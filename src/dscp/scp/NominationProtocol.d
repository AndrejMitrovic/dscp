// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.NominationProtocol;

import dscp.scp.LocalNode;
import dscp.scp.SCP;
import dscp.scp.SCPDriver;
import dscp.scp.Slot;
import dscp.scp.QuorumSetUtils;
import dscp.util.Log;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import std.algorithm;
import std.range;

import core.time;

class NominationProtocolT (NodeID, Hash, Value, Signature, alias Set, alias makeSet, alias getHashOf, alias hashPart, alias duplicate)
{
    public alias LocalNode = LocalNodeT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate);
    public alias SCPStatement = SCPStatementT!(NodeID, Hash, Value);
    public alias Slot = SlotT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate);
    public alias SCP = SCPT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate);
    public alias SCPEnvelope = SCPEnvelopeT!(NodeID, Hash, Value, Signature);
    public alias SCPNomination = SCPNominationT!(Hash, Value);
    public alias SCPQuorumSet = SCPQuorumSetT!(NodeID, hashPart);
    public alias PublicKey = NodeID;
    public alias StatementPredicate = bool delegate (ref const(SCPStatement));

    protected Slot mSlot;
    protected int32 mRoundNumber;
    protected Set!Value mVotes;                       // X
    protected Set!Value mAccepted;                    // Y
    protected Set!Value mCandidates;                  // Z
    protected SCPEnvelope[NodeID] mLatestNominations; // N

    protected SCPEnvelope* mLastEnvelope; // last envelope emitted by this node

    // nodes from quorum set that have the highest priority this round
    protected Set!NodeID mRoundLeaders;

    // true if 'nominate' was called
    protected bool mNominationStarted;

    // the latest (if any) candidate value
    protected Value mLatestCompositeCandidate;

    // the value from the previous slot
    protected Value mPreviousValue;

    public this (Slot slot)
    {
        this.mSlot = slot;
        this.mVotes = makeSet!Value;
        this.mAccepted = makeSet!Value;
        this.mCandidates = makeSet!Value;
        this.mRoundLeaders = makeSet!NodeID;
    }

    public SCP.EnvelopeState processEnvelope (ref const(SCPEnvelope) envelope)
    {
        if (!this.isNewerStatement(envelope.statement.nodeID,
            envelope.statement.pledges.nominate_))
            return SCP.EnvelopeState.INVALID;

        if (!this.isSane(envelope.statement))
        {
            log.trace("NominationProtocol: message didn't pass sanity check");
            return SCP.EnvelopeState.INVALID;
        }

        this.recordEnvelope(envelope);

        // valid, but message came too soon -> we're not interested in it
        if (!this.mNominationStarted)
            return SCP.EnvelopeState.VALID;

        bool modified; // tracks if we should emit a new nomination message
        bool newCandidates = false;

        // attempts to promote some of the votes to accepted
        foreach (v; envelope.statement.pledges.nominate_.votes)
        {
            if (v in this.mAccepted)
                continue;  // v is already accepted

            if (this.mSlot.federatedAccept(
                (ref const(SCPStatement) st) {
                    return st.pledges.nominate_.votes.canFind(v);
                },
                (ref const(SCPStatement) st) => acceptPredicate(v, st),
                mLatestNominations))
            {
                auto vl = this.validateValue(v);
                if (vl == ValidationLevel.kFullyValidatedValue)
                {
                    this.mAccepted.insert(v);
                    this.mVotes.insert(v);
                    modified = true;
                }
                else
                {
                    // the value made it pretty far:
                    // see if we can vote for a variation that
                    // we consider valid
                    Value toVote;
                    toVote = this.extractValidValue(v);
                    if (!toVote.empty())
                    {
                        if (toVote !in this.mVotes)
                        {
                            this.mVotes.insert(duplicate(toVote));
                            modified = true;
                        }
                    }
                }
            }
        }

        // attempts to promote accepted values to candidates
        foreach (a; this.mAccepted[])
        {
            if (a in this.mCandidates)
                continue;

            if (this.mSlot.federatedRatify(
                (ref const(SCPStatement) st) => acceptPredicate(a, st),
                mLatestNominations))
            {
                mCandidates.insert(a);
                newCandidates = true;
            }
        }

        // only take round leader votes if we're still looking for
        // candidates
        if (mCandidates.empty() && envelope.statement.nodeID in mRoundLeaders)
        {
            Value newVote = getNewValueFromNomination(envelope.statement.pledges.nominate_);
            if (!newVote.empty())
            {
                mVotes.insert(duplicate(newVote));
                modified = true;
                mSlot.getSCPDriver().nominatingValue(
                    mSlot.getSlotIndex(), newVote);
            }
        }

        if (modified)
            this.emitNomination();

        if (newCandidates)
        {
            this.mLatestCompositeCandidate =
                this.mSlot.getSCPDriver().combineCandidates(
                    this.mSlot.getSlotIndex(), this.mCandidates);

            this.mSlot.getSCPDriver().updatedCandidateValue(
                this.mSlot.getSlotIndex(), this.mLatestCompositeCandidate);

            const bool DontForce = false;
            this.mSlot.bumpState(this.mLatestCompositeCandidate, DontForce);
        }

        return SCP.EnvelopeState.VALID;
    }

    public static const(Value)[] getStatementValues (ref const(SCPStatement) st)
    {
        const(Value)[] res;
        applyAll(st.pledges.nominate_, (ref const(Value) v) { res ~= v; });
        return res;
    }

    // attempts to nominate a value for consensus
    public bool nominate (ref const(Value) value,
        ref const(Value) previousValue, bool timedout)
    {
        log.trace("NominationProtocol.nominate (%s) %s",
            mRoundNumber, mSlot.getSCP().getValueString(value));

        if (timedout && !this.mNominationStarted)
        {
            log.trace("NominationProtocol.nominate (TIMED OUT)");
            return false;
        }

        this.mNominationStarted = true;
        this.mPreviousValue = duplicate(previousValue);
        this.mRoundNumber++;
        this.updateRoundLeaders();

        bool updated = false;
        Value nominatingValue;

        // if we're leader, add our value
        if (this.mSlot.getLocalNode().getNodeID() in this.mRoundLeaders)
        {
            if (value !in this.mVotes)
            {
                this.mVotes.insert(value);
                updated = true;
            }

            nominatingValue = duplicate(value);
        }

        // add a few more values from other leaders
        foreach (leader; this.mRoundLeaders[])
        {
            if (auto nom_value = leader in this.mLatestNominations)
            {
                nominatingValue = this.getNewValueFromNomination(
                    nom_value.statement.pledges.nominate_);
                if (!nominatingValue.empty())
                {
                    this.mVotes.insert(duplicate(nominatingValue));
                    updated = true;
                }
            }
        }

        Duration timeout = mSlot.getSCPDriver().computeTimeout(mRoundNumber);

        mSlot.getSCPDriver().nominatingValue(
            this.mSlot.getSlotIndex(), nominatingValue);

        const bool HasTimedOut = true;
        mSlot.getSCPDriver().setupTimer(
            mSlot.getSlotIndex(), TimerID.NOMINATION_TIMER, timeout,
            () { mSlot.nominate(value, previousValue, HasTimedOut); });

        if (updated)
            this.emitNomination();
        else
            log.trace("NominationProtocol.nominate (SKIPPED)");

        return updated;
    }

    // stops the nomination protocol
    public void stopNomination ()
    {
        this.mNominationStarted = false;
    }

    // return the current leaders
    public const(Set!NodeID) getLeaders () const
    {
        return this.mRoundLeaders;
    }

    public ref const(Value) getLatestCompositeCandidate () const
    {
        return this.mLatestCompositeCandidate;
    }

    /// used externally by client code
    public const(SCPEnvelope)* getLastMessageSend () const
    {
        return this.mLastEnvelope.get();
    }

    /// Only used during boot-up if we want to load old SCP state
    public void setStateFromEnvelope (ref const(SCPEnvelope) e)
    {
        if (this.mNominationStarted)
            assert(0, "Cannot set state after nomination is started");

        this.recordEnvelope(e);
        foreach (a; e.statement.pledges.nominate_.accepted)
            this.mAccepted.insert(a);

        foreach (v; e.statement.pledges.nominate_.votes)
            this.mVotes.insert(v);

        this.mLastEnvelope = new SCPEnvelope();
        *this.mLastEnvelope = duplicate(e);
    }

    /// only used by external code
    public const(SCPEnvelope)[] getCurrentState () const
    {
        const(SCPEnvelope)[] res;
        res.reserve(this.mLatestNominations.length);
        foreach (node_id, env; this.mLatestNominations)
        {
            // only return messages for self if the slot is fully validated
            if (node_id != this.mSlot.getSCP().getLocalNodeID() ||
                this.mSlot.isFullyValidated())
                res ~= env;
        }

        return res;
    }

    // returns the latest message from a node
    // or null if not found
    public const(SCPEnvelope)* getLatestMessage(ref const(NodeID) id) const
    {
        return id in this.mLatestNominations;
    }

    protected bool isNewerStatement (ref const(NodeID) nodeID,
        ref const(SCPNomination) st)
    {
        if (auto old = nodeID in this.mLatestNominations)
            return isNewerStatement(old.statement.pledges.nominate_, st);

        return true;
    }

    protected static bool isNewerStatement(ref const(SCPNomination) oldst,
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
    protected static bool isSubsetHelper (const(Value)[] p,
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

    protected ValidationLevel validateValue (ref const(Value) v)
    {
        const bool IsNomination = true;
        return this.mSlot.getSCPDriver().validateValue(
            mSlot.getSlotIndex(), v, IsNomination);
    }

    protected Value extractValidValue (ref const(Value) value)
    {
        return mSlot.getSCPDriver().extractValidValue(
            mSlot.getSlotIndex(), value);
    }

    protected bool isSane (ref const(SCPStatement) st)
    {
        if (st.pledges.nominate_.votes.length +
            st.pledges.nominate_.accepted.length == 0)
            return false;

        return st.pledges.nominate_.votes.isStrictlyMonotonic() &&
            st.pledges.nominate_.accepted.isStrictlyMonotonic();
    }

    // only called after a call to isNewerStatement so safe to replace the
    // mLatestNomination
    protected void recordEnvelope (ref const(SCPEnvelope) env)
    {
        this.mLatestNominations[env.statement.nodeID] = duplicate(env);
        this.mSlot.recordStatement(env.statement);
    }

    protected void emitNomination ()
    {
        SCPStatement st;
        st.nodeID = mSlot.getLocalNode().getNodeID();
        st.pledges.type_ = SCPStatementType.SCP_ST_NOMINATE;
        st.pledges.nominate_.quorumSetHash = this.mSlot.getLocalNode()
            .getQuorumSetHash();

        foreach (v; mVotes[])
            st.pledges.nominate_.votes ~= duplicate(v);

        foreach (a; mAccepted[])
            st.pledges.nominate_.accepted ~= duplicate(a);

        SCPEnvelope envelope = this.mSlot.createEnvelope(st);

        static bool IsFromSelf = true;
        if (mSlot.processEnvelope(envelope, IsFromSelf) !=
            SCP.EnvelopeState.VALID)
        {
            // there is a bug in the application if it queued up
            // a statement for itself that it considers invalid
            assert(0, "moved to a bad state (nomination)");
        }

        if (!this.mLastEnvelope ||
            isNewerStatement(mLastEnvelope.statement.pledges.nominate_,
                             st.pledges.nominate_))
        {
            this.mLastEnvelope = new SCPEnvelope();
            *this.mLastEnvelope = duplicate(envelope);

            if (this.mSlot.isFullyValidated())
                this.mSlot.getSCPDriver().emitEnvelope(envelope);
        }
    }

    // returns true if v is in the accepted list from the statement
    protected static bool acceptPredicate (ref const(Value) v,
        ref const(SCPStatement) st)
    {
        return st.pledges.nominate_.accepted.canFind(v);
    }

    // applies 'processor' to all values from the passed in nomination
    protected static void applyAll (ref const(SCPNomination) nom,
        void delegate(ref const(Value)) processor)
    {
        foreach (v; nom.votes)
            processor(v);

        foreach (a; nom.accepted)
            processor(a);
    }

    // updates the set of nodes that have priority over the others
    protected void updateRoundLeaders ()
    {
        uint32 threshold;
        PublicKey[] validators;
        SCPQuorumSet[] innerSets;

        const localQset = this.mSlot.getLocalNode().getQuorumSet();
        SCPQuorumSet myQSet = duplicate(localQset);

        // initialize priority with value derived from self
        Set!NodeID newRoundLeaders = makeSet!NodeID;
        auto localID = mSlot.getLocalNode().getNodeID();
        normalizeQSet(myQSet, &localID);

        newRoundLeaders.insert(localID);
        uint64 topPriority = this.getNodePriority(localID, myQSet);

        LocalNode.forAllNodes(myQSet, (ref const(NodeID) cur) {
            uint64 w = this.getNodePriority(cur, myQSet);
            if (w > topPriority)
            {
                topPriority = w;
                newRoundLeaders.clear();
            }

            if (w == topPriority && w > 0)
                newRoundLeaders.insert(cur);
        });

        // expand mRoundLeaders with the newly computed leaders
        foreach (new_leader; newRoundLeaders[])
            this.mRoundLeaders.insert(new_leader);

        log.trace("updateRoundLeaders: %s -> %s", newRoundLeaders.length,
            this.mRoundLeaders.length);

        foreach (rl; this.mRoundLeaders)
            log.trace("    leader %s",
                this.mSlot.getSCPDriver().toShortString(rl));
    }

    // computes Gi(isPriority?P:N, prevValue, mRoundNumber, nodeID)
    // from the paper
    protected uint64 hashNode (bool isPriority, ref const(NodeID) nodeID)
    {
        assert(!this.mPreviousValue.empty());
        return this.mSlot.getSCPDriver().computeHashNode(
            this.mSlot.getSlotIndex(), this.mPreviousValue,
            isPriority, this.mRoundNumber, nodeID);
    }

    // computes Gi(K, prevValue, mRoundNumber, value)
    protected uint64 hashValue (ref const(Value) value)
    {
        assert(!this.mPreviousValue.empty());
        return this.mSlot.getSCPDriver().computeValueHash(
            this.mSlot.getSlotIndex(), this.mPreviousValue, this.mRoundNumber,
            value);
    }

    protected uint64 getNodePriority (ref const(NodeID) nodeID,
        ref const(SCPQuorumSet) qset)
    {
        uint64 w;
        if (nodeID == this.mSlot.getLocalNode().getNodeID())
            w = ulong.max;  // local node is in all quorum sets
        else
            w = LocalNode.getNodeWeight(nodeID, qset);

        // if w > 0; w is inclusive here as
        // 0 <= hashNode <= ulong.max
        uint64 res;
        if (w > 0 && hashNode(false, nodeID) <= w)
            res = hashNode(true, nodeID);
        else
            res = 0;

        return res;
    }

    // returns the highest value that we don't have yet, that we should
    // vote for, extracted from a nomination.
    // returns the empty value if no new value was found
    protected Value getNewValueFromNomination (ref const(SCPNomination) nom)
    {
        // pick the highest value we don't have from the leader
        // sorted using hashValue.
        Value newVote;
        uint64 newHash = 0;

        applyAll(nom, (ref const(Value) value) {
            Value valueToNominate;
            auto vl = validateValue(value);
            if (vl == ValidationLevel.kFullyValidatedValue)
                valueToNominate = duplicate(value);
            else
                valueToNominate = extractValidValue(value);

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
    alias makeSet (T) = redBlackTree!(const(T));
    T duplicate (T)(T arg) { return arg; }
    void hashPart (void delegate(scope const(ubyte)[]) dg) const nothrow @safe @nogc {}
    alias NominationProtocolT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate) LN;
}
