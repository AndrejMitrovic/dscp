// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.NominationProtocol;

import dscp.scp.SCP;
import dscp.scp.SCPDriver;
import dscp.scp.Slot;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import std.algorithm;

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
                                 ref const(SCPNomination) st);

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

    SCPDriver.ValidationLevel validateValue(ref const(Value) v);
    Value extractValidValue(ref const(Value) value);

    bool isSane(ref const(SCPStatement) st);

    void recordEnvelope(ref const(SCPEnvelope) env);

    void emitNomination();

    // returns true if v is in the accepted list from the statement
    static bool acceptPredicate(ref const(Value) v, ref const(SCPStatement) st);

    // applies 'processor' to all values from the passed in nomination
    static void applyAll(ref const(SCPNomination) nom,
                         void delegate(ref const(Value) processor));

    // updates the set of nodes that have priority over the others
    void updateRoundLeaders();

    // computes Gi(isPriority?P:N, prevValue, mRoundNumber, nodeID)
    // from the paper
    uint64 hashNode(bool isPriority, ref const(NodeID) nodeID);

    // computes Gi(K, prevValue, mRoundNumber, value)
    uint64 hashValue(ref const(Value) value);

    uint64 getNodePriority(ref const(NodeID) nodeID, ref const(SCPQuorumSet) qset);

    // returns the highest value that we don't have yet, that we should
    // vote for, extracted from a nomination.
    // returns the empty value if no new value was found
    Value getNewValueFromNomination(ref const(SCPNomination) nom);

  public:
    this(Slot slot)
    {
        mSlot = slot;
        mRoundNumber = 0;
        mNominationStarted = false;
    }

    SCP.EnvelopeState processEnvelope(ref const(SCPEnvelope) envelope);

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
