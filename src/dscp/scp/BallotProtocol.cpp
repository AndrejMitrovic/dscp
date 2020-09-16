bool
BallotProtocol.areBallotsCompatible(SCPBallot const& b1, SCPBallot const& b2)
{
    return b1.value == b2.value;
}

bool
BallotProtocol.areBallotsLessAndIncompatible(SCPBallot const& b1,
                                              SCPBallot const& b2)
{
    return (compareBallots(b1, b2) <= 0) && !areBallotsCompatible(b1, b2);
}

bool
BallotProtocol.areBallotsLessAndCompatible(SCPBallot const& b1,
                                            SCPBallot const& b2)
{
    return (compareBallots(b1, b2) <= 0) && areBallotsCompatible(b1, b2);
}

void
BallotProtocol.setStateFromEnvelope(SCPEnvelope const& e)
{
    if (mCurrentBallot)
    {
        throw std.runtime_error(
            "Cannot set state after starting ballot protocol");
    }

    recordEnvelope(e);

    mLastEnvelope = std.make_shared<SCPEnvelope>(e);
    mLastEnvelopeEmit = mLastEnvelope;

    const pl = &e.statement.pledges;

    switch (pl.type)
    {
    case SCPStatementType.SCP_ST_PREPARE:
    {
        const prep = &pl.prepare_;
        const b = &prep.ballot;
        bumpToBallot(b, true);
        if (prep.prepared)
        {
            mPrepared = std.make_unique<SCPBallot>(*prep.prepared);
        }
        if (prep.preparedPrime)
        {
            mPreparedPrime = std.make_unique<SCPBallot>(*prep.preparedPrime);
        }
        if (prep.nH)
        {
            mHighBallot = std.make_unique<SCPBallot>(prep.nH, b.value);
        }
        if (prep.nC)
        {
            mCommit = std.make_unique<SCPBallot>(prep.nC, b.value);
        }
        mPhase = SCPPhase.SCP_PHASE_PREPARE;
    }
    break;
    case SCPStatementType.SCP_ST_CONFIRM:
    {
        const c = &pl.confirm_;
        const v = &c.ballot.value;
        bumpToBallot(c.ballot, true);
        mPrepared = std.make_unique<SCPBallot>(c.nPrepared, v);
        mHighBallot = std.make_unique<SCPBallot>(c.nH, v);
        mCommit = std.make_unique<SCPBallot>(c.nCommit, v);
        mPhase = SCPPhase.SCP_PHASE_CONFIRM;
    }
    break;
    case SCPStatementType.SCP_ST_EXTERNALIZE:
    {
        const ext = &pl.externalize_;
        const v = &ext.commit.value;
        bumpToBallot(SCPBallot(uint.max, v), true);
        mPrepared = std.make_unique<SCPBallot>(uint.max, v);
        mHighBallot = std.make_unique<SCPBallot>(ext.nH, v);
        mCommit = std.make_unique<SCPBallot>(ext.commit);
        mPhase = SCPPhase.SCP_PHASE_EXTERNALIZE;
    }
    break;
    default:
        assert(0);
    }
}

