// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.Slot;

import dscp.scp.LocalNode;
import dscp.scp.BallotProtocol;
import dscp.scp.NominationProtocol;
import dscp.scp.SCP;
import dscp.scp.SCPDriver;
import dscp.util.Nullable;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import core.stdc.stdint;
import core.stdc.time;

public enum TimerID
{
    NOMINATION_TIMER = 0,
    BALLOT_PROTOCOL_TIMER = 1
}

/**
 * The Slot object is in charge of maintaining the state of the SCP protocol
 * for a given slot index.
 */
// todo: this used to be a shared_ptr to a struct
class SlotT (NodeID, Hash, Value, Signature, alias Set, alias getHashOf)
{
    public alias SCPStatement = SCPStatementT!(NodeID, Hash, Value);
    public alias SCP = SCPT!(NodeID, Hash, Value, Signature, Set, getHashOf);
    public alias SCPEnvelope = SCPEnvelopeT!(NodeID, Hash, Value, Signature);
    public alias BallotProtocol = BallotProtocolT!(NodeID, Hash, Value, Signature, Set, getHashOf);
    public alias NominationProtocol = NominationProtocolT!(NodeID, Hash, Value, Signature, Set, getHashOf);
    public alias SCPDriver = SCPDriverT!(NodeID, Hash, Value, Signature, Set, getHashOf);
    public alias SCPQuorumSet = SCPQuorumSetT!NodeID;
    public alias StatementPredicate = bool delegate (ref const(SCPStatement));
    public alias LocalNode = LocalNodeT!(NodeID, Hash, Value, Signature, Set, getHashOf);

    // keeps track of all statements seen so far for this slot.
    // it is used for debugging purpose
    public struct HistoricalStatement
    {
        time_t mWhen;
        SCPStatement mStatement;
        bool mValidated;
    }

    private const uint64 mSlotIndex;  // the index this slot is tracking
    private SCP mSCP;
    private BallotProtocol mBallotProtocol;
    private NominationProtocol mNominationProtocol;
    private HistoricalStatement[] mStatementsHistory;
    private bool mFullyValidated;  // true if the Slot was fully validated

    public this (uint64 slotIndex, SCP scp)
    {
        mSlotIndex = slotIndex;
        mSCP = scp;
        mBallotProtocol = new BallotProtocol(this);
        mNominationProtocol = new NominationProtocol(this);
        mFullyValidated = scp.getLocalNode().isValidator();
    }

    public uint64 getSlotIndex () const
    {
        return mSlotIndex;
    }

    public inout(SCP) getSCP () inout
    {
        return mSCP;
    }

    public SCPDriver getSCPDriver ()
    {
        return mSCP.getDriver();
    }

    public const(SCPDriver) getSCPDriver () const
    {
        return mSCP.getDriver();
    }

    public BallotProtocol getBallotProtocol ()
    {
        return mBallotProtocol;
    }

    public const(Value) getLatestCompositeCandidate ()
    {
        return mNominationProtocol.getLatestCompositeCandidate();
    }

    /// returns the latest messages the slot emitted
    /// used externally by client code
    public SCPEnvelope[] getLatestMessagesSend () const
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
    public void setStateFromEnvelope (ref const(SCPEnvelope) e)
    {
        if (e.statement.nodeID == getSCP().getLocalNodeID() &&
            e.statement.slotIndex == mSlotIndex)
        {
            if (e.statement.pledges.type == SCPStatementType.SCP_ST_NOMINATE)
                mNominationProtocol.setStateFromEnvelope(e);
            else
                mBallotProtocol.setStateFromEnvelope(e);
        }
        else
        {
            //if (Logging.logTrace("SCP"))
            //    CLOG(TRACE, "SCP")
            //        << "Slot.setStateFromEnvelope invalid envelope"
            //        << " i: " << getSlotIndex() << " " << mSCP.envToStr(e);
        }
    }

    /// returns the latest messages known for this slot
    /// only used by external code
    public SCPEnvelope[] getCurrentState () const
    {
        SCPEnvelope[] res;
        res ~= mNominationProtocol.getCurrentState();
        res ~= mBallotProtocol.getCurrentState();
        return res;
    }

