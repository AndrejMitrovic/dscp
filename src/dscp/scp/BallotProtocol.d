// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.BallotProtocol;

import dscp.scp.LocalNode;
import dscp.scp.SCP;
import dscp.scp.SCPDriver;
import dscp.scp.Slot;
import dscp.scp.QuorumSetUtils;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import std.range;

// used to filter statements
alias StatementPredicate = bool delegate (ref const(SCPStatement));

// max number of transitions that can occur from processing one message
private enum MAX_ADVANCE_SLOT_RECURSION = 50;

/**
 * The Slot object is in charge of maintaining the state of the SCP protocol
 * for a given slot index.
 */
class BallotProtocol
{
    Slot mSlot;

    bool mHeardFromQuorum = false;

    // state tracking members
    enum SCPPhase
    {
        SCP_PHASE_PREPARE,
        SCP_PHASE_CONFIRM,
        SCP_PHASE_EXTERNALIZE,
        SCP_PHASE_NUM
    };

    // todo: this was unique_ptr, keeping refcount..
    SCPBallot* mCurrentBallot;      // b
    SCPBallot* mPrepared;           // p
    SCPBallot* mPreparedPrime;      // p'
    SCPBallot* mHighBallot;         // h
    SCPBallot* mCommit;             // c
    SCPEnvelope[NodeID] mLatestEnvelopes; // M
    SCPPhase mPhase = SCPPhase.SCP_PHASE_PREPARE;  // Phi
    // todo: this was unique_ptr
    Value* mValueOverride;          // z

    int mCurrentMessageLevel = 0; // number of messages triggered in one run

    // todo: this was shared_ptr
    SCPEnvelope* mLastEnvelope; // last envelope generated by this node
    SCPEnvelope* mLastEnvelopeEmit; // last envelope emitted by this node

  public:
    this (Slot slot)
    {
        mSlot = slot;
    }

    // Process a newly received envelope for this slot and update the state of
    // the slot accordingly.
    // self: set to true when node feeds its own statements in order to
    // trigger more potential state changes
    SCP.EnvelopeState processEnvelope(ref const(SCPEnvelope) envelope,
        bool self)
    {
        SCP.EnvelopeState res = SCP.EnvelopeState.INVALID;
        assert(envelope.statement.slotIndex == mSlot.getSlotIndex());

        auto statement = envelope.statement;
        auto nodeID = statement.nodeID;

        if (!isStatementSane(statement, self))
        {
            if (self)
            {
                //CLOG(ERROR, "SCP") << "not sane statement from self, skipping "
                //                   << "  e: " << mSlot.getSCP().envToStr(envelope);
            }

            return SCP.EnvelopeState.INVALID;
        }

        if (!isNewerStatement(nodeID, statement))
        {
            if (self)
            {
                //CLOG(ERROR, "SCP") << "stale statement from self, skipping "
                //                   << "  e: " << mSlot.getSCP().envToStr(envelope);
            }
            else
            {
                //CLOG(TRACE, "SCP") << "stale statement, skipping "
                //                   << " i: " << mSlot.getSlotIndex();
            }

            return SCP.EnvelopeState.INVALID;
        }

        auto validationRes = validateValues(statement);
        if (validationRes != ValidationLevel.kInvalidValue)
        {
            bool processed = false;

            if (mPhase != SCPPhase.SCP_PHASE_EXTERNALIZE)
            {
                if (validationRes == ValidationLevel.kMaybeValidValue)
                {
                    mSlot.setFullyValidated(false);
                }

                recordEnvelope(envelope);
                processed = true;
                advanceSlot(statement);
                res = SCP.EnvelopeState.VALID;
            }

            if (!processed)
            {
                // note: this handles also our own messages
                // in particular our final EXTERNALIZE message
                if (mPhase == SCPPhase.SCP_PHASE_EXTERNALIZE &&
                    mCommit.value == getWorkingBallot(statement).value)
                {
                    recordEnvelope(envelope);
                    res = SCP.EnvelopeState.VALID;
                }
                else
                {
                    if (self)
                    {
                        //CLOG(ERROR, "SCP")
                        //    << "externalize statement with invalid value from "
                        //       "self, skipping "
                        //    << "  e: " << mSlot.getSCP().envToStr(envelope);
                    }

                    res = SCP.EnvelopeState.INVALID;
                }
            }
        }
        else
        {
            // If the value is not valid, we just ignore it.
            if (self)
            {
                //CLOG(ERROR, "SCP") << "invalid value from self, skipping "
                //                   << "  e: " << mSlot.getSCP().envToStr(envelope);
            }
            else
            {
                //CLOG(TRACE, "SCP") << "invalid value "
                //                   << " i: " << mSlot.getSlotIndex();
            }

            res = SCP.EnvelopeState.INVALID;
        }
        return res;
    }

