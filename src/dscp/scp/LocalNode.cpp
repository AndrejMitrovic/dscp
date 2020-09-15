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
