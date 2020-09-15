
bool
SCP.nominate(uint64 slotIndex, Value const& value, Value const& previousValue)
{
    assert(isValidator());
    return getSlot(slotIndex, true).nominate(value, previousValue, false);
}

void
SCP.stopNomination(uint64 slotIndex)
{
    auto s = getSlot(slotIndex, false);
    if (s)
    {
        s.stopNomination();
    }
}

void
SCP.updateLocalQuorumSet(ref const(SCPQuorumSet) qSet)
{
    mLocalNode.updateQuorumSet(qSet);
}

ref const(SCPQuorumSet)
SCP.getLocalQuorumSet()
{
    return mLocalNode.getQuorumSet();
}

ref const(NodeID)
SCP.getLocalNodeID()
{
    return mLocalNode.getNodeID();
}

void
SCP.purgeSlots(uint64 maxSlotIndex)
{
    auto it = mKnownSlots.begin();
    while (it != mKnownSlots.end())
    {
        if (it.first < maxSlotIndex)
        {
            it = mKnownSlots.erase(it);
        }
        else
        {
            ++it;
        }
    }
}

std.shared_ptr<LocalNode>
SCP.getLocalNode()
{
    return mLocalNode;
}

std.shared_ptr<Slot>
SCP.getSlot(uint64 slotIndex, bool create)
{
    std.shared_ptr<Slot> res;
    auto it = mKnownSlots.find(slotIndex);
    if (it == mKnownSlots.end())
    {
        if (create)
        {
            res = std.make_shared<Slot>(slotIndex, *this);
            mKnownSlots[slotIndex] = res;
        }
    }
    else
    {
        res = it.second;
    }
    return res;
}

Json.Value
SCP.getJsonInfo(size_t limit, bool fullKeys)
{
    Json.Value ret;
    auto it = mKnownSlots.rbegin();
    while (it != mKnownSlots.rend() && limit-- != 0)
    {
        auto slot = &*(it.second);
        ret[std.to_string(slot.getSlotIndex())] = slot.getJsonInfo(fullKeys);
        it++;
    }

    return ret;
}

Json.Value
SCP.getJsonQuorumInfo(ref const(NodeID) id, bool summary, bool fullKeys,
                       uint64 index)
{
    Json.Value ret;
    if (index == 0)
    {
        for (auto item : mKnownSlots)
        {
            auto& slot = &*item.second;
            ret = slot.getJsonQuorumInfo(id, summary, fullKeys);
            ret["ledger"] = static_cast<Json.UInt64>(slot.getSlotIndex());
        }
    }
    else
    {
        auto s = getSlot(index, false);
        if (s)
        {
            ret = s.getJsonQuorumInfo(id, summary, fullKeys);
            ret["ledger"] = static_cast<Json.UInt64>(index);
        }
    }
    return ret;
}

bool
SCP.isValidator()
{
    return mLocalNode.isValidator();
}

bool
SCP.isSlotFullyValidated(uint64 slotIndex)
{
    auto slot = getSlot(slotIndex, false);
    if (slot)
    {
        return slot.isFullyValidated();
    }
    else
    {
        return false;
    }
}

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