    void ballotProtocolTimerExpired();

    // abandon's current ballot, move to a new ballot
    // at counter `n` (or, if n == 0, increment current counter)
    bool abandonBallot(uint32 n)
    {
        //CLOG(TRACE, "SCP") << "BallotProtocol.abandonBallot";
        bool res = false;
        Value v = mSlot.getLatestCompositeCandidate().dup;
        if (v.empty())
        {
            if (mCurrentBallot)
            {
                v = mCurrentBallot.value;
            }
        }
        if (!v.empty())
        {
            if (n == 0)
            {
                res = bumpState(v, true);
            }
            else
            {
                res = bumpState(v, n);
            }
        }
        return res;
    }

    // bumps the ballot based on the local state and the value passed in:
    // in prepare phase, attempts to take value
    // otherwise, no-ops
    // force: when true, always bumps the value, otherwise only bumps
    // the state if no value was prepared
    bool bumpState(ref const(Value) value, bool force)
    {
        uint32 n;
        if (!force && mCurrentBallot)
        {
            return false;
        }

        n = mCurrentBallot ? (mCurrentBallot.counter + 1) : 1;

        return bumpState(value, n);
    }

    // flavor that takes the actual desired counter value
    bool bumpState(ref const(Value) value, uint32 n)
    {
        if (mPhase != SCPPhase.SCP_PHASE_PREPARE && mPhase != SCPPhase.SCP_PHASE_CONFIRM)
        {
            return false;
        }

        SCPBallot newb;

        newb.counter = n;

        if (mValueOverride)
        {
            // we use the value that we saw confirmed prepared
            // or that we at least voted to commit to
            newb.value = *mValueOverride;
        }
        else
        {
            newb.value = value.dup;
        }

        //if (Logging.logTrace("SCP"))
        //    CLOG(TRACE, "SCP") << "BallotProtocol.bumpState"
        //                       << " i: " << mSlot.getSlotIndex()
        //                       << " v: " << mSlot.getSCP().ballotToStr(newb);

        bool updated = updateCurrentValue(newb);

        if (updated)
        {
            emitCurrentStateStatement();
            checkHeardFromQuorum();
        }

        return updated;
    }

    // ** status methods

    // returns the hash of the QuorumSet that should be downloaded
    // with the statement.
    // note: the companion hash for an EXTERNALIZE statement does
    // not match the hash of the QSet, but the hash of commitQuorumSetHash
    static Hash getCompanionQuorumSetHashFromStatement(ref const(SCPStatement) st);

    // helper function to retrieve b for PREPARE, P for CONFIRM or
    // c for EXTERNALIZE messages
    static SCPBallot getWorkingBallot(ref const(SCPStatement) st);

    const(SCPEnvelope)*
    getLastMessageSend() const
    {
        return mLastEnvelopeEmit.get();
    }

    void setStateFromEnvelope(ref const(SCPEnvelope) e);

    SCPEnvelope[] getCurrentState() const;

    // returns the latest message from a node
    // or null if not found
    const(SCPEnvelope)* getLatestMessage(ref const(NodeID) id) const;

