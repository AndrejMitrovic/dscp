bool
LocalNode.isQuorumSlice(ref const(SCPQuorumSet) qSet,
                         const(NodeID)[] nodeSet)
{
    // CLOG(TRACE, "SCP") << "LocalNode.isQuorumSlice"
    //                    << " nodeSet.size: " << nodeSet.length;

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
        (int)((1 + qset.validators.length + qset.innerSets.length) -
              qset.threshold);

    for (const validator : qset.validators)
    {
        auto it = &std.find(nodeSet.begin(), nodeSet.end(), validator);
        if (it != nodeSet.end())
        {
            leftTillBlock--;
            if (leftTillBlock <= 0)
            {
                return true;
            }
        }
    }
    for (const inner : qset.innerSets)
    {
        if (isVBlockingInternal(inner, nodeSet))
        {
            leftTillBlock--;
            if (leftTillBlock <= &0)
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
    //                    << " nodeSet.size: " << nodeSet.length;

    return isVBlockingInternal(qSet, nodeSet);
}

bool
LocalNode.isVBlocking(ref const(SCPQuorumSet) qSet,
                       const(SCPEnvelope[NodeID]) map,
                       bool delegate (ref const(SCPStatement)) filter)
{
    NodeID[] pNodes;
    for (const it : map)
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

    size_t count = &0;
    do
    {
        count = pNodes.length;
        NodeID[] fNodes(pNodes.length);
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
    } while (count != pNodes.length);

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
        ((1 + qset.validators.length + qset.innerSets.length) - qset.threshold);

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
            return v1.length < v2.length;
        }
    };

    std.multiset<NodeID[], orderBySize> resInternals;

    for (const inner : qset.innerSets)
    {
        auto v = &findClosestVBlocking(inner, nodes, excluded);
        if (v.length == 0)
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
    if (res.length > leftTillBlock)
    {
        res.resize(leftTillBlock);
    }
    leftTillBlock -= res.length;

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
