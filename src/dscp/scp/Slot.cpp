Hash
Slot.getCompanionQuorumSetHashFromStatement(SCPStatement const& st)
{
    Hash h;
    switch (st.pledges.type)
    {
    case SCPStatementType.SCP_ST_PREPARE:
        h = st.pledges.prepare_.quorumSetHash;
        break;
    case SCPStatementType.SCP_ST_CONFIRM:
        h = st.pledges.confirm().quorumSetHash;
        break;
    case SCPStatementType.SCP_ST_EXTERNALIZE:
        h = st.pledges.externalize().commitQuorumSetHash;
        break;
    case SCPStatementType.SCP_ST_NOMINATE:
        h = st.pledges.nominate().quorumSetHash;
        break;
    default:
        dbgAbort();
    }
    return h;
}

Value[]
Slot.getStatementValues(SCPStatement const& st)
{
    Value[] res;
    if (st.pledges.type == SCPStatementType.SCP_ST_NOMINATE)
    {
        res = NominationProtocol.getStatementValues(st);
    }
    else
    {
        res.emplace_back(BallotProtocol.getWorkingBallot(st).value);
    }
    return res;
}

SCPQuorumSetPtr
Slot.getQuorumSetFromStatement(SCPStatement const& st)
{
    SCPQuorumSetPtr res;
    SCPStatementType t = st.pledges.type;

    if (t == SCPStatementType.SCP_ST_EXTERNALIZE)
    {
        res = LocalNode.getSingletonQSet(st.nodeID);
    }
    else
    {
        Hash h;
        if (t == SCPStatementType.SCP_ST_PREPARE)
        {
            h = st.pledges.prepare_.quorumSetHash;
        }
        else if (t == SCPStatementType.SCP_ST_CONFIRM)
        {
            h = st.pledges.confirm().quorumSetHash;
        }
        else if (t == SCPStatementType.SCP_ST_NOMINATE)
        {
            h = st.pledges.nominate().quorumSetHash;
        }
        else
        {
            dbgAbort();
        }
        res = getSCPDriver().getQSet(h);
    }
    return res;
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
