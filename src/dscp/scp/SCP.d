// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.SCP;

import dscp.crypto.Hex;
import dscp.scp.LocalNode;
import dscp.scp.SCPDriver;
import dscp.scp.Slot;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import std.conv;
import std.format;

class SCPT (NodeID, Hash, Value, Signature, alias Set, alias makeSet, alias getHashOf, alias hashPart, alias duplicate, Logger)
{
    public alias SCPQuorumSet = SCPQuorumSetT!(NodeID, hashPart);
    public alias LocalNode = LocalNodeT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate, Logger);
    public alias Slot = SlotT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate, Logger);
    public alias SCPDriver = SCPDriverT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate, Logger);
    public alias SCPEnvelope = SCPEnvelopeT!(NodeID, Hash, Value, Signature);
    public alias SCPBallot = SCPBallotT!Value;
    public alias SCPStatement = SCPStatementT!(NodeID, Hash, Value);
    alias SCPQuorumSetPtr = SCPQuorumSet*;

    protected LocalNode mLocalNode;
    protected Slot[uint64] mKnownSlots;
    private SCPDriver mDriver;

    private Logger log;

    public this (SCPDriver driver, ref const(NodeID) nodeID, bool isValidator,
        ref SCPQuorumSet qSetLocal, Logger log)
    {
        mDriver = driver;
        this.log = log;
        mLocalNode = new LocalNode(nodeID, isValidator, qSetLocal, this, this.log);
    }

    public SCPDriver getDriver ()
    {
        return mDriver;
    }

    public const(SCPDriver) getDriver () const
    {
        return mDriver;
    }

    public enum EnvelopeState
    {
        INVALID, // the envelope is considered invalid
        VALID    // the envelope is valid
    }

    // this is the main entry point of the SCP library
    // it processes the envelope, updates the internal state and
    // invokes the appropriate methods
    public EnvelopeState receiveEnvelope (ref const(SCPEnvelope) envelope)
    {
        uint64 slotIndex = envelope.statement.slotIndex;
        const bool CreateIfNew = true;
        const bool NotFromSelf = false;
        return getSlot(slotIndex, CreateIfNew)
            .processEnvelope(envelope, NotFromSelf);
    }

    // Submit a value to consider for slotIndex
    // previousValue is the value from slotIndex-1
    public bool nominate (uint64 slotIndex, ref const(Value) value,
        ref const(Value) previousValue)
    {
        assert(isValidator());
        const bool CreateIfNew = true;
        const bool NotTimedOut = false;
        return getSlot(slotIndex, CreateIfNew)
            .nominate(value, previousValue, NotTimedOut);
    }

    // stops nomination for a slot if one is in progress
    public void stopNomination (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto s = getSlot(slotIndex, DontCreateNew))
            s.stopNomination();
    }

    // Update the quorum set of this node
    public void updateLocalQuorumSet (ref SCPQuorumSet qSet) nothrow
    {
        mLocalNode.updateQuorumSet(qSet);
    }

    public ref const(SCPQuorumSet) getLocalQuorumSet ()
    {
        return mLocalNode.getQuorumSet();
    }

    // Local nodeID getter
    public ref const(NodeID) getLocalNodeID () inout
    {
        return mLocalNode.getNodeID();
    }

    // returns the local node descriptor
    public LocalNode getLocalNode ()
    {
        return mLocalNode;
    }

    // Purges all data relative to all the slots whose slotIndex is smaller
    // than the specified `maxSlotIndex`.
    public void purgeSlots (uint64 maxSlotIndex)
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
    public bool isValidator ()
    {
        return mLocalNode.isValidator();
    }

    // returns the validation state of the given slot
    public bool isSlotFullyValidated (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.isFullyValidated();

        return false;
    }

    // Helpers for monitoring and reporting the internal memory-usage of the SCP
    // protocol to system metric reporters.
    public size_t getKnownSlotsCount () const
    {
        return mKnownSlots.length;
    }

    public size_t getCumulativeStatemtCount () const
    {
        size_t count;
        foreach (slot; mKnownSlots.byValue())  // order is not important
            count += slot.getStatementCount();
        return count;
    }

    // returns the latest messages sent for the given slot
    public const(SCPEnvelope)[] getLatestMessagesSend (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.getLatestMessagesSend();

        return null;
    }

    // forces the state to match the one in the envelope
    // this is used when rebuilding the state after a crash for example
    public void setStateFromEnvelope (uint64 slotIndex, ref const(SCPEnvelope) e)
    {
        const CreateIfNew = true;
        auto slot = getSlot(slotIndex, CreateIfNew);
        slot.setStateFromEnvelope(e);
    }

    // check if we are holding some slots
    public bool empty() const
    {
        return mKnownSlots.length == 0;
    }

    // return lowest slot index value
    public uint64 getLowSlotIndex () const
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
    public uint64 getHighSlotIndex () const
    {
        assert(!this.empty());

        // todo: optimize
        uint64 highest = 0;
        foreach (slot_idx; mKnownSlots.byKey)
            if (slot_idx > highest)
                highest = slot_idx;

        return highest;
    }

    /// returns all messages for the slot
    /// only used by external code
    public const(SCPEnvelope)[] getCurrentState (uint64 slotIndex)
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
    public const(SCPEnvelope)* getLatestMessage (ref const(NodeID) id)
    {
        foreach (slot_idx; this.getLowSlotIndex() .. this.getHighSlotIndex() + 1)
        {
            if (auto msg = mKnownSlots[slot_idx].getLatestMessage(id))
                return msg;
        }

        return null;
    }

    // returns messages that contributed to externalizing the given slot index
    // (or null if the slot didn't externalize)
    public const(SCPEnvelope)[] getExternalizingState (uint64 slotIndex)
    {
        const bool DontCreateNew = false;
        if (auto slot = getSlot(slotIndex, DontCreateNew))
            return slot.getExternalizingState();

        return null;
    }

    // ** helper methods to stringify ballot for logging
    public string getValueString (ref const(Value) v) const
    {
        return mDriver.getValueString(v);
    }

    public string ballotToStr (const(SCPBallot)* ballot) const
    {
        if (ballot is null)
            return "(<null_ballot>)";
        else
            return ballotToStr(*ballot);
    }

    public string ballotToStr (const(SCPBallot) ballot) const
    {
        return format("(%s, %s)", ballot.counter, getValueString(ballot.value));
    }

    public string envToStr (ref const(SCPEnvelope) envelope, bool fullKeys = false) const
    {
        return envToStr(envelope.statement, fullKeys);
    }

    public string envToStr (ref const(SCPStatement) st, bool fullKeys = false) const
    {
        const(Hash) qSetHash = Slot.getCompanionQuorumSetHashFromStatement(st);
        string nodeId = mDriver.toStrKey(st.nodeID, fullKeys);

        string res = format("{ENV@%s | i: %s", nodeId, st.slotIndex);
        switch (st.pledges.type)
        {
            case SCPStatementType.SCP_ST_PREPARE:
            {
                const p = &st.pledges.prepare;
                res ~= " | PREPARE"
                    ~ " | D: " ~ hexAbbrev(qSetHash)
                    ~ " | b: " ~ ballotToStr(p.ballot)
                    ~ " | p: " ~ ballotToStr(p.prepared)
                    ~ " | p': " ~ ballotToStr(p.preparedPrime) ~ " | c.n: " ~ p.nC.to!string
                    ~ " | h.n: " ~ p.nH.to!string;
            }
            break;

            case SCPStatementType.SCP_ST_CONFIRM:
            {
                const c = &st.pledges.confirm;
                res ~= " | CONFIRM"
                    ~ " | D: " ~ hexAbbrev(qSetHash)
                    ~ " | b: " ~ ballotToStr(c.ballot) ~ " | p.n: " ~ c.nPrepared.to!string
                    ~ " | c.n: " ~ c.nCommit.to!string ~ " | h.n: " ~ c.nH.to!string;
            }
            break;

            case SCPStatementType.SCP_ST_EXTERNALIZE:
            {
                const ex = &st.pledges.externalize;
                res ~= " | EXTERNALIZE"
                    ~ " | c: " ~ ballotToStr(ex.commit) ~ " | h.n: " ~ ex.nH.to!string
                    ~ " | (lastD): " ~ hexAbbrev(qSetHash);
            }
            break;

            case SCPStatementType.SCP_ST_NOMINATE:
            {
                const nom = &st.pledges.nominate;
                res ~= " | NOMINATE"
                    ~ " | D: " ~ hexAbbrev(qSetHash) ~ " | X: {";
                bool first = true;
                foreach (const v; nom.votes)
                {
                    if (!first)
                        res ~= " ,";
                    res ~= "'" ~ getValueString(v) ~ "'";
                    first = false;
                }
                res ~= "}"
                    ~ " | Y: {";
                first = true;
                foreach (const a; nom.accepted)
                {
                    if (!first)
                        res ~= " ,";
                    res ~= "'" ~ getValueString(a) ~ "'";
                    first = false;
                }
                res ~= "}";
            }
            break;

            default:
                assert(0);
        }

        res ~= " }";
        return res;
    }

    // Slot getter
    protected Slot getSlot (uint64 slotIndex, bool create)
    {
        if (create)
            return mKnownSlots.require(slotIndex, new Slot(slotIndex, this, this.log));
        else
            return mKnownSlots.get(slotIndex, null);
    }
}

unittest
{
    import std.container;
    import std.traits;
    alias Hash = ubyte[64];
    alias uint256 = ubyte[32];
    alias uint512 = ubyte[64];
    alias Value = ubyte[];

    static struct PublicKey
    {
        int opCmp (const ref PublicKey rhs) inout
        {
            return this.ed25519 < rhs.ed25519;
        }

        uint256 ed25519;
    }

    alias NodeID = PublicKey;
    alias Signature = ubyte[64];
    static Hash getHashOf (Args...)(Args args) { return Hash.init; }
    alias Set (V) = RedBlackTree!(const(V));
    alias makeSet (T) = redBlackTree!(const(T));
    static auto duplicate (T)(T arg)
    {
        static if (isArray!T)
            return arg.dup;
        else
            return cast(Unqual!T)arg;
    }
    static void hashPart (T)(T arg, void delegate(scope const(ubyte)[]) dg) nothrow @safe @nogc { }
    static struct Logger
    {
        void trace (T...)(T t) { }
        void info (T...)(T t) { }
        void error (T...)(T t) { }
    }

    alias SCPT!(NodeID, Hash, Value, Signature, Set, makeSet, getHashOf, hashPart, duplicate, Logger) SCP;
}
