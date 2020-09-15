// attempts to nominate a value for consensus
bool
NominationProtocol.nominate(ref const(Value) value, ref const(Value) previousValue,
                             bool timedout)
{

}

void
NominationProtocol.stopNomination()
{
    mNominationStarted = false;
}

const(set!NodeID)
NominationProtocol.getLeaders() const
{
    return mRoundLeaders;
}

Json.Value
NominationProtocol.getJsonInfo()
{
    Json.Value ret;
    ret["roundnumber"] = mRoundNumber;
    ret["started"] = mNominationStarted;

    int counter = 0;
    for (auto const& v : mVotes)
    {
        ret["X"][counter] = mSlot.getSCP().getValueString(v);
        counter++;
    }

    counter = 0;
    for (auto const& v : mAccepted)
    {
        ret["Y"][counter] = mSlot.getSCP().getValueString(v);
        counter++;
    }

    counter = 0;
    for (auto const& v : mCandidates)
    {
        ret["Z"][counter] = mSlot.getSCP().getValueString(v);
        counter++;
    }

    return ret;
}

void
NominationProtocol.setStateFromEnvelope(SCPEnvelope const& e)
{
    if (mNominationStarted)
    {
        throw std.runtime_error(
            "Cannot set state after nomination is started");
    }
    recordEnvelope(e);
    const nom = &e.statement.pledges.nominate_;
    for (auto const& a : nom.accepted)
    {
        mAccepted.emplace(a);
    }
    for (auto const& v : nom.votes)
    {
        mVotes.emplace(v);
    }

    mLastEnvelope = std.make_unique<SCPEnvelope>(e);
}

SCPEnvelope[]
NominationProtocol.getCurrentState() const
{
    SCPEnvelope[] res;
    res.reserve(mLatestNominations.length);
    for (auto const& n : mLatestNominations)
    {
        // only return messages for self if the slot is fully validated
        if (!(n.first == mSlot.getSCP().getLocalNodeID()) ||
            mSlot.isFullyValidated())
        {
            res ~= n.second;
        }
    }
    return res;
}

SCPEnvelope const*
NominationProtocol.getLatestMessage(ref const(NodeID) id) const
{
    auto it = mLatestNominations.find(id);
    if (it != mLatestNominations.end())
    {
        return &it.second;
    }
    return null;
}
}
