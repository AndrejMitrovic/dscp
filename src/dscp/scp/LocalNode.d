// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.LocalNode;

import dscp.crypto.Hash;
import dscp.scp.SCP;
import dscp.scp.QuorumSetUtils;
import dscp.util.numeric;
import dscp.xdr.Stellar_types;
import dscp.xdr.Stellar_SCP;

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
    SCPQuorumSet mSingleQSet; // {{mNodeID}}

    SCP mSCP;

  public:
    this (ref const(NodeID) nodeID, bool isValidator,
        ref SCPQuorumSet qSet, SCP scp)
    {
        mNodeID = nodeID;
        mIsValidator = isValidator;
        mQSet = qSet;
        mSCP = scp;
        normalizeQSet(mQSet);
        mQSetHash = getHashOf(mQSet);

        //CLOG(INFO, "SCP") << "LocalNode.LocalNode"
        //                  << "@" << KeyUtils.toShortString(mNodeID)
        //                  << " qSet: " << hexAbbrev(mQSetHash);

        mSingleQSet = buildSingletonQSet(mNodeID);
        gSingleQSetHash = getHashOf(mSingleQSet);
    }

    ref const(NodeID) getNodeID ();

    void updateQuorumSet (ref SCPQuorumSet qSet)
    {
        mQSetHash = getHashOf(qSet);
        mQSet = qSet;
    }

    ref const(SCPQuorumSet) getQuorumSet ()
    {
        return mQSet;
    }

    ref const(Hash) getQuorumSetHash ()
    {
        return mQSetHash;
    }

    bool isValidator ();

    // returns the quorum set {{X}}
    static SCPQuorumSet getSingletonQSet (ref const(NodeID) nodeID)
    {
        return buildSingletonQSet(nodeID);
    }

    // runs proc over all nodes contained in qset
    static void forAllNodes (ref const(SCPQuorumSet) qset,
        void delegate (ref const(NodeID)) proc)
    {
        foreach (const n; qset.validators)
            proc(n);

        foreach (const ref q; qset.innerSets)
            forAllNodes(q, proc);
    }

    // returns the weight of the node within the qset
    // normalized between 0-UINT64_MAX
    static uint64 getNodeWeight(ref const(NodeID) nodeID, ref const(SCPQuorumSet) qset)
    {
        uint64 n = qset.threshold;
        uint64 d = qset.innerSets.length + qset.validators.length;
        uint64 res;

        foreach (const ref qsetNode; qset.validators)
        {
            if (qsetNode == nodeID)
            {
                res = computeWeight(ulong.max, d, n);
                return res;
            }
        }

        foreach (const q; qset.innerSets)
        {
            uint64 leafW = getNodeWeight(nodeID, q);
            if (leafW)
            {
                res = computeWeight(leafW, d, n);
                return res;
            }
        }

        return 0;
    }

    // Tests this node against nodeSet for the specified qSethash.
    static bool isQuorumSlice(ref const(SCPQuorumSet) qSet,
                              const(NodeID)[] nodeSet);
    static bool isVBlocking(ref const(SCPQuorumSet) qSet,
                            const(NodeID)[] nodeSet);

    // Tests this node against a map of nodeID . T for the specified qSetHash.

    // `isVBlocking` tests if the filtered nodes V are a v-blocking set for
    // this node.
    static bool
    isVBlocking(ref const(SCPQuorumSet) qSet,
                const(SCPEnvelope[NodeID]) map,
                bool delegate (ref const(SCPStatement)) filter
                //= (ref const s) => true  // todo: can't use context here
                );

    // `isQuorum` tests if the filtered nodes V form a quorum
    // (meaning for each v \in V there is q \in Q(v)
    // included in V and we have quorum on V for qSetHash). `qfun` extracts the
    // SCPQuorumSetPtr from the SCPStatement for its associated node in map
    // (required for transitivity)
    static bool isQuorum (ref const(SCPQuorumSet) qSet,
        const(SCPEnvelope[NodeID]) map,
        SCPQuorumSet delegate (ref const(SCPStatement)) qfun,
        bool delegate (ref const(SCPStatement)) filter
            //= (ref const s) => true  // todo: can't use context here
            );

    // computes the distance to the set of v-blocking sets given
    // a set of nodes that agree (but can fail)
    // excluded, if set will be skipped altogether
    static NodeID[]
    findClosestVBlocking(ref const(SCPQuorumSet) qset,
                         const(set!NodeID) nodes, const(NodeID)* excluded);

    static NodeID[] findClosestVBlocking(
        ref const(SCPQuorumSet) qset, const(SCPEnvelope[NodeID]) map,
        bool delegate (ref const(SCPStatement)) filter,
        //= (ref const s) => true  // todo: can't use context here
        const(NodeID)* excluded = null);

    string to_string(ref const(SCPQuorumSet) qSet) const;

    static uint64 computeWeight(uint64 m, uint64 total, uint64 threshold)
    {
        uint64 res;
        assert(threshold <= total);
        bigDivide(res, m, threshold, total, Rounding.ROUND_UP);
        return res;
    }

  protected:
    // returns a quorum set {{ nodeID }}
    static SCPQuorumSet buildSingletonQSet(ref const(NodeID) nodeID)
    {
        SCPQuorumSet qSet;
        qSet.threshold = 1;
        qSet.validators ~= nodeID;
        return qSet;
    }

    // called recursively
    static bool isQuorumSliceInternal(ref const(SCPQuorumSet) qset,
                                      const(NodeID)[] nodeSet)
    {
        long thresholdLeft = qset.threshold;
        foreach (const validator; qset.validators)
        {
            if (nodeSet.canFind(validator))
            {
                thresholdLeft--;
                if (thresholdLeft <= 0)
                    return true;
            }
        }

        foreach (const inner; qset.innerSets)
        {
            if (isQuorumSliceInternal(inner, nodeSet))
            {
                thresholdLeft--;
                if (thresholdLeft <= 0)
                {
                    return true;
                }
            }
        }
        return false;
    }

    static bool isVBlockingInternal(ref const(SCPQuorumSet) qset,
                                    const(NodeID)[] nodeSet);
}