    SCPEnvelope[] getExternalizingState() const;

  private:
    // attempts to make progress using the latest statement as a hint
    // calls into the various attempt* methods, emits message
    // to make progress
    void advanceSlot(ref const(SCPStatement) hint);

    // returns true if all values in statement are valid
    ValidationLevel validateValues(ref const(SCPStatement) st);

    // send latest envelope if needed
    void sendLatestEnvelope();

    // `attempt*` methods are called by `advanceSlot` internally call the
    //  the `set*` methods.
    //   * check if the specified state for the current slot has been
    //     reached or not.
    //   * idempotent
    //  input: latest statement received (used as a hint to reduce the
    //  space to explore)
    //  output: returns true if the state was updated

    // `set*` methods progress the slot to the specified state
    //  input: state specific
    //  output: returns true if the state was updated.

    // step 1 and 5 from the SCP paper
    bool attemptPreparedAccept(ref const(SCPStatement) hint);
    // prepared: ballot that should be prepared
    bool setPreparedAccept(ref const(SCPBallot) prepared);

    // step 2+3+8 from the SCP paper
    // ballot is the candidate to record as 'confirmed prepared'
    bool attemptPreparedConfirmed(ref const(SCPStatement) hint);
    // newC, newH : low/high bounds prepared confirmed
    bool setPreparedConfirmed(ref const(SCPBallot) newC, ref const(SCPBallot) newH);

    // step (4 and 6)+8 from the SCP paper
    bool attemptAcceptCommit(ref const(SCPStatement) hint);
    // new values for c and h
    bool setAcceptCommit(ref const(SCPBallot) c, ref const(SCPBallot) h);

    // step 7+8 from the SCP paper
    bool attemptConfirmCommit(ref const(SCPStatement) hint);
    bool setConfirmCommit(ref const(SCPBallot) acceptCommitLow,
                          ref const(SCPBallot) acceptCommitHigh);

    // step 9 from the SCP paper
    bool attemptBump();

    // computes a list of candidate values that may have been prepared
    set!SCPBallot getPrepareCandidates(ref const(SCPStatement) hint);

    // helper to perform step (8) from the paper
    bool updateCurrentIfNeeded(ref const(SCPBallot) h);

    // An interval is [low,high] represented as a pair
    struct Interval
    {
        uint32 low;
        uint32 high;
    }

    // helper function to find a contiguous range 'candidate' that satisfies the
    // predicate.
    // updates 'candidate' (or leave it unchanged)
    static void findExtendedInterval(ref Interval candidate,
                                     ref const(set!uint32) boundaries,
                                     bool delegate(ref const(Interval)) pred);

    // constructs the set of counters representing the
    // commit ballots compatible with the ballot
    set!uint32 getCommitBoundariesFromStatements(ref const(SCPBallot) ballot);

    // ** helper predicates that evaluate if a statement satisfies
    // a certain property

    // is ballot prepared by st
    static bool hasPreparedBallot(ref const(SCPBallot) ballot,
                                  ref const(SCPStatement) st);

    // returns true if the statement commits the ballot in the range 'check'
    static bool commitPredicate(ref const(SCPBallot) ballot, ref const(Interval) check,
                                ref const(SCPStatement) st);

    // attempts to update p to ballot (updating p' if needed)
    bool setPrepared(ref const(SCPBallot) ballot);

    // ** Helper methods to compare two ballots

    // ballot comparison (ordering)
    static int compareBallots(ref const(SCPBallot*) b1,
                              ref const(SCPBallot*) b2);
    static int compareBallots(ref const(SCPBallot) b1, ref const(SCPBallot) b2);

    // b1 ~ b2
    static bool areBallotsCompatible(ref const(SCPBallot) b1, ref const(SCPBallot) b2);

