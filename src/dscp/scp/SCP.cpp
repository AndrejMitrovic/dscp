
size_t
SCP.getKnownSlotsCount() const
{
    return mKnownSlots.size();
}

size_t
SCP.getCumulativeStatemtCount() const
{
    size_t c = 0;
    for (auto const& s : mKnownSlots)
    {
        c += s.second.getStatementCount();
    }
    return c;
}

SCPEnvelope[]
SCP.getLatestMessagesSend(uint64 slotIndex)
{
    auto slot = getSlot(slotIndex, false);
    if (slot)
    {
        return slot.getLatestMessagesSend();
    }
    else
    {
        return SCPEnvelope[]();
    }
}

void
SCP.setStateFromEnvelope(uint64 slotIndex, SCPEnvelope const& e)
{
    auto slot = getSlot(slotIndex, true);
    slot.setStateFromEnvelope(e);
}

bool
SCP.empty() const
{
    return mKnownSlots.empty();
}

uint64
SCP.getLowSlotIndex() const
{
    assert(!empty());
    return mKnownSlots.begin().first;
}

uint64
SCP.getHighSlotIndex() const
{
    assert(!empty());
    auto it = mKnownSlots.end();
    it--;
    return it.first;
}

SCPEnvelope[]
SCP.getCurrentState(uint64 slotIndex)
{
    auto slot = getSlot(slotIndex, false);
    if (slot)
    {
        return slot.getCurrentState();
    }
    else
    {
        return SCPEnvelope[]();
    }
}

SCPEnvelope const*
SCP.getLatestMessage(ref const(NodeID) id)
{
    for (auto it = mKnownSlots.rbegin(); it != mKnownSlots.rend(); it++)
    {
        auto slot = it.second;
        auto res = slot.getLatestMessage(id);
        if (res !is null)
        {
            return res;
        }
    }
    return null;
}

SCPEnvelope[]
SCP.getExternalizingState(uint64 slotIndex)
{
    auto slot = getSlot(slotIndex, false);
    if (slot)
    {
        return slot.getExternalizingState();
    }
    else
    {
        return SCPEnvelope[]();
    }
}

std.string
SCP.getValueString(Value const& v) const
{
    return mDriver.getValueString(v);
}

std.string
SCP.ballotToStr(SCPBallot const& ballot) const
{
    std.ostringstream oss;

    oss << "(" << ballot.counter << "," << getValueString(ballot.value) << ")";
    return oss.str();
}

std.string
SCP.ballotToStr(std.unique_ptr<SCPBallot> const& ballot) const
{
    std.string res;
    if (ballot)
    {
        res = ballotToStr(*ballot);
    }
    else
    {
        res = "(<null_ballot>)";
    }
    return res;
}

std.string
SCP.envToStr(SCPEnvelope const& envelope, bool fullKeys) const
{
    return envToStr(envelope.statement, fullKeys);
}

std.string
SCP.envToStr(ref const(SCPStatement) st, bool fullKeys) const
{
    std.ostringstream oss;

    ref const(Hash) qSetHash = Slot.getCompanionQuorumSetHashFromStatement(st);

    std.string nodeId = mDriver.toStrKey(st.nodeID, fullKeys);

    oss << "{ENV@" << nodeId << " | "
        << " i: " << st.slotIndex;
    switch (st.pledges.type)
    {
    case SCPStatementType.SCP_ST_PREPARE:
    {
        auto const& p = st.pledges.prepare_;
        oss << " | PREPARE"
            << " | D: " << hexAbbrev(qSetHash)
            << " | b: " << ballotToStr(p.ballot)
            << " | p: " << ballotToStr(p.prepared)
            << " | p': " << ballotToStr(p.preparedPrime) << " | c.n: " << p.nC
            << " | h.n: " << p.nH;
    }
    break;
    case SCPStatementType.SCP_ST_CONFIRM:
    {
        auto const& c = st.pledges.confirm_;
        oss << " | CONFIRM"
            << " | D: " << hexAbbrev(qSetHash)
            << " | b: " << ballotToStr(c.ballot) << " | p.n: " << c.nPrepared
            << " | c.n: " << c.nCommit << " | h.n: " << c.nH;
    }
    break;
    case SCPStatementType.SCP_ST_EXTERNALIZE:
    {
        auto const& ex = st.pledges.externalize_;
        oss << " | EXTERNALIZE"
            << " | c: " << ballotToStr(ex.commit) << " | h.n: " << ex.nH
            << " | (lastD): " << hexAbbrev(qSetHash);
    }
    break;
    case SCPStatementType.SCP_ST_NOMINATE:
    {
        auto const& nom = st.pledges.nominate_;
        oss << " | NOMINATE"
            << " | D: " << hexAbbrev(qSetHash) << " | X: {";
        bool first = true;
        for (auto const& v : nom.votes)
        {
            if (!first)
            {
                oss << " ,";
            }
            oss << "'" << getValueString(v) << "'";
            first = false;
        }
        oss << "}"
            << " | Y: {";
        first = true;
        for (auto const& a : nom.accepted)
        {
            if (!first)
            {
                oss << " ,";
            }
            oss << "'" << getValueString(a) << "'";
            first = false;
        }
        oss << "}";
    }
    break;
    }

    oss << " }";
    return oss.str();
}
}