    // returns the latest message from a node
    // prefering ballots over nominations,
    // or null if not found
    public const(SCPEnvelope)* getLatestMessage (ref const(NodeID) id) const
    {
        if (auto m = mBallotProtocol.getLatestMessage(id))
            return m;

        return mNominationProtocol.getLatestMessage(id);
    }

    // returns messages that helped this slot externalize
    public SCPEnvelope[] getExternalizingState () const
    {
        return mBallotProtocol.getExternalizingState();
    }

    // records the statement in the historical record for this slot
    public void recordStatement (ref const(SCPStatement) st)
    {
        mStatementsHistory ~=
            HistoricalStatement(time(null), st, mFullyValidated);

        //CLOG(DEBUG, "SCP") << "new statement: "
        //                   << " i: " << getSlotIndex()
        //                   << " st: " << mSCP.envToStr(st, false) << " validated: "
        //                   << (mFullyValidated ? "true" : "false");
    }

    // Process a newly received envelope for this slot and update the state of
    // the slot accordingly.
    // self: set to true when node wants to record its own messages (potentially
    // triggering more transitions)
    public SCP.EnvelopeState processEnvelope (ref const(SCPEnvelope) envelope,
        bool self)
    {
        assert(envelope.statement.slotIndex == mSlotIndex);

        //if (Logging.logTrace("SCP"))
        //    log.trace("Slot.processEnvelope"
        //                       << " i: " << getSlotIndex() << " "
        //                       << mSCP.envToStr(envelope);

        try
        {

            if (envelope.statement.pledges.type ==
                SCPStatementType.SCP_ST_NOMINATE)
                return mNominationProtocol.processEnvelope(envelope);
            else
                return mBallotProtocol.processEnvelope(envelope, self);
        }
        catch (Throwable thr)
        {
            //CLOG(FATAL, "SCP") << "SCP context:";
            //CLOG(FATAL, "SCP") << getJsonInfo().toStyledString();
            //CLOG(FATAL, "SCP") << "Exception processing SCP messages at "
            //                   << mSlotIndex
            //                   << ", envelope: " << mSCP.envToStr(envelope);
            //CLOG(FATAL, "SCP") << REPORT_INTERNAL_BUG;

            throw thr;
        }
    }

    public bool abandonBallot ()
    {
        return mBallotProtocol.abandonBallot(0);
    }

    // bumps the ballot based on the local state and the value passed in:
    // in prepare phase, attempts to take value
    // otherwise, no-ops
    // force: when true, always bumps the value, otherwise only bumps
    // the state if no value was prepared
    public bool bumpState (const(Value) value, bool force)
    {
        return mBallotProtocol.bumpState(value, force);
    }

    // attempts to nominate a value for consensus
    public bool nominate (const(Value) value, const(Value) previousValue,
        bool timedout)
    {
        return mNominationProtocol.nominate(value, previousValue, timedout);
    }

    public void stopNomination ()
    {
        mNominationProtocol.stopNomination();
    }

    // returns the current nomination leaders
    public const(Set!NodeID) getNominationLeaders() const
    {
        return mNominationProtocol.getLeaders();
    }

    public bool isFullyValidated () const
    {
        return mFullyValidated;
    }

    public void setFullyValidated (bool fullyValidated)
    {
        mFullyValidated = fullyValidated;
    }

    /* status methods */

    public size_t getStatementCount () const
    {
        return mStatementsHistory.length;
    }

    // returns the hash of the QuorumSet that should be downloaded
    // with the statement.
    // note: the companion hash for an EXTERNALIZE statement does
    // not match the hash of the QSet, but the hash of commitQuorumSetHash
    public static Hash getCompanionQuorumSetHashFromStatement (
        ref const(SCPStatement) st)
    {
        switch (st.pledges.type)
        {
            case SCPStatementType.SCP_ST_PREPARE:
                return st.pledges.prepare_.quorumSetHash;

            case SCPStatementType.SCP_ST_CONFIRM:
                return st.pledges.confirm_.quorumSetHash;

            case SCPStatementType.SCP_ST_EXTERNALIZE:
                return st.pledges.externalize_.commitQuorumSetHash;

            case SCPStatementType.SCP_ST_NOMINATE:
                return st.pledges.nominate_.quorumSetHash;

            default:
                assert(0);
        }
    }

