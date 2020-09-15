// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.NominationProtocol;

import dscp.scp.LocalNode;
import dscp.scp.SCP;
import dscp.scp.SCPDriver;
import dscp.scp.Slot;
import dscp.scp.QuorumSetUtils;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import std.algorithm;
import std.range;

class NominationProtocol
{
  protected:
    Slot mSlot;

    int32 mRoundNumber;
    set!Value mVotes;                       // X
    set!Value mAccepted;                    // Y
    set!Value mCandidates;                  // Z
    SCPEnvelope[NodeID] mLatestNominations; // N

    SCPEnvelope* mLastEnvelope; // last envelope emitted by this node

    // nodes from quorum set that have the highest priority this round
    set!NodeID mRoundLeaders;

    // true if 'nominate' was called
    bool mNominationStarted;

    // the latest (if any) candidate value
    Value mLatestCompositeCandidate;

    // the value from the previous slot
    Value mPreviousValue;

    bool isNewerStatement (ref const(NodeID) nodeID, ref const(SCPNomination) st)
    {
        if (auto old = nodeID in mLatestNominations)
            return isNewerStatement(old.statement.pledges.nominate_, st);

        return true;
    }

    static bool isNewerStatement(ref const(SCPNomination) oldst,
                                 ref const(SCPNomination) st)
    {
        bool res = false;
        bool grows;
        bool g = false;

        if (isSubsetHelper(oldst.votes, st.votes, g))
        {
            grows = g;
            if (isSubsetHelper(oldst.accepted, st.accepted, g))
            {
                grows = grows || g;
                res = grows; //  true only if one of the sets grew
            }
        }

        return res;
    }

    // returns true if 'p' is a subset of 'v'
    // also sets 'notEqual' if p and v differ
    // note: p and v must be sorted
    static bool isSubsetHelper(const(Value)[] p,
                               const(Value)[] v, ref bool notEqual)
    {
        if (p.length <= v.length && v.canFind(p))
        {
            notEqual = p.length != v.length;
            return true;
        }

        notEqual = true;
        return false;
    }

    ValidationLevel validateValue(ref const(Value) v)
    {
        return mSlot.getSCPDriver().validateValue(mSlot.getSlotIndex(), v, true);
    }

    Value extractValidValue(ref const(Value) value)
    {
        return mSlot.getSCPDriver().extractValidValue(mSlot.getSlotIndex(), value);
    }

    bool isSane (ref const(SCPStatement) st)
    {
        const nom = &st.pledges.nominate_;

        if (nom.votes.length + nom.accepted.length == 0)
            return false;

        return nom.votes.isStrictlyMonotonic() &&
            nom.accepted.isStrictlyMonotonic();
    }

    // only called after a call to isNewerStatement so safe to replace the
    // mLatestNomination
    void recordEnvelope(ref const(SCPEnvelope) env)
    {
        const st = &env.statement;
        mLatestNominations[st.nodeID] = env;
        mSlot.recordStatement(env.statement);
    }

    void emitNomination()
    {
        SCPStatement st;
        st.nodeID = mSlot.getLocalNode().getNodeID();
        st.pledges.type = SCPStatementType.SCP_ST_NOMINATE;
        auto nom = &st.pledges.nominate_;

        nom.quorumSetHash = mSlot.getLocalNode().getQuorumSetHash();

        foreach (v; mVotes.byKey)
            nom.votes ~= cast(ubyte[])v;

        foreach (a; mAccepted.byKey)
            nom.accepted ~= cast(ubyte[])a;

        SCPEnvelope envelope = mSlot.createEnvelope(st);

        if (mSlot.processEnvelope(envelope, true) == SCP.EnvelopeState.VALID)
        {
            if (!mLastEnvelope ||
                isNewerStatement(mLastEnvelope.statement.pledges.nominate_,
                                 st.pledges.nominate_))
            {
                mLastEnvelope = new SCPEnvelope();
                mLastEnvelope.tupleof = envelope.tupleof;  // deep-dup

                if (mSlot.isFullyValidated())
                {
                    mSlot.getSCPDriver().emitEnvelope(envelope);
                }
            }
        }
        else
        {
            // there is a bug in the application if it queued up
            // a statement for itself that it considers invalid
            assert(0, "moved to a bad state (nomination)");
        }
    }

