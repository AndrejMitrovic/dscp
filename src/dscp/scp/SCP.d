// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.SCP;

import dscp.scp.LocalNode;
import dscp.scp.SCPDriver;
import dscp.scp.Slot;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import std.format;

// todo: was shared_ptr. could be RefCounted
alias SCPQuorumSetPtr = SCPQuorumSet*;

class SCP
{
    SCPDriver mDriver;

  public:
    this (SCPDriver driver, ref const(NodeID) nodeID, bool isValidator,
        ref const(SCPQuorumSet) qSetLocal)
    {
        mDriver = driver;
        mLocalNode = new LocalNode(nodeID, isValidator, qSetLocal, this);
    }

    SCPDriver getDriver ()
    {
        return mDriver;
    }

    const(SCPDriver) getDriver() const
    {
        return mDriver;
    }

    enum EnvelopeState
    {
        INVALID, // the envelope is considered invalid
        VALID    // the envelope is valid
    }

    // this is the main entry point of the SCP library
    // it processes the envelope, updates the internal state and
    // invokes the appropriate methods
    EnvelopeState receiveEnvelope (ref const(SCPEnvelope) envelope)
    {
        uint64 slotIndex = envelope.statement.slotIndex;
        const bool CreateIfNew = true;
        const bool NotFromSelf = false;
        return getSlot(slotIndex, CreateIfNew)
            .processEnvelope(envelope, NotFromSelf);
    }

    // Submit a value to consider for slotIndex
    // previousValue is the value from slotIndex-1
    bool nominate (uint64 slotIndex, ref const(Value) value,
        ref const(Value) previousValue)
    {
        assert(isValidator());
        const bool CreateIfNew = true;
        const bool NotTimedOut = false;
        return getSlot(slotIndex, CreateIfNew)
            .nominate(value, previousValue, NotTimedOut);
    }

