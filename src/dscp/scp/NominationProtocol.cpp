Value[]
NominationProtocol.getStatementValues(ref const(SCPStatement) st)
{
    Value[] res;
    applyAll(st.pledges.nominate_,
             [&](ref const(Value) v) { res ~= v; });
    return res;
}

// attempts to nominate a value for consensus
bool
NominationProtocol.nominate(ref const(Value) value, ref const(Value) previousValue,
                             bool timedout)
{
    if (Logging.logDebug("SCP"))
        CLOG(DEBUG, "SCP") << "NominationProtocol.nominate (" << mRoundNumber
                           << ") " << mSlot.getSCP().getValueString(value);

    bool updated = false;

    if (timedout && !mNominationStarted)
    {
        CLOG(DEBUG, "SCP") << "NominationProtocol.nominate (TIMED OUT)";
        return false;
    }

    mNominationStarted = true;

    mPreviousValue = previousValue;

    mRoundNumber++;
    updateRoundLeaders();

    Value nominatingValue;

    // if we're leader, add our value
    if (mRoundLeaders.find(mSlot.getLocalNode().getNodeID()) !=
        mRoundLeaders.end())
    {
        auto ins = mVotes.insert(value);
        if (ins.second)
        {
            updated = true;
        }
        nominatingValue = value;
    }
    // add a few more values from other leaders
    for (auto const& leader : mRoundLeaders)
    {
        auto it = mLatestNominations.find(leader);
        if (it != mLatestNominations.end())
        {
            nominatingValue = getNewValueFromNomination(
                it.second.statement.pledges.nominate_);
            if (!nominatingValue.empty())
            {
                mVotes.insert(nominatingValue);
                updated = true;
            }
        }
    }

    std.chrono.milliseconds timeout =
        mSlot.getSCPDriver().computeTimeout(mRoundNumber);

    mSlot.getSCPDriver().nominatingValue(mSlot.getSlotIndex(), nominatingValue);

    std.shared_ptr<Slot> slot = mSlot.shared_from_this();

    std.function<void()>* func = new std.function<void()>;
    *func = [slot, value, previousValue]() {
            slot.nominate(value, previousValue, true);
        };

    mSlot.getSCPDriver().setupTimer(
        mSlot.getSlotIndex(), Slot.NOMINATION_TIMER, timeout, func);

    if (updated)
    {
        emitNomination();
    }
    else
    {
        CLOG(DEBUG, "SCP") << "NominationProtocol.nominate (SKIPPED)";
    }

    return updated;
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
