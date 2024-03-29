// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.LocalNode;

import dscp.scp.SCP;
import dscp.scp.QuorumSetUtils;
import dscp.xdr.Stellar_types;
import dscp.xdr.Stellar_SCP;

import std.algorithm;
import std.conv;
import std.range;

/**
 * This is one Node in the stellar network
 */
class LocalNodeT (NodeID, Hash, Value, Signature, alias Set, alias makeSet, alias getHashOf, alias hashPart, alias duplicate, Logger)
{
    public alias SCPQuorumSet = SCPQuorumSetT!(NodeID, hashPart);
    public alias SCPEnvelope = SCPEnvelopeT!(NodeID, Hash, Value, Signature);
    public alias SCPStatement = SCPStatementT!(NodeID, Hash, Value);
    public alias SCP = SCPT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate, Logger);

    protected const NodeID mNodeID;
    protected const bool mIsValidator;
    protected SCPQuorumSet mQSet;
    protected Hash mQSetHash;

    // alternative qset used during externalize {{mNodeID}}
    protected Hash gSingleQSetHash;      // hash of the singleton qset
    protected SCPQuorumSet* mSingleQSet;  // {{mNodeID}}
    protected SCP mSCP;

    private Logger log;

    public this (ref const(NodeID) nodeID, bool isValidator,
        ref SCPQuorumSet qSet, SCP scp, Logger log)
    {
        mNodeID = nodeID;
        mIsValidator = isValidator;
        mQSet = qSet;
        mSCP = scp;
        normalizeQSet(mQSet);
        mQSetHash = getHashOf(mQSet);
        this.log = log;

        this.log.info("LocalNode.LocalNode@%s qset: %s", mNodeID, mQSetHash);
        mSingleQSet = getSingletonQSet(mNodeID);
        gSingleQSetHash = getHashOf(*mSingleQSet);
    }

    public ref const(NodeID) getNodeID () inout
    {
        return mNodeID;
    }

    public void updateQuorumSet (ref SCPQuorumSet qSet) nothrow
    {
        scope (failure) assert(0);
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

    public bool isValidator ()
    {
        return mIsValidator;
    }

    // runs proc over all nodes contained in qset
    public static void forAllNodes (ref const(SCPQuorumSet) qset,
        void delegate (ref const(NodeID)) proc)
    {
        foreach (const n; qset.validators)
            proc(n);

        foreach (const ref q; qset.innerSets)
            forAllNodes(q, proc);
    }

    // returns the weight of the node within the qset
    // normalized between 0-UINT64_MAX
    public static uint64 getNodeWeight (ref const(NodeID) nodeID,
        ref const(SCPQuorumSet) qset)
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
    public static bool isQuorumSlice (ref const(SCPQuorumSet) qSet,
        const(NodeID)[] nodeSet)
    {
        auto res = isQuorumSliceInternal(qSet, nodeSet);
        //this.log.trace("LocalNode.isQuorumSlice nodeSet.size: %s: %s",
        //    nodeSet.length, res);
        return res;
    }

    public static bool isVBlocking (ref const(SCPQuorumSet) qSet,
        const(NodeID)[] nodeSet)
    {
        return isVBlockingInternal(qSet, nodeSet);
    }

    // Tests this node against a map of nodeID -> T for the specified qSetHash.

    // `isVBlocking` tests if the filtered nodes V are a v-blocking set for
    // this node.
    public static bool isVBlocking (ref const(SCPQuorumSet) qSet,
        const(SCPEnvelope[NodeID]) map,
        bool delegate (ref const(SCPStatement)) filter)
    {
        NodeID[] pNodes;
        foreach (node_id, env; map)
        {
            if (filter(env.statement))
                pNodes ~= node_id;
        }

        return isVBlocking(qSet, pNodes);
    }

    // `isQuorum` tests if the filtered nodes V form a quorum
    // (meaning for each v \in V there is q \in Q(v)
    // included in V and we have quorum on V for qSetHash). `qfun` extracts the
    // SCPQuorumSetPtr from the SCPStatement for its associated node in map
    // (required for transitivity)
    public static bool isQuorum (ref const(SCPQuorumSet) qSet,
        const(SCPEnvelope[NodeID]) map,
        SCPQuorumSet* delegate (ref const(SCPStatement)) qfun,
        bool delegate (ref const(SCPStatement)) filter)
    {
        NodeID[] pNodes;
        foreach (node_id, env; map)
        {
            if (filter(env.statement))
                pNodes ~= node_id;
        }

        size_t count = 0;
        do
        {
            count = pNodes.length;
            NodeID[] fNodes;
            auto quorumFilter = (NodeID nodeID)
            {
                if (auto qSetPtr = qfun(map[nodeID].statement))
                    return isQuorumSlice(*qSetPtr, pNodes);
                else
                    return false;
            };

            foreach (node; pNodes)
                if (quorumFilter(node))
                    fNodes ~= node;

            pNodes = fNodes;
        } while (count != pNodes.length);

        return isQuorumSlice(qSet, pNodes);
    }

    // computes the distance to the set of v-blocking sets given
    // a set of nodes that agree (but can fail)
    // excluded, if set will be skipped altogether
    public static NodeID[] findClosestVBlocking (ref const(SCPQuorumSet) qset,
        const(Set!NodeID) nodes, const(NodeID)* excluded)
    {
        size_t leftTillBlock =
            ((1 + qset.validators.length + qset.innerSets.length) - qset.threshold);

        NodeID[] res;

        // first, compute how many top level items need to be blocked
        foreach (validator; qset.validators)
        {
            if (!excluded || !(validator == *excluded))
            {
                // save this for later
                if (validator in nodes)
                {
                    res ~= validator;
                }
                else
                {
                    leftTillBlock--;
                    if (leftTillBlock == 0)
                    {
                        // already blocked
                        return null;
                    }
                }
            }
        }

        NodeID[][] resInternals;
        foreach (inner; qset.innerSets)
        {
            auto v = findClosestVBlocking(inner, nodes, excluded);
            if (v.length == 0)
            {
                leftTillBlock--;
                if (leftTillBlock == 0)
                {
                    // already blocked
                    return null;
                }
            }
            else
            {
                resInternals ~= v;
                sort!((a, b) => a.length < b.length)(resInternals);
            }
        }

        // use the top level validators to get closer
        if (res.length > leftTillBlock)
            res.length = leftTillBlock;
        leftTillBlock -= res.length;

        // use subsets to get closer, using the smallest ones first
        while (leftTillBlock != 0 && !resInternals.empty)
        {
            auto vnodes = resInternals.front;
            res ~= vnodes;
            leftTillBlock--;
            resInternals.popFront();
        }

        return res;
    }

    public static NodeID[] findClosestVBlocking ( ref const(SCPQuorumSet) qset,
        const(SCPEnvelope[NodeID]) map,
        bool delegate (ref const(SCPStatement)) filter,
        const(NodeID)* excluded = null)
    {
        Set!NodeID s = makeSet!NodeID;
        foreach (node_id, env; map)
        {
            if (filter(env.statement))
                s.insert(node_id);
        }

        return findClosestVBlocking(qset, s, excluded);
    }

    public static uint64 computeWeight (uint64 m, uint64 total,
        uint64 threshold)
    {
        uint64 res;
        assert(threshold <= total);
        // calculates A*B/C when A*B overflows 64bits
        res = (m * threshold) / total;
        //bigDivide(res, m, threshold, total, Rounding.ROUND_UP);
        return res;
    }

    // returns a quorum set {{ nodeID }}
    public static SCPQuorumSet* getSingletonQSet (ref const(NodeID) nodeID)
    {
        SCPQuorumSet* qSet = new SCPQuorumSet;
        qSet.threshold = 1;
        qSet.validators ~= nodeID;
        return qSet;
    }

    // called recursively
    protected static bool isQuorumSliceInternal (ref const(SCPQuorumSet) qset,
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
                    return true;
            }
        }

        return false;
    }

    // called recursively
    protected static bool isVBlockingInternal (ref const(SCPQuorumSet) qset,
        const(NodeID)[] nodeSet)
    {
        // There is no v-blocking set for {\empty}
        if (qset.threshold == 0)
            return false;

        int leftTillBlock =
            to!int((1 + qset.validators.length + qset.innerSets.length) -
                    qset.threshold);

        foreach (validator; qset.validators)
        {
            if (nodeSet.canFind(validator))
            {
                leftTillBlock--;
                if (leftTillBlock <= 0)
                    return true;
            }
        }

        foreach (inner; qset.innerSets)
        {
            if (isVBlockingInternal(inner, nodeSet))
            {
                leftTillBlock--;
                if (leftTillBlock <= 0)
                    return true;
            }
        }

        return false;
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

    static struct Logger
    {
        void trace (T...)(T t) { }
        void info (T...)(T t) { }
        void error (T...)(T t) { }
    }

    alias NodeID = PublicKey;
    alias Signature = ubyte[64];
    static Hash getHashOf (Args...)(Args args) { return Hash.init; }
    import std.container;
    alias Set (T) = RedBlackTree!(const(T));
    alias makeSet (T) = redBlackTree!(const(T));
    import std.traits;
    static auto duplicate (T)(T arg)
    {
        static if (isArray!T)
            return arg.dup;
        else
            return cast(Unqual!T)arg;
    }
    static void hashPart (T)(T arg, void delegate(scope const(ubyte)[]) dg) nothrow @safe @nogc { }
    alias LocalNodeT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate, Logger) LN;
}
