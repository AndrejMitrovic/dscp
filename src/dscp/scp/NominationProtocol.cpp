
uint64
NominationProtocol.getNodePriority(ref const(NodeID) nodeID,
                                    ref const(SCPQuorumSet) qset)
{

}

Value
NominationProtocol.getNewValueFromNomination(SCPNomination const& nom)
{

}

SCP.EnvelopeState
NominationProtocol.processEnvelope(SCPEnvelope const& envelope)
{
    const st = &envelope.statement;
    const nom = &st.pledges.nominate_;

    SCP.EnvelopeState res = SCP.EnvelopeState.INVALID;

    if (isNewerStatement(st.nodeID, nom))
    {
        if (isSane(st))
        {
            recordEnvelope(envelope);
            res = SCP.EnvelopeState.VALID;

            if (mNominationStarted)
            {
                bool modified =
                    false; // tracks if we should emit a new nomination message
                bool newCandidates = false;

                // attempts to promote some of the votes to accepted
                for (auto const& v : nom.votes)
                {
                    if (mAccepted.find(v) != mAccepted.end())
                    { // v is already accepted
                        continue;
                    }
                    if (mSlot.federatedAccept(
                            [&v](ref const(SCPStatement) st) . bool {
                                const nom = &st.pledges.nominate_;
                                bool res;
                                res = (std.find(nom.votes.begin(),
                                                 nom.votes.end(),
                                                 v) != nom.votes.end());
                                return res;
                            },
                            &v.acceptPredicate,
                            mLatestNominations))
                    {
                        auto vl = validateValue(v);
                        if (vl == ValidationLevel.kFullyValidatedValue)
                        {
                            mAccepted.emplace(v);
                            mVotes.emplace(v);
                            modified = true;
                        }
                        else
                        {
                            // the value made it pretty far:
                            // see if we can vote for a variation that
                            // we consider valid
                            Value toVote;
                            toVote = extractValidValue(v);
                            if (!toVote.empty())
                            {
                                if (mVotes.emplace(toVote).second)
                                {
                                    modified = true;
                                }
                            }
                        }
                    }
                }
                // attempts to promote accepted values to candidates
                for (auto const& a : mAccepted)
                {
                    if (mCandidates.find(a) != mCandidates.end())
                    {
                        continue;
                    }
                    if (mSlot.federatedRatify(
                            &a.acceptPredicate,
                            mLatestNominations))
                    {
                        mCandidates.emplace(a);
                        newCandidates = true;
                    }
                }

                // only take round leader votes if we're still looking for
                // candidates
                if (mCandidates.empty() &&
                    mRoundLeaders.find(st.nodeID) != mRoundLeaders.end())
                {
                    Value newVote = getNewValueFromNomination(nom);
                    if (!newVote.empty())
                    {
                        mVotes.emplace(newVote);
                        modified = true;
                        mSlot.getSCPDriver().nominatingValue(
                            mSlot.getSlotIndex(), newVote);
                    }
                }

                if (modified)
                {
                    emitNomination();
                }

                if (newCandidates)
                {
                    mLatestCompositeCandidate =
                        mSlot.getSCPDriver().combineCandidates(
                            mSlot.getSlotIndex(), mCandidates);

                    mSlot.getSCPDriver().updatedCandidateValue(
                        mSlot.getSlotIndex(), mLatestCompositeCandidate);

                    mSlot.bumpState(mLatestCompositeCandidate, false);
                }
            }
        }
        else
        {
            CLOG(TRACE, "SCP")
                << "NominationProtocol: message didn't pass sanity check";
        }
    }
    return res;
}

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