SCPEnvelope[]
BallotProtocol.getCurrentState() const
{
    SCPEnvelope[] res;
    res.reserve(mLatestEnvelopes.length);
    for (auto const& n : mLatestEnvelopes)
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
BallotProtocol.getLatestMessage(ref const(NodeID) id) const
{
    auto it = mLatestEnvelopes.find(id);
    if (it != mLatestEnvelopes.end())
    {
        return &it.second;
    }
    return null;
}

SCPEnvelope[]
BallotProtocol.getExternalizingState() const
{
    SCPEnvelope[] res;
    if (mPhase == SCPPhase.SCP_PHASE_EXTERNALIZE)
    {
        res.reserve(mLatestEnvelopes.length);
        for (auto const& n : mLatestEnvelopes)
        {
            if (!(n.first == mSlot.getSCP().getLocalNodeID()))
            {
                // good approximation: statements with the value that
                // externalized
                // we could filter more using mConfirmedPrepared as well
                if (areBallotsCompatible(getWorkingBallot(n.second.statement),
                                         *mCommit))
                {
                    res ~= n.second;
                }
            }
            else if (mSlot.isFullyValidated())
            {
                // only return messages for self if the slot is fully validated
                res ~= n.second;
            }
        }
    }
    return res;
}

void
BallotProtocol.advanceSlot(ref const(SCPStatement) hint)
{
    mCurrentMessageLevel++;
    if (Logging.logTrace("SCP"))
        CLOG(TRACE, "SCP") << "BallotProtocol.advanceSlot "
                           << mCurrentMessageLevel << " " << getLocalState();

    if (mCurrentMessageLevel >= MAX_ADVANCE_SLOT_RECURSION)
    {
        throw std.runtime_error(
            "maximum number of transitions reached in advanceSlot");
    }

    // attempt* methods will queue up messages, causing advanceSlot to be
    // called recursively

    // done in order so that we follow the steps from the white paper in
    // order
    // allowing the state to be updated properly

    bool didWork = false;

    didWork = attemptPreparedAccept(hint) || didWork;

    didWork = attemptPreparedConfirmed(hint) || didWork;

    didWork = attemptAcceptCommit(hint) || didWork;

    didWork = attemptConfirmCommit(hint) || didWork;

    // only bump after we're done with everything else
    if (mCurrentMessageLevel == 1)
    {
        bool didBump = false;
        do
        {
            // attemptBump may invoke advanceSlot recursively
            didBump = attemptBump();
            didWork = didBump || didWork;
        } while (didBump);

        checkHeardFromQuorum();
    }

    if (Logging.logTrace("SCP"))
        CLOG(TRACE, "SCP") << "BallotProtocol.advanceSlot "
                           << mCurrentMessageLevel << " - exiting "
                           << getLocalState();

    --mCurrentMessageLevel;

    if (didWork)
    {
        sendLatestEnvelope();
    }
}

ValidationLevel
BallotProtocol.validateValues(ref const(SCPStatement) st)
{
    set!Value values;
    switch (st.pledges.type)
    {
    case SCPStatementType.SCP_ST_PREPARE:
    {
        const prep = &st.pledges.prepare_;
        const b = &prep.ballot;
        if (b.counter != 0)
        {
            values.insert(prep.ballot.value);
        }
        if (prep.prepared)
        {
            values.insert(prep.prepared.value);
        }
    }
    break;
    case SCPStatementType.SCP_ST_CONFIRM:
        values.insert(st.pledges.confirm_.ballot.value);
        break;
    case SCPStatementType.SCP_ST_EXTERNALIZE:
        values.insert(st.pledges.externalize_.commit.value);
        break;
    default:
        // This shouldn't happen
        return ValidationLevel.kInvalidValue;
    }
    ValidationLevel res = ValidationLevel.kFullyValidatedValue;
    for (auto const& v : values)
    {
        auto tr =
            mSlot.getSCPDriver().validateValue(mSlot.getSlotIndex(), v, false);
        if (tr != ValidationLevel.kFullyValidatedValue)
        {
            if (tr == ValidationLevel.kInvalidValue)
            {
                res = ValidationLevel.kInvalidValue;
            }
            else
            {
                res = ValidationLevel.kMaybeValidValue;
            }
        }
    }
    return res;
}

void
BallotProtocol.sendLatestEnvelope()
{
    // emit current envelope if needed
    if (mCurrentMessageLevel == 0 && mLastEnvelope && mSlot.isFullyValidated())
    {
        if (!mLastEnvelopeEmit || mLastEnvelope != mLastEnvelopeEmit)
        {
            mLastEnvelopeEmit = mLastEnvelope;
            mSlot.getSCPDriver().emitEnvelope(*mLastEnvelopeEmit);
        }
    }
}

const char* BallotProtocol.phaseNames[SCPPhase.SCP_PHASE_NUM] = {"PREPARE", "FINISH",
                                                         "EXTERNALIZE"};

Json.Value
BallotProtocol.getJsonInfo()
{
    Json.Value ret;
    ret["heard"] = mHeardFromQuorum;
    ret["ballot"] = mSlot.getSCP().ballotToStr(mCurrentBallot);
    ret["phase"] = phaseNames[mPhase];

    ret["state"] = getLocalState();
    return ret;
}

Json.Value
BallotProtocol.getJsonQuorumInfo(ref const(NodeID) id, bool summary, bool fullKeys)
{
    Json.Value ret;
    auto phase = &ret["phase"];

    // find the state of the node `id`
    SCPBallot b;
    Hash qSetHash;

    auto stateit = mLatestEnvelopes.find(id);
    if (stateit == mLatestEnvelopes.end())
    {
        phase = "unknown";
        if (id == mSlot.getLocalNode().getNodeID())
        {
            qSetHash = mSlot.getLocalNode().getQuorumSetHash();
        }
    }
    else
    {
        const st = &stateit.second.statement;

        switch (st.pledges.type)
        {
        case SCPStatementType.SCP_ST_PREPARE:
            phase = "PREPARE";
            b = st.pledges.prepare_.ballot;
            break;
        case SCPStatementType.SCP_ST_CONFIRM:
            phase = "CONFIRM";
            b = st.pledges.confirm_.ballot;
            break;
        case SCPStatementType.SCP_ST_EXTERNALIZE:
            phase = "EXTERNALIZE";
            b = st.pledges.externalize_.commit;
            break;
        default:
            assert(0);
        }
        // use the companion set here even for externalize to capture
        // the view of the quorum set during consensus
        qSetHash = mSlot.getCompanionQuorumSetHashFromStatement(st);
    }

    Json.Value& disagree = ret["disagree"];
    Json.Value& missing = ret["missing"];
    Json.Value& delayed = ret["delayed"];

    int n_missing = 0, n_disagree = 0, n_delayed = 0;

    int agree = 0;
    auto qSet = mSlot.getSCPDriver().getQSet(qSetHash);
    if (!qSet)
    {
        phase = "expired";
        return ret;
    }
    LocalNode.forAllNodes(*qSet, (ref const(NodeID) n) {
        auto it = mLatestEnvelopes.find(n);
        if (it == mLatestEnvelopes.end())
        {
            if (!summary)
            {
                missing.append(mSlot.getSCPDriver().toStrKey(n, fullKeys));
            }
            n_missing++;
        }
        else
        {
            auto st = &it.second.statement;
            if (areBallotsCompatible(getWorkingBallot(st), b))
            {
                agree++;
                auto t = st.pledges.type;
                if (!(t == SCPStatementType.SCP_ST_EXTERNALIZE ||
                      (t == SCPStatementType.SCP_ST_CONFIRM &&
                       st.pledges.confirm_.ballot.counter == uint.max)))
                {
                    if (!summary)
                    {
                        delayed.append(
                            mSlot.getSCPDriver().toStrKey(n, fullKeys));
                    }
                    n_delayed++;
                }
            }
            else
            {
                if (!summary)
                {
                    disagree.append(mSlot.getSCPDriver().toStrKey(n, fullKeys));
                }
                n_disagree++;
            }
        }
    });
    if (summary)
    {
        missing = n_missing;
        disagree = n_disagree;
        delayed = n_delayed;
    }

    auto f = LocalNode.findClosestVBlocking(*qSet, mLatestEnvelopes,
                                             (ref const(SCPStatement) st) {
                                                 return areBallotsCompatible(
                                                     getWorkingBallot(st), b);
                                             },
                                             &id);
    ret["fail_at"] = static_cast<int>(f.length);

    if (!summary)
    {
        auto f_ex = &ret["fail_with"];
        for (auto const& n : f)
        {
            f_ex.append(mSlot.getSCPDriver().toStrKey(n, fullKeys));
        }
        ret["value"] = &getLocalNode().toJson(*qSet, fullKeys);
    }

    ret["hash"] = hexAbbrev(qSetHash);
    ret["agree"] = agree;

    return ret;
}

std.string
BallotProtocol.getLocalState() const
{
    std.ostringstream oss;

    oss << "i: " << mSlot.getSlotIndex() << " | " << phaseNames[mPhase]
        << " | b: " << mSlot.getSCP().ballotToStr(mCurrentBallot)
        << " | p: " << mSlot.getSCP().ballotToStr(mPrepared)
        << " | p': " << mSlot.getSCP().ballotToStr(mPreparedPrime)
        << " | h: " << mSlot.getSCP().ballotToStr(mHighBallot)
        << " | c: " << mSlot.getSCP().ballotToStr(mCommit)
        << " | M: " << mLatestEnvelopes.length;
    return oss.str();
}

std.shared_ptr<LocalNode>
BallotProtocol.getLocalNode()
{
    return mSlot.getSCP().getLocalNode();
}

bool
BallotProtocol.federatedAccept(StatementPredicate voted,
                                StatementPredicate accepted)
{
    return mSlot.federatedAccept(voted, accepted, mLatestEnvelopes);
}

bool
BallotProtocol.federatedRatify(StatementPredicate voted)
{
    return mSlot.federatedRatify(voted, mLatestEnvelopes);
}

void
BallotProtocol.checkHeardFromQuorum()
{
    // this method is safe to call regardless of the transitions of the other
    // nodes on the network:
    // we guarantee that other nodes can only transition to higher counters
    // (messages are ignored upstream)
    // therefore the local node will not flip flop between "seen" and "not seen"
    // for a given counter on the local node
    if (mCurrentBallot)
    {
        if (LocalNode.isQuorum(
                getLocalNode().getQuorumSet(), mLatestEnvelopes,
                &mslot.getQuorumSetFromStatement,
                (ref const(SCPStatement) st) {
                    bool res;
                    if (st.pledges.type == SCPStatementType.SCP_ST_PREPARE)
                    {
                        res = mCurrentBallot.counter <=
                              st.pledges.prepare_.ballot.counter;
                    }
                    else
                    {
                        res = true;
                    }
                    return res;
                }))
        {
            bool oldHQ = mHeardFromQuorum;
            mHeardFromQuorum = true;
            if (!oldHQ)
            {
                // if we transition from not heard . heard, we start the timer
                mSlot.getSCPDriver().ballotDidHearFromQuorum(
                    mSlot.getSlotIndex(), *mCurrentBallot);
                if (mPhase != SCPPhase.SCP_PHASE_EXTERNALIZE)
                {
                    startBallotProtocolTimer();
                }
            }
            if (mPhase == SCPPhase.SCP_PHASE_EXTERNALIZE)
            {
                stopBallotProtocolTimer();
            }
        }
        else
        {
            mHeardFromQuorum = false;
            stopBallotProtocolTimer();
        }
    }
}
}