    // returns true if v is in the accepted list from the statement
    static bool acceptPredicate(ref const(Value) v, ref const(SCPStatement) st)
    {
        const nom = &st.pledges.nominate_;
        return nom.accepted.canFind(v);
    }

    // applies 'processor' to all values from the passed in nomination
    static void applyAll(ref const(SCPNomination) nom,
                         void delegate(ref const(Value)) processor)
    {
        foreach (v; nom.votes)
            processor(v);

        foreach (a; nom.accepted)
            processor(a);
    }

    // updates the set of nodes that have priority over the others
    void updateRoundLeaders()
    {
        uint32 threshold;
        PublicKey[] validators;
        SCPQuorumSet[] innerSets;

        const localQset = mSlot.getLocalNode().getQuorumSet();
        SCPQuorumSet myQSet;
        myQSet.threshold = localQset.threshold;
        myQSet.validators = localQset.validators.dup;
        myQSet.innerSets = (cast(SCPQuorumSet[])localQset.innerSets).dup;

        // initialize priority with value derived from self
        set!NodeID newRoundLeaders;
        auto localID = mSlot.getLocalNode().getNodeID();
        normalizeQSet(myQSet, &localID);

        newRoundLeaders[localID] = [];
        uint64 topPriority = getNodePriority(localID, myQSet);

        LocalNode.forAllNodes(myQSet, (ref const(NodeID) cur) {
            uint64 w = getNodePriority(cur, myQSet);
            if (w > topPriority)
            {
                topPriority = w;
                newRoundLeaders.clear();
            }
            if (w == topPriority && w > 0)
            {
                newRoundLeaders[cur] = [];
            }
        });
        // expand mRoundLeaders with the newly computed leaders
        foreach (new_leader; newRoundLeaders.byKey)
            mRoundLeaders[new_leader] = [];

        //if (Logging.logDebug("SCP"))
        //{
        //    CLOG(DEBUG, "SCP") << "updateRoundLeaders: " << newRoundLeaders.length
        //                       << " . " << mRoundLeaders.length;
        //    foreach (rl; mRoundLeaders)
        //    {
        //        CLOG(DEBUG, "SCP")
        //            << "    leader " << mSlot.getSCPDriver().toShortString(rl);
        //    }
        //}
    }

    // computes Gi(isPriority?P:N, prevValue, mRoundNumber, nodeID)
    // from the paper
    uint64 hashNode(bool isPriority, ref const(NodeID) nodeID)
    {
        assert(!mPreviousValue.empty());
        return mSlot.getSCPDriver().computeHashNode(
            mSlot.getSlotIndex(), mPreviousValue, isPriority, mRoundNumber, nodeID);
    }

    // computes Gi(K, prevValue, mRoundNumber, value)
    uint64 hashValue(ref const(Value) value)
    {
        assert(!mPreviousValue.empty());
        return mSlot.getSCPDriver().computeValueHash(
            mSlot.getSlotIndex(), mPreviousValue, mRoundNumber, value);
    }

    uint64 getNodePriority(ref const(NodeID) nodeID, ref const(SCPQuorumSet) qset)
    {
        uint64 res;
        uint64 w;

        if (nodeID == mSlot.getLocalNode().getNodeID())
        {
            // local node is in all quorum sets
            w = ulong.max;
        }
        else
        {
            w = LocalNode.getNodeWeight(nodeID, qset);
        }

        // if w > 0; w is inclusive here as
        // 0 <= hashNode <= ulong.max
        if (w > 0 && hashNode(false, nodeID) <= w)
        {
            res = hashNode(true, nodeID);
        }
        else
        {
            res = 0;
        }
        return res;
    }

    // returns the highest value that we don't have yet, that we should
    // vote for, extracted from a nomination.
    // returns the empty value if no new value was found
    Value getNewValueFromNomination(ref const(SCPNomination) nom)
    {
        // pick the highest value we don't have from the leader
        // sorted using hashValue.
        Value newVote;
        uint64 newHash = 0;

        applyAll(nom, (ref const(Value) value) {
            Value valueToNominate;
            auto vl = validateValue(value);
            if (vl == ValidationLevel.kFullyValidatedValue)
            {
                valueToNominate = value.dup;
            }
            else
            {
                valueToNominate = extractValidValue(value);
            }
            if (!valueToNominate.empty())
            {
                if (valueToNominate !in mVotes)
                {
                    uint64 curHash = hashValue(valueToNominate);
                    if (curHash >= newHash)
                    {
                        newHash = curHash;
                        newVote = valueToNominate;
                    }
                }
            }
        });
        return newVote;
    }

