SCPQuorumSetPtr
Slot.getQuorumSetFromStatement(SCPStatement const& st)
{

}

Json.Value
Slot.getJsonInfo(bool fullKeys)
{
    Json.Value ret;
    std.map<Hash, SCPQuorumSetPtr> qSetsUsed;

    int count = 0;
    for (auto const& item : mStatementsHistory)
    {
        Json.Value& v = ret["statements"][count++];
        v.append((Json.UInt64)item.mWhen);
        v.append(mSCP.envToStr(item.mStatement, fullKeys));
        v.append(item.mValidated);

        ref const(Hash) qSetHash =
            getCompanionQuorumSetHashFromStatement(item.mStatement);
        auto qSet = getSCPDriver().getQSet(qSetHash);
        if (qSet)
        {
            qSetsUsed.insert(std.make_pair(qSetHash, qSet));
        }
    }

    auto qSets = &ret["quorum_sets"];
    for (auto const& q : qSetsUsed)
    {
        qSets[hexAbbrev(q.first)] = getLocalNode().toJson(*q.second, fullKeys);
    }

    ret["validated"] = mFullyValidated;
    ret["nomination"] = mNominationProtocol.getJsonInfo();
    ret["ballotProtocol"] = mBallotProtocol.getJsonInfo();

    return ret;
}

Json.Value
Slot.getJsonQuorumInfo(ref const(NodeID) id, bool summary, bool fullKeys)
{
    Json.Value ret = mBallotProtocol.getJsonQuorumInfo(id, summary, fullKeys);
    if (getLocalNode().isValidator())
    {
        ret["validated"] = isFullyValidated();
    }
    return ret;
}

bool
Slot.federatedAccept(StatementPredicate voted, StatementPredicate accepted,
                      const(SCPEnvelope[NodeID]) envs)
{
    // Checks if the nodes that claimed to accept the statement form a
    // v-blocking set
    if (LocalNode.isVBlocking(getLocalNode().getQuorumSet(), envs, accepted))
    {
        return true;
    }

    // Checks if the set of nodes that accepted or voted for it form a quorum

    auto ratifyFilter = [&](SCPStatement const& st) {
        bool res;
        res = accepted(st) || voted(st);
        return res;
    };

    if (LocalNode.isQuorum(
            getLocalNode().getQuorumSet(), envs,
            std.bind(&Slot.getQuorumSetFromStatement, this, _1),
            ratifyFilter))
    {
        return true;
    }

    return false;
}

bool
Slot.federatedRatify(StatementPredicate voted,
                      const(SCPEnvelope[NodeID]) envs)
{
    return LocalNode.isQuorum(
        getLocalNode().getQuorumSet(), envs,
        std.bind(&Slot.getQuorumSetFromStatement, this, _1), voted);
}

std.shared_ptr<LocalNode>
Slot.getLocalNode()
{
    return mSCP.getLocalNode();
}

SCPEnvelope[]
Slot.getEntireCurrentState()
{
    bool old = mFullyValidated;
    // fake fully validated to force returning all envelopes
    mFullyValidated = true;
    auto r = getCurrentState();
    mFullyValidated = old;
    return r;
}
}
