// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.SCP;

import dscp.scp.LocalNode;
import dscp.scp.SCPDriver;
import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

// todo: was shared_ptr. could be RefCounted
alias SCPQuorumSetPtr = SCPQuorumSet*;

class SCP
{
    SCPDriver mDriver;

  public:
    this (SCPDriver driver, ref const(NodeID) nodeID, bool isValidator,
        ref const(SCPQuorumSet) qSetLocal);

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
    EnvelopeState receiveEnvelope (ref const(SCPEnvelope) envelope);

    // Submit a value to consider for slotIndex
    // previousValue is the value from slotIndex-1
    bool nominate (uint64 slotIndex, ref const(Value) value,
        ref const(Value) previousValue);

    // stops nomination for a slot
    void stopNomination (uint64 slotIndex);

    // Local QuorumSet interface (can be dynamically updated)
    void updateLocalQuorumSet (ref const(SCPQuorumSet) qSet);

    ref const(SCPQuorumSet) getLocalQuorumSet ();

    // Local nodeID getter
    ref const(NodeID) getLocalNodeID ();

    // returns the local node descriptor
    LocalNode* getLocalNode ();

    // Purges all data relative to all the slots whose slotIndex is smaller
    // than the specified `maxSlotIndex`.
    void purgeSlots (uint64 maxSlotIndex);

    // Returns whether the local node is a validator.
    bool isValidator ();

    // returns the validation state of the given slot
    bool isSlotFullyValidated (uint64 slotIndex);

    // Helpers for monitoring and reporting the internal memory-usage of the SCP
    // protocol to system metric reporters.
    size_t getKnownSlotsCount () const;
    size_t getCumulativeStatemtCount () const;

    // returns the latest messages sent for the given slot
    SCPEnvelope[] getLatestMessagesSend (uint64 slotIndex);

    // forces the state to match the one in the envelope
    // this is used when rebuilding the state after a crash for example
    void setStateFromEnvelope (uint64 slotIndex, ref const(SCPEnvelope) e);

    // check if we are holding some slots
    bool empty() const;

    // return lowest slot index value
    uint64 getLowSlotIndex () const;

    // return highest slot index value
    uint64 getHighSlotIndex () const;

    // returns all messages for the slot
    SCPEnvelope[] getCurrentState (uint64 slotIndex);

    // returns the latest message from a node
    // or null if not found
    ref const(SCPEnvelope) getLatestMessage (ref const(NodeID) id);

    // returns messages that contributed to externalizing the slot
    // (or empty if the slot didn't externalize)
    SCPEnvelope[] getExternalizingState (uint64 slotIndex);

    // ** helper methods to stringify ballot for logging
    string getValueString (ref const(Value) v) const;
    string ballotToStr (ref const(SCPBallot) ballot) const;
    string envToStr (ref const(SCPEnvelope) envelope, bool fullKeys = false) const;
    string envToStr (ref const(SCPStatement) st, bool fullKeys = false) const;

  protected:
    LocalNode* mLocalNode;
    Slot[uint64] mKnownSlots;

    // Slot getter
    Slot* getSlot (uint64 slotIndex, bool create);
}