  public:
    this(Slot slot)
    {
        mSlot = slot;
        mRoundNumber = 0;
        mNominationStarted = false;
    }

    SCP.EnvelopeState processEnvelope(ref const(SCPEnvelope) envelope)
    {
        const st = &envelope.statement;
        const nom = &st.pledges.nominate_;

        SCP.EnvelopeState res = SCP.EnvelopeState.INVALID;

        if (isNewerStatement(st.nodeID, *nom))
        {
            if (isSane(*st))
            {
                recordEnvelope(envelope);
                res = SCP.EnvelopeState.VALID;

                if (mNominationStarted)
                {
                    bool modified =
                        false; // tracks if we should emit a new nomination message
                    bool newCandidates = false;

                    // attempts to promote some of the votes to accepted
                    foreach (v; nom.votes)
                    {
                        if (v in mAccepted)
                            continue;  // v is already accepted

                        if (mSlot.federatedAccept(
                                (ref const(SCPStatement) st) {
                                    const nom = &st.pledges.nominate_;
                                    return nom.votes.canFind(v);
                                },
                                (ref const(SCPStatement) st) => acceptPredicate(v, st),
                                mLatestNominations))
                        {
                            auto vl = validateValue(v);
                            if (vl == ValidationLevel.kFullyValidatedValue)
                            {
                                mAccepted[v] = [];
                                mVotes[v] = [];
                                modified = true;
                            }
                            else
                            {
                                // the value made it pretty far:
                                // see if we can vote for a variation that
                                // we consider valid
                                Value toVote;
                                toVote = extractValidValue(v);
                                if (!toVote.empty())
                                {
                                    if (toVote in mVotes)
                                        modified = true;
                                }
                            }
                        }
                    }

                    // attempts to promote accepted values to candidates
                    foreach (a; mAccepted.byKey)
                    {
                        if (mCandidates.byKey.canFind(a))
                            continue;

                        if (mSlot.federatedRatify(
                                (ref const(SCPStatement) st) => acceptPredicate(a, st),
                                mLatestNominations))
                        {
                            mCandidates[a] = [];
                            newCandidates = true;
                        }
                    }

                    // only take round leader votes if we're still looking for
                    // candidates
                    if (mCandidates.empty() &&
                        mRoundLeaders.byKey.canFind(st.nodeID))
                    {
                        Value newVote = getNewValueFromNomination(*nom);
                        if (!newVote.empty())
                        {
                            mVotes[newVote.idup] = [];
                            modified = true;
                            mSlot.getSCPDriver().nominatingValue(
                                mSlot.getSlotIndex(), newVote);
                        }
                    }

                    if (modified)
                    {
                        emitNomination();
                    }

                    if (newCandidates)
                    {
                        mLatestCompositeCandidate =
                            mSlot.getSCPDriver().combineCandidates(
                                mSlot.getSlotIndex(), mCandidates);

                        mSlot.getSCPDriver().updatedCandidateValue(
                            mSlot.getSlotIndex(), mLatestCompositeCandidate);

                        mSlot.bumpState(mLatestCompositeCandidate, false);
                    }
                }
            }
            else
            {
                //CLOG(TRACE, "SCP")
                //    << "NominationProtocol: message didn't pass sanity check";
            }
        }
        return res;
    }

    static Value[] getStatementValues(ref const(SCPStatement) st);

    // attempts to nominate a value for consensus
    bool nominate(ref const(Value) value, ref const(Value) previousValue,
                  bool timedout);

    // stops the nomination protocol
    void stopNomination();

    // return the current leaders
    const(set!NodeID) getLeaders() const;

    ref const(Value)
    getLatestCompositeCandidate() const
    {
        return mLatestCompositeCandidate;
    }

    const(SCPEnvelope)* getLastMessageSend() const
    {
        return mLastEnvelope.get();
    }

    void setStateFromEnvelope(ref const(SCPEnvelope) e);

    SCPEnvelope[] getCurrentState() const;

    // returns the latest message from a node
    // or null if not found
    const(SCPEnvelope)* getLatestMessage(ref const(NodeID) id) const;
}
