// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.LocalNode;

import dscp.scp.SCP;

/**
 * This is one Node in the stellar network
 */
class LocalNode
{
  protected:
    const NodeID mNodeID;
    const bool mIsValidator;
    SCPQuorumSet mQSet;
    Hash mQSetHash;

    // alternative qset used during externalize {{mNodeID}}
    Hash gSingleQSetHash;                      // hash of the singleton qset
    SCPQuorumSet* mSingleQSet; // {{mNodeID}}

    SCP* mSCP;

  public:
    this (ref const(NodeID) nodeID, bool isValidator,
        ref const(SCPQuorumSet) qSet, SCP* scp);

    ref const(NodeID) getNodeID ();

    void updateQuorumSet (ref const(SCPQuorumSet) qSet);

    ref const(SCPQuorumSet) getQuorumSet ();
    ref const(Hash) getQuorumSetHash ();
    bool isValidator ();

    // returns the quorum set {{X}}
    static SCPQuorumSetPtr getSingletonQSet (ref const(NodeID) nodeID);

    // runs proc over all nodes contained in qset
    static void forAllNodes (ref const(SCPQuorumSet) qset,
        void delegate (ref const(NodeID)) proc);

    // returns the weight of the node within the qset
    // normalized between 0-UINT64_MAX
    static uint64 getNodeWeight(ref const(NodeID) nodeID, ref const(SCPQuorumSet) qset);

    // Tests this node against nodeSet for the specified qSethash.
    static bool isQuorumSlice(ref const(SCPQuorumSet) qSet,
                              const(NodeID)[] nodeSet);
    static bool isVBlocking(ref const(SCPQuorumSet) qSet,
                            const(NodeID)[] nodeSet);

    // Tests this node against a map of nodeID -> T for the specified qSetHash.

    // `isVBlocking` tests if the filtered nodes V are a v-blocking set for
    // this node.
    static bool
    isVBlocking(ref const(SCPQuorumSet) qSet,
                const(SCPEnvelope[NodeID]) map,
                bool delegate (ref const(SCPStatement)) filter =
                    (ref const s) => true);

    // `isQuorum` tests if the filtered nodes V form a quorum
    // (meaning for each v \in V there is q \in Q(v)
    // included in V and we have quorum on V for qSetHash). `qfun` extracts the
    // SCPQuorumSetPtr from the SCPStatement for its associated node in map
    // (required for transitivity)
    static bool isQuorum (ref const(SCPQuorumSet) qSet,
        const(SCPEnvelope[NodeID]) map,
        SCPQuorumSetPtr delegate (ref const(SCPStatement)) qfun,
        bool delegate (ref const(SCPStatement)) filter =
            (ref const s) => true);

    // computes the distance to the set of v-blocking sets given
    // a set of nodes that agree (but can fail)
    // excluded, if set will be skipped altogether
    static NodeID[]
    findClosestVBlocking(ref const(SCPQuorumSet) qset,
                         set!NodeID const& nodes, const(NodeID)* excluded);

    static NodeID[] findClosestVBlocking(
        ref const(SCPQuorumSet) qset, const(SCPEnvelope[NodeID]) map,
        bool delegate (ref const(SCPStatement)) filter = (ref const s) => true,
        const(NodeID)* excluded = null);

    string to_string(ref const(SCPQuorumSet) qSet) const;

    static uint64 computeWeight(uint64 m, uint64 total, uint64 threshold);

  protected:
    // returns a quorum set {{ nodeID }}
    static SCPQuorumSet buildSingletonQSet(ref const(NodeID) nodeID);

    // called recursively
    static bool isQuorumSliceInternal(ref const(SCPQuorumSet) qset,
                                      const(NodeID)[] nodeSet);
    static bool isVBlockingInternal(ref const(SCPQuorumSet) qset,
                                    const(NodeID)[] nodeSet);
}