    // returns the values associated with the statement
    public static Value[] getStatementValues (ref const(SCPStatement) st)
    {
        if (st.pledges.type == SCPStatementType.SCP_ST_NOMINATE)
            return NominationProtocol.getStatementValues(st);
        else
            return [BallotProtocol.getWorkingBallot(st).value];
    }

    // returns the QuorumSet that should be used for a node given the
    // statement (singleton for externalize)
    public Nullable!SCPQuorumSet getQuorumSetFromStatement (
        ref const(SCPStatement) st)
    {
        SCPStatementType t = st.pledges.type;
        if (t == SCPStatementType.SCP_ST_EXTERNALIZE)
            return Nullable!SCPQuorumSet(LocalNode.getSingletonQSet(st.nodeID));

        Hash h;
        if (t == SCPStatementType.SCP_ST_PREPARE)
            h = st.pledges.prepare_.quorumSetHash;
        else if (t == SCPStatementType.SCP_ST_CONFIRM)
            h = st.pledges.confirm_.quorumSetHash;
        else if (t == SCPStatementType.SCP_ST_NOMINATE)
            h = st.pledges.nominate_.quorumSetHash;
        else
            assert(0);

        return getSCPDriver().getQSet(h);
    }

    // wraps a statement in an envelope (sign it, etc)
    public SCPEnvelope createEnvelope (ref const(SCPStatement) statement)
    {
        SCPEnvelope envelope;

        envelope.statement = statement;
        auto mySt = &envelope.statement;
        mySt.nodeID = getSCP().getLocalNodeID();
        mySt.slotIndex = getSlotIndex();
        mSCP.getDriver().signEnvelope(envelope);

        return envelope;
    }

    /* federated agreement helper functions */

    // returns true if the statement defined by voted and accepted
    // should be accepted
    public bool federatedAccept (StatementPredicate voted,
        StatementPredicate accepted, const(SCPEnvelope[NodeID]) envs)
    {
        // Checks if the nodes that claimed to accept the statement form a
        // v-blocking set
        if (LocalNode.isVBlocking(getLocalNode().getQuorumSet(), envs, accepted))
            return true;

        return LocalNode.isQuorum(
            getLocalNode().getQuorumSet(), envs,
            &this.getQuorumSetFromStatement,
            // ratify filter - accepted / voted form a quorum
            (ref const(SCPStatement) st) => (accepted(st) || voted(st))
        );
    }

    // returns true if the statement defined by voted
    // is ratified
    public bool federatedRatify (StatementPredicate voted,
        const(SCPEnvelope[NodeID]) envs)
    {
        return LocalNode.isQuorum(
            getLocalNode().getQuorumSet(), envs,
            &this.getQuorumSetFromStatement, voted);
    }

    public LocalNode getLocalNode ()
    {
        return mSCP.getLocalNode();
    }

    /// only used by external code
    protected SCPEnvelope[] getEntireCurrentState ()
    {
        bool old = mFullyValidated;
        // fake fully validated to force returning all envelopes
        mFullyValidated = true;
        auto r = getCurrentState();
        mFullyValidated = old;
        return r;
    }
}

unittest
{
    alias Hash = ubyte[64];
    alias uint256 = ubyte[32];
    alias uint512 = ubyte[64];
    alias Value = ubyte[];

    static struct PublicKey
    {
        int opCmp (const ref PublicKey rhs) inout
        {
            return this.ed25519 < rhs.ed25519;
        }

        uint256 ed25519;
    }

    alias NodeID = PublicKey;
    alias Signature = ubyte[64];
    static Hash getHashOf (Args...)(Args args) { return Hash.init; }
    import std.container;
    alias Set (T) = RedBlackTree!(const(T));

    alias SlotT!(NodeID, Hash, Value, Signature, Set, getHashOf) Slot;
}
