// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.Slot;

import dscp.scp.LocalNode;
import dscp.scp.BallotProtocol;
import dscp.scp.NominationProtocol;
import dscp.scp.SCP;
import dscp.scp.SCPDriver;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import core.stdc.stdint;
import core.stdc.time;

/**
 * The Slot object is in charge of maintaining the state of the SCP protocol
 * for a given slot index.
 */
// todo: this used to be a shared_ptr to a struct
class Slot
{
    const uint64 mSlotIndex; // the index this slot is tracking
    SCP mSCP;

    BallotProtocol mBallotProtocol;
    NominationProtocol mNominationProtocol;

    // keeps track of all statements seen so far for this slot.
    // it is used for debugging purpose
    struct HistoricalStatement
    {
        time_t mWhen;
        SCPStatement mStatement;
        bool mValidated;
    };

    HistoricalStatement[] mStatementsHistory;

    // true if the Slot was fully validated
    bool mFullyValidated;

  public:
    this(uint64 slotIndex, SCP scp)
    {
        mSlotIndex = slotIndex;
        mSCP = scp;
        mBallotProtocol = new BallotProtocol(this);
        mNominationProtocol = new NominationProtocol(this);
        mFullyValidated = scp.getLocalNode().isValidator();
    }

    uint64
    getSlotIndex() const
    {
        return mSlotIndex;
    }

    SCP
    getSCP()
    {
        return mSCP;
    }

    SCPDriver
    getSCPDriver()
    {
        return mSCP.getDriver();
    }

    const(SCPDriver)
    getSCPDriver() const
    {
        return mSCP.getDriver();
    }

    BallotProtocol
    getBallotProtocol()
    {
        return mBallotProtocol;
    }

    const(Value) getLatestCompositeCandidate()
    {
        return mNominationProtocol.getLatestCompositeCandidate();
    }

    // returns the latest messages the slot emitted
    SCPEnvelope[] getLatestMessagesSend() const
    {
        if (!mFullyValidated)
            return null;

        SCPEnvelope[] res;
        if (auto e = mNominationProtocol.getLastMessageSend())
            res ~= *e;

        if (auto e = mBallotProtocol.getLastMessageSend())
            res ~= *e;

        return res;
    }

    // forces the state to match the one in the envelope
    // this is used when rebuilding the state after a crash for example
    void setStateFromEnvelope(ref const(SCPEnvelope) e)
    {
        if (e.statement.nodeID == getSCP().getLocalNodeID() &&
            e.statement.slotIndex == mSlotIndex)
        {
            if (e.statement.pledges.type() == SCPStatementType.SCP_ST_NOMINATE)
            {
                mNominationProtocol.setStateFromEnvelope(e);
            }
            else
            {
                mBallotProtocol.setStateFromEnvelope(e);
            }
        }
        else
        {
            if (Logging.logTrace("SCP"))
                CLOG(TRACE, "SCP")
                    << "Slot.setStateFromEnvelope invalid envelope"
                    << " i: " << getSlotIndex() << " " << mSCP.envToStr(e);
        }
    }

    // returns the latest messages known for this slot
    SCPEnvelope[] getCurrentState() const;

    // returns the latest message from a node
    // or null if not found
    const(SCPEnvelope)* getLatestMessage(ref const(NodeID) id) const;

    // returns messages that helped this slot externalize
    SCPEnvelope[] getExternalizingState() const;

    // records the statement in the historical record for this slot
    void recordStatement(ref const(SCPStatement) st);

    // Process a newly received envelope for this slot and update the state of
    // the slot accordingly.
    // self: set to true when node wants to record its own messages (potentially
    // triggering more transitions)
    SCP.EnvelopeState processEnvelope(ref const(SCPEnvelope) envelope, bool self);

    bool abandonBallot();

    // bumps the ballot based on the local state and the value passed in:
    // in prepare phase, attempts to take value
    // otherwise, no-ops
    // force: when true, always bumps the value, otherwise only bumps
    // the state if no value was prepared
    bool bumpState(const(Value) value, bool force);

    // attempts to nominate a value for consensus
    bool nominate(const(Value) value, const(Value) previousValue,
                  bool timedout);

    void stopNomination();

    // returns the current nomination leaders
    set!NodeID getNominationLeaders() const;

    bool isFullyValidated() const;
    void setFullyValidated(bool fullyValidated);

    // ** status methods

    size_t
    getStatementCount() const
    {
        return mStatementsHistory.size();
    }

    // returns the hash of the QuorumSet that should be downloaded
    // with the statement.
    // note: the companion hash for an EXTERNALIZE statement does
    // not match the hash of the QSet, but the hash of commitQuorumSetHash
    static Hash getCompanionQuorumSetHashFromStatement(ref const(SCPStatement) st);

    // returns the values associated with the statement
    static Value[] getStatementValues(ref const(SCPStatement) st);

    // returns the QuorumSet that should be used for a node given the
    // statement (singleton for externalize)
    SCPQuorumSetPtr getQuorumSetFromStatement(ref const(SCPStatement) st);

    // wraps a statement in an envelope (sign it, etc)
    SCPEnvelope createEnvelope(ref const(SCPStatement) statement);

    // ** federated agreement helper functions

    // returns true if the statement defined by voted and accepted
    // should be accepted
    bool federatedAccept(StatementPredicate voted, StatementPredicate accepted,
                         const(SCPEnvelope[NodeID]) envs);
    // returns true if the statement defined by voted
    // is ratified
    bool federatedRatify(StatementPredicate voted,
                         const(SCPEnvelope[NodeID]) envs);

    LocalNode getLocalNode();

    enum timerIDs
    {
        NOMINATION_TIMER = 0,
        BALLOT_PROTOCOL_TIMER = 1
    };

  protected:
    SCPEnvelope[] getEntireCurrentState();
}