    // b1 <= b2 && b1 !~ b2
    static bool areBallotsLessAndIncompatible(ref const(SCPBallot) b1,
                                              ref const(SCPBallot) b2);
    // b1 <= b2 && b1 ~ b2
    static bool areBallotsLessAndCompatible(ref const(SCPBallot) b1,
                                            ref const(SCPBallot) b2);

    // ** statement helper functions

    // returns true if the statement is newer than the one we know about
    // for a given node.
    bool isNewerStatement(ref const(NodeID) nodeID, ref const(SCPStatement) st)
    {
        if (auto oldp = nodeID in mLatestEnvelopes)
            return isNewerStatement(oldp.statement, st);

        return false;
    }

    // returns true if st is newer than oldst
    static bool isNewerStatement(ref const(SCPStatement) oldst,
                                 ref const(SCPStatement) st)
    {
        bool res = false;

        // total ordering described in SCP paper.
        auto t = st.pledges.type;

        // statement type (PREPARE < CONFIRM < EXTERNALIZE)
        if (oldst.pledges.type != t)
        {
            res = (oldst.pledges.type < t);
        }
        else
        {
            // can't have duplicate EXTERNALIZE statements
            if (t == SCPStatementType.SCP_ST_EXTERNALIZE)
            {
                res = false;
            }
            else if (t == SCPStatementType.SCP_ST_CONFIRM)
            {
                // sorted by (b, p, p', h) (p' = 0 implicitely)
                const oldC = &oldst.pledges.confirm_;
                const c = &st.pledges.confirm_;
                int compBallot = compareBallots(oldC.ballot, c.ballot);
                if (compBallot < 0)
                {
                    res = true;
                }
                else if (compBallot == 0)
                {
                    if (oldC.nPrepared == c.nPrepared)
                    {
                        res = (oldC.nH < c.nH);
                    }
                    else
                    {
                        res = (oldC.nPrepared < c.nPrepared);
                    }
                }
            }
            else
            {
                // Lexicographical order between PREPARE statements:
                // (b, p, p', h)
                const oldPrep = &oldst.pledges.prepare_;
                const prep = &st.pledges.prepare_;

                int compBallot = compareBallots(oldPrep.ballot, prep.ballot);
                if (compBallot < 0)
                {
                    res = true;
                }
                else if (compBallot == 0)
                {
                    compBallot = compareBallots(oldPrep.prepared, prep.prepared);
                    if (compBallot < 0)
                    {
                        res = true;
                    }
                    else if (compBallot == 0)
                    {
                        compBallot = compareBallots(oldPrep.preparedPrime,
                                                    prep.preparedPrime);
                        if (compBallot < 0)
                        {
                            res = true;
                        }
                        else if (compBallot == 0)
                        {
                            res = (oldPrep.nH < prep.nH);
                        }
                    }
                }
            }
        }

        return res;
    }