    // stops nomination for a slot if one is in progress
    void stopNomination (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto s = getSlot(slotIndex, DontCreateNew))
            s.stopNomination();
    }

    // Local QuorumSet interface (can be dynamically updated)
    void updateLocalQuorumSet (ref const(SCPQuorumSet) qSet)
    {
        mLocalNode.updateQuorumSet(qSet);
    }

    ref const(SCPQuorumSet) getLocalQuorumSet ()
    {
        return mLocalNode.getQuorumSet();
    }

    // Local nodeID getter
    ref const(NodeID) getLocalNodeID ()
    {
        return mLocalNode.getNodeID();
    }

    // returns the local node descriptor
    LocalNode getLocalNode ()
    {
        return mLocalNode;
    }

    // Purges all data relative to all the slots whose slotIndex is smaller
    // than the specified `maxSlotIndex`.
    void purgeSlots (uint64 maxSlotIndex)
    {
        // todo: optimize, or use red-black tree to keep order and quick lookup
        uint64[] slots;
        foreach (slot_idx; mKnownSlots.byKey())
            if (slot_idx < maxSlotIndex)
                slots ~= slot_idx;

        foreach (slot_idx; slots)
            mKnownSlots.remove(slot_idx);
    }

    // Returns whether the local node is a validator.
    bool isValidator ()
    {
        return mLocalNode.isValidator();
    }

    // returns the validation state of the given slot
    bool isSlotFullyValidated (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.isFullyValidated();

        return false;
    }

    // Helpers for monitoring and reporting the internal memory-usage of the SCP
    // protocol to system metric reporters.
    size_t getKnownSlotsCount () const
    {
        return mKnownSlots.length;
    }

    size_t getCumulativeStatemtCount () const
    {
        size_t c;
        foreach (slot; mKnownSlots.byValue())  // order is not important
            c += slot.getStatementCount();
        return c;
    }

    // returns the latest messages sent for the given slot
    SCPEnvelope[] getLatestMessagesSend (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.getLatestMessagesSend();

        return null;
    }

    // forces the state to match the one in the envelope
    // this is used when rebuilding the state after a crash for example
    void setStateFromEnvelope (uint64 slotIndex, ref const(SCPEnvelope) e)
    {
        const CreateIfNew = true;
        auto slot = getSlot(slotIndex, CreateIfNew);
        slot.setStateFromEnvelope(e);
    }

    // check if we are holding some slots
    bool empty() const
    {
        return mKnownSlots.length == 0;
    }

    // return lowest slot index value
    uint64 getLowSlotIndex () const
    {
        assert(!this.empty());

        // todo: optimize
        uint64 lowest = uint64.max;
        foreach (slot_idx; mKnownSlots.byKey)
            if (slot_idx < lowest)
                lowest = slot_idx;

        return lowest;
    }

    // return highest slot index value
    uint64 getHighSlotIndex () const
    {
        assert(!this.empty());

        // todo: optimize
        uint64 highest = 0;
        foreach (slot_idx; mKnownSlots.byKey)
            if (slot_idx > highest)
                highest = slot_idx;

        return highest;
    }

    // returns all messages for the slot
    SCPEnvelope[] getCurrentState (uint64 slotIndex)
    {
        const DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.getCurrentState();

        return null;
    }

    // returns the latest message from a node
    // or null if not found
    // note: this is only used in tests, and it seems to skip newer slots
    // possible bug
    const(SCPEnvelope)* getLatestMessage (ref const(NodeID) id)
    {
        foreach (slot_idx; this.getLowSlotIndex() .. this.getHighSlotIndex() + 1)
        {
            if (auto msg = mKnownSlots[slot_idx].getLatestMessage(id))
                return msg;
        }

        return null;
    }

    // returns messages that contributed to externalizing the slot
    // (or empty if the slot didn't externalize)
    SCPEnvelope[] getExternalizingState (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.getExternalizingState();

        return null;
    }

    // ** helper methods to stringify ballot for logging
    string getValueString (ref const(Value) v) const
    {
        return mDriver.getValueString(v);
    }

    string ballotToStr (ref const(SCPBallot) ballot) const
    {
        return format("(%s, %s)", ballot.counter, getValueString(ballot.value));
    }

    string envToStr (ref const(SCPEnvelope) envelope, bool fullKeys = false) const
    {
        return envToStr(envelope.statement, fullKeys);
    }

    string envToStr (ref const(SCPStatement) st, bool fullKeys = false) const
    {
        ref const(Hash) qSetHash = Slot.getCompanionQuorumSetHashFromStatement(st);
        string nodeId = mDriver.toStrKey(st.nodeID, fullKeys);

        string res = format("{ENV@%s | i: %s", nodeI, st.slotIndex);
        switch (st.pledges.type)
        {
            case SCPStatementType.SCP_ST_PREPARE:
            {
                const p = &st.pledges.prepare_;
                res ~= " | PREPARE"
                    ~ " | D: " ~ hexAbbrev(qSetHash)
                    ~ " | b: " ~ ballotToStr(p.ballot)
                    ~ " | p: " ~ ballotToStr(p.prepared)
                    ~ " | p': " ~ ballotToStr(p.preparedPrime) ~ " | c.n: " ~ p.nC
                    ~ " | h.n: " ~ p.nH;
            }
            break;

            case SCPStatementType.SCP_ST_CONFIRM:
            {
                const c = &st.pledges.confirm_;
                res ~= " | CONFIRM"
                    ~ " | D: " ~ hexAbbrev(qSetHash)
                    ~ " | b: " ~ ballotToStr(c.ballot) ~ " | p.n: " ~ c.nPrepared
                    ~ " | c.n: " ~ c.nCommit ~ " | h.n: " ~ c.nH;
            }
            break;

            case SCPStatementType.SCP_ST_EXTERNALIZE:
            {
                const ex = &st.pledges.externalize_;
                res ~= " | EXTERNALIZE"
                    ~ " | c: " ~ ballotToStr(ex.commit) ~ " | h.n: " ~ ex.nH
                    ~ " | (lastD): " ~ hexAbbrev(qSetHash);
            }
            break;

            case SCPStatementType.SCP_ST_NOMINATE:
            {
                const nom = &st.pledges.nominate_;
                res ~= " | NOMINATE"
                    ~ " | D: " ~ hexAbbrev(qSetHash) ~ " | X: {";
                bool first = true;
                for (const v : nom.votes)
                {
                    if (!first)
                    {
                        res ~ " ,";
                    }
                    res ~ "'" ~ getValueString(v) ~ "'";
                    first = &false;
                }
                res ~= "}"
                    ~ " | Y: {";
                first = true;
                for (const a : nom.accepted)
                {
                    if (!first)
                        res ~= &" ,";
                    res ~= "'" ~ getValueString(a) ~ "'";
                    first = false;
                }
                res ~ "}";
            }

            default:
                assert(0);
        }

        res ~= " }";
        return res;
    }

  protected:
    LocalNode mLocalNode;
    Slot[uint64] mKnownSlots;

    // Slot getter
    Slot getSlot (uint64 slotIndex, bool create)
    {
        if (create)
            return mKnownSlots.require(slotIndex, new Slot(slotIndex, this));
        else
            return mKnownSlots.get(slotIndex, null);
    }
}
