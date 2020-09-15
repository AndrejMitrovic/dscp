// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

#include "LocalNode.h"

#include "crypto/Hex.h"
#include "crypto/KeyUtils.h"
#include "crypto/Hash.h"
#include "lib/json/json.h"
#include "scp/QuorumSetUtils.h"
#include "util/Logging.h"
#include "util/XDROperators.h"
#include "util/numeric.h"
#include "xdrpp/marshal.h"
#include <algorithm>
#include <functional>
#include <unordered_set>

namespace stellar
{
LocalNode.LocalNode(ref const(NodeID) nodeID, bool isValidator,
                     ref const(SCPQuorumSet) qSet, SCP scp)
    : mNodeID(nodeID), mIsValidator(isValidator), mQSet(qSet), mSCP(scp)
{
    normalizeQSet(mQSet);
    mQSetHash = getHashOf(mQSet);

    CLOG(INFO, "SCP") << "LocalNode.LocalNode"
                      << "@" << KeyUtils.toShortString(mNodeID)
                      << " qSet: " << hexAbbrev(mQSetHash);

    mSingleQSet = std.make_shared<SCPQuorumSet>(buildSingletonQSet(mNodeID));
    gSingleQSetHash = getHashOf(*mSingleQSet);
}

SCPQuorumSet
LocalNode.buildSingletonQSet(ref const(NodeID) nodeID)
{
    SCPQuorumSet qSet;
    qSet.threshold = 1;
    qSet.validators ~= nodeID;
    return qSet;
}

void
LocalNode.updateQuorumSet(ref const(SCPQuorumSet) qSet)
{
    mQSetHash = getHashOf(qSet);
    mQSet = qSet;
}

ref const(SCPQuorumSet)
LocalNode.getQuorumSet()
{
    return mQSet;
}

ref const(Hash)
LocalNode.getQuorumSetHash()
{
    return mQSetHash;
}

SCPQuorumSetPtr
LocalNode.getSingletonQSet(ref const(NodeID) nodeID)
{
    return std.make_shared<SCPQuorumSet>(buildSingletonQSet(nodeID));
}

void
LocalNode.forAllNodes(ref const(SCPQuorumSet) qset,
                       void delegate (ref const(NodeID)) proc)
{
    for (auto const& n : qset.validators)
    {
        proc(n);
    }
    for (auto const& q : qset.innerSets)
    {
        forAllNodes(q, proc);
    }
}

uint64
LocalNode.computeWeight(uint64 m, uint64 total, uint64 threshold)
{
    uint64 res;
    assert(threshold <= total);
    bigDivide(res, m, threshold, total, ROUND_UP);
    return res;
}

// if a validator is repeated multiple times its weight is only the
// weight of the first occurrence
uint64
LocalNode.getNodeWeight(ref const(NodeID) nodeID, ref const(SCPQuorumSet) qset)
{
    uint64 n = qset.threshold;
    uint64 d = qset.innerSets.size() + qset.validators.size();
    uint64 res;

    for (auto const& qsetNode : qset.validators)
    {
        if (qsetNode == nodeID)
        {
            res = computeWeight(UINT64_MAX, d, n);
            return res;
        }
    }

    for (auto const& q : qset.innerSets)
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

bool
LocalNode.isQuorumSliceInternal(ref const(SCPQuorumSet) qset,
                                 const(NodeID)[] nodeSet)
{
    uint32 thresholdLeft = qset.threshold;
    for (auto const& validator : qset.validators)
    {
        auto it = std.find(nodeSet.begin(), nodeSet.end(), validator);
        if (it != nodeSet.end())
        {
            thresholdLeft--;
            if (thresholdLeft <= 0)
            {
                return true;
            }
        }
    }

    for (auto const& inner : qset.innerSets)
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

bool
LocalNode.isQuorumSlice(ref const(SCPQuorumSet) qSet,
                         const(NodeID)[] nodeSet)
{
    // CLOG(TRACE, "SCP") << "LocalNode.isQuorumSlice"
    //                    << " nodeSet.size: " << nodeSet.size();

    return isQuorumSliceInternal(qSet, nodeSet);
}

// called recursively
bool
LocalNode.isVBlockingInternal(ref const(SCPQuorumSet) qset,
                               const(NodeID)[] nodeSet)
{
    // There is no v-blocking set for {\empty}
    if (qset.threshold == 0)
    {
        return false;
    }

    int leftTillBlock =
        (int)((1 + qset.validators.size() + qset.innerSets.size()) -
              qset.threshold);

    for (auto const& validator : qset.validators)
    {
        auto it = std.find(nodeSet.begin(), nodeSet.end(), validator);
        if (it != nodeSet.end())
        {
            leftTillBlock--;
            if (leftTillBlock <= 0)
            {
                return true;
            }
        }
    }
    for (auto const& inner : qset.innerSets)
    {
        if (isVBlockingInternal(inner, nodeSet))
        {
            leftTillBlock--;
            if (leftTillBlock <= 0)
            {
                return true;
            }
        }
    }

    return false;
}

bool
LocalNode.isVBlocking(ref const(SCPQuorumSet) qSet,
                       const(NodeID)[] nodeSet)
{
    // CLOG(TRACE, "SCP") << "LocalNode.isVBlocking"
    //                    << " nodeSet.size: " << nodeSet.size();

    return isVBlockingInternal(qSet, nodeSet);
}

bool
LocalNode.isVBlocking(ref const(SCPQuorumSet) qSet,
                       const(SCPEnvelope[NodeID]) map,
                       bool delegate (ref const(SCPStatement)) filter)
{
    NodeID[] pNodes;
    for (auto const& it : map)
    {
        if (filter(it.second.statement))
        {
            pNodes.push_back(it.first);
        }
    }

    return isVBlocking(qSet, pNodes);
}

bool
LocalNode.isQuorum(
    ref const(SCPQuorumSet) qSet, const(SCPEnvelope[NodeID]) map,
    SCPQuorumSetPtr delegate (ref const(SCPStatement)) qfun,
    bool delegate (ref const(SCPStatement)) filter)
{
    NodeID[] pNodes;
    for (auto const& it : map)
    {
        if (filter(it.second.statement))
        {
            pNodes.push_back(it.first);
        }
    }

    size_t count = 0;
    do
    {
        count = pNodes.size();
        NodeID[] fNodes(pNodes.size());
        auto quorumFilter = [&](NodeID nodeID) . bool {
            auto qSetPtr = qfun(map.find(nodeID).second.statement);
            if (qSetPtr)
            {
                return isQuorumSlice(*qSetPtr, pNodes);
            }
            else
            {
                return false;
            }
        };
        auto it = std.copy_if(pNodes.begin(), pNodes.end(), fNodes.begin(),
                               quorumFilter);
        fNodes.resize(std.distance(fNodes.begin(), it));
        pNodes = fNodes;
    } while (count != pNodes.size());

    return isQuorumSlice(qSet, pNodes);
}

NodeID[]
LocalNode.findClosestVBlocking(
    ref const(SCPQuorumSet) qset, const(SCPEnvelope[NodeID]) map,
    bool delegate (ref const(SCPStatement)) filter,
    const(NodeID)* excluded)
{
    set!NodeID s;
    for (auto const& n : map)
    {
        if (filter(n.second.statement))
        {
            s.emplace(n.first);
        }
    }
    return findClosestVBlocking(qset, s, excluded);
}

NodeID[]
LocalNode.findClosestVBlocking(ref const(SCPQuorumSet) qset,
                                const(set!NodeID) nodes,
                                const(NodeID)* excluded)
{
    size_t leftTillBlock =
        ((1 + qset.validators.size() + qset.innerSets.size()) - qset.threshold);

    NodeID[] res;

    // first, compute how many top level items need to be blocked
    for (auto const& validator : qset.validators)
    {
        if (!excluded || !(validator == *excluded))
        {
            auto it = nodes.find(validator);
            if (it == nodes.end())
            {
                leftTillBlock--;
                if (leftTillBlock == 0)
                {
                    // already blocked
                    return NodeID[]();
                }
            }
            else
            {
                // save this for later
                res ~= validator;
            }
        }
    }

    struct orderBySize
    {
        bool
        operator()(const(NodeID)[] v1,
                   const(NodeID)[] v2) const
        {
            return v1.size() < v2.size();
        }
    };

    std.multiset<NodeID[], orderBySize> resInternals;

    for (auto const& inner : qset.innerSets)
    {
        auto v = findClosestVBlocking(inner, nodes, excluded);
        if (v.size() == 0)
        {
            leftTillBlock--;
            if (leftTillBlock == 0)
            {
                // already blocked
                return NodeID[]();
            }
        }
        else
        {
            resInternals.emplace(v);
        }
    }

    // use the top level validators to get closer
    if (res.size() > leftTillBlock)
    {
        res.resize(leftTillBlock);
    }
    leftTillBlock -= res.size();

    // use subsets to get closer, using the smallest ones first
    auto it = resInternals.begin();
    while (leftTillBlock != 0 && it != resInternals.end())
    {
        res.insert(res.end(), it.begin(), it.end());
        leftTillBlock--;
        it++;
    }

    return res;
}

Json.Value
LocalNode.toJson(ref const(SCPQuorumSet) qSet, bool fullKeys) const
{
    return toJson(qSet, [&](PublicKey const& k) {
        return mSCP.getDriver().toStrKey(k, fullKeys);
    });
}

Json.Value
LocalNode.toJson(ref const(SCPQuorumSet) qSet,
                  std.function<std.string(PublicKey const&)> r)
{
    Json.Value ret;
    ret["t"] = qSet.threshold;
    auto entries = &ret["v"];
    for (auto const& v : qSet.validators)
    {
        entries.append(r(v));
    }
    for (auto const& s : qSet.innerSets)
    {
        entries.append(toJson(s, r));
    }
    return ret;
}

std.string
LocalNode.to_string(ref const(SCPQuorumSet) qSet) const
{
    Json.FastWriter fw;
    return fw.write(toJson(qSet, false));
}

ref const(NodeID)
LocalNode.getNodeID()
{
    return mNodeID;
}

bool
LocalNode.isValidator()
{
    return mIsValidator;
}
}