    // basic sanity check on statement
    bool isStatementSane(ref const(SCPStatement) st, bool self)
    {
        auto qSet = mSlot.getQuorumSetFromStatement(st);

        const NoExtraChecks = false;
        const char* reason = null;
        bool res = qSet.ok && isQuorumSetSane(qSet, NoExtraChecks, &reason);
        if (!res)
        {
            //CLOG(DEBUG, "SCP") << "Invalid quorum set received";
            if (reason !is null)
            {
                //std.string msg(reason);
                //CLOG(DEBUG, "SCP") << msg;
            }

            return false;
        }

        switch (st.pledges.type)
        {
        case SCPStatementType.SCP_ST_PREPARE:
        {
            const p = &st.pledges.prepare_;
            // self is allowed to have b = 0 (as long as it never gets emitted)
            bool isOK = self || p.ballot.counter > 0;

            isOK = isOK &&
                   ((!p.preparedPrime || !p.prepared) ||
                    (areBallotsLessAndIncompatible(*p.preparedPrime, *p.prepared)));

            isOK =
                isOK && (p.nH == 0 || (p.prepared && p.nH <= p.prepared.counter));

            // c != 0 . c <= h <= b
            isOK = isOK && (p.nC == 0 || (p.nH != 0 && p.ballot.counter >= p.nH &&
                                          p.nH >= p.nC));

            if (!isOK)
            {
                //CLOG(TRACE, "SCP") << "Malformed PREPARE message";
                res = false;
            }
        }
        break;
        case SCPStatementType.SCP_ST_CONFIRM:
        {
            const c = &st.pledges.confirm_;
            // c <= h <= b
            res = c.ballot.counter > 0;
            res = res && (c.nH <= c.ballot.counter);
            res = res && (c.nCommit <= c.nH);
            if (!res)
            {
                //CLOG(TRACE, "SCP") << "Malformed CONFIRM message";
            }
        }
        break;
        case SCPStatementType.SCP_ST_EXTERNALIZE:
        {
            const e = &st.pledges.externalize_;

            res = e.commit.counter > 0;
            res = res && e.nH >= e.commit.counter;

            if (!res)
            {
                //CLOG(TRACE, "SCP") << "Malformed EXTERNALIZE message";
            }
        }
        break;
        default:
            assert(0);
        }

        return res;
    }

    // records the statement in the state machine
    void recordEnvelope(ref const(SCPEnvelope) env)
    {
        const st = &env.statement;
        mLatestEnvelopes[st.nodeID] = env;
        mSlot.recordStatement(env.statement);
    }

    // ** State related methods

    // helper function that updates the current ballot
    // this is the lowest level method to update the current ballot and as
    // such doesn't do any validation
    // check: verifies that ballot is greater than old one
    void bumpToBallot(ref const(SCPBallot) ballot, bool check);

    // switch the local node to the given ballot's value
    // with the assumption that the ballot is more recent than the one
    // we have.
    // updates the local state based to the specified ballot
    // (that could be a prepared ballot) enforcing invariants
    bool updateCurrentValue(ref const(SCPBallot) ballot)
    {
        if (mPhase != SCPPhase.SCP_PHASE_PREPARE && mPhase != SCPPhase.SCP_PHASE_CONFIRM)
        {
            return false;
        }

        bool updated = false;
        if (!mCurrentBallot)
        {
            bumpToBallot(ballot, true);
            updated = true;
        }
        else
        {
            assert(compareBallots(*mCurrentBallot, ballot) <= 0);

            if (mCommit && !areBallotsCompatible(*mCommit, ballot))
            {
                return false;
            }

            int comp = compareBallots(*mCurrentBallot, ballot);
            if (comp < 0)
            {
                bumpToBallot(ballot, true);
                updated = true;
            }
            else if (comp > 0)
            {
                // this code probably changes with the final version
                // of the conciliator

                // this case may happen if the other nodes are not
                // following the protocol (and we end up with a smaller value)
                // not sure what is the best way to deal
                // with this situation
                //CLOG(ERROR, "SCP")
                //    << "BallotProtocol.updateCurrentValue attempt to bump to "
                //       "a smaller value";
                // can't just bump to the value as we may already have
                // statements at counter+1
                return false;
            }
        }

        if (updated)
        {
            //CLOG(TRACE, "SCP") << "BallotProtocol.updateCurrentValue updated";
        }

        checkInvariants();

        return updated;
    }

    // emits a statement reflecting the nodes' current state
    // and attempts to make progress
    void emitCurrentStateStatement();

    // verifies that the internal state is consistent
    void checkInvariants();

    // create a statement of the given type using the local state
    SCPStatement createStatement(ref const(SCPStatementType) type);

    // returns a string representing the slot's state
    // used for log lines
    string getLocalState() const;

    LocalNode getLocalNode();

    bool federatedAccept(StatementPredicate voted, StatementPredicate accepted);
    bool federatedRatify(StatementPredicate voted);

    void startBallotProtocolTimer();
    void stopBallotProtocolTimer();
    void checkHeardFromQuorum();
}
