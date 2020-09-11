module dscp.scp.SCPDriver;

// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

//#include <chrono>
//#include <functional>
//#include <map>
//#include <memory>
//#include <set>

import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import core.stdc.stdint;
import core.time;

/// std::set equivalent
public alias set (V) = void[][V];

// was: shared_ptr. could use RefCounted
alias SCPQuorumSetPtr = SCPQuorumSet*;

abstract class SCPDriver
{
    // Envelope signature
    public void signEnvelope (ref SCPEnvelope envelope);

    // Retrieves a quorum set from its hash
    //
    // All SCP statement (see `SCPNomination` and `SCPStatement`) include
    // a quorum set hash.
    // SCP does not define how quorum sets are exchanged between nodes,
    // hence their retrieval is delegated to the user of SCP.
    // The return value is not cached by SCP, as quorum sets are transient.
    //
    // `nullptr` is a valid return value which cause the statement to be
    // considered invalid.
    public SCPQuorumSetPtr getQSet (ref const(Hash) qSetHash);

    // Users of the SCP library should inherit from SCPDriver and implement the
    // public methods which are called by the SCP implementation to
    // abstract the transport layer used from the implementation of the SCP
    // protocol.

    // Delegates the emission of an SCPEnvelope to the user of SCP. Envelopes
    // should be flooded to the network.
    public void emitEnvelope (ref const(SCPEnvelope) envelope);

    // methods to hand over the validation and ordering of values and ballots.

    // `validateValue` is called on each message received before any processing
    // is done. It should be used to filter out values that are not compatible
    // with the current state of that node. Unvalidated values can never
    // externalize.
    // If the value cannot be validated (node is missing some context) but
    // passes
    // the validity checks, kMaybeValidValue can be returned. This will cause
    // the current slot to be marked as a non validating slot: the local node
    // will abstain from emiting its position.
    // validation can be *more* restrictive during nomination as needed
    enum ValidationLevel
    {
        kInvalidValue,        // value is invalid for sure
        kFullyValidatedValue, // value is valid for sure
        kMaybeValidValue      // value may be valid
    }

    public ValidationLevel validateValue (uint64 slotIndex,
        ref const(Value) value, bool nomination)
    {
        return ValidationLevel.kMaybeValidValue;
    }

    // `extractValidValue` transforms the value, if possible to a different
    // value that the local node would agree to (fully validated).
    // This is used during nomination when encountering an invalid value (ie
    // validateValue did not return `kFullyValidatedValue` for this value).
    // returning Value() means no valid value could be extracted
    public Value extractValidValue (uint64 slotIndex, ref const(Value) value);

    // `getValueString` is used for debugging
    // default implementation is the hash of the value
    public string getValueString (ref const(Value) v) const;

    // `toStrKey` returns StrKey encoded string representation
    public string toStrKey (ref const(PublicKey) pk,
        bool fullKey = true) const;

    // `toShortString` converts to the common name of a key if found
    public string toShortString (ref const(PublicKey) pk) const;

    // `computeHashNode` is used by the nomination protocol to
    // randomize the order of messages between nodes.
    public uint64 computeHashNode (uint64 slotIndex, ref const(Value) prev,
        bool isPriority, int32_t roundNumber, ref const(NodeID) nodeID);

    // `computeValueHash` is used by the nomination protocol to
    // randomize the relative order between values.
    public uint64 computeValueHash (uint64 slotIndex, ref const(Value) prev,
        int32_t roundNumber, ref const(Value) value);

    // `combineCandidates` computes the composite value based off a list
    // of candidate values.
    public Value combineCandidates (uint64 slotIndex,
        ref const(set!Value) candidates);

    // `setupTimer`: requests to trigger 'cb' after timeout
    // if cb is nullptr, the timer is cancelled
    public void setupTimer (uint64 slotIndex, int timerID,
        Duration timeout, void delegate () cb);

    // `computeTimeout` computes a timeout given a round number
    // it should be sufficiently large such that nodes in a
    // quorum can exchange 4 messages
    public Duration computeTimeout (uint32 roundNumber);

    /*\ Inform about events happening within the consensus algorithm. */

    // `valueExternalized` is called at most once per slot when the slot
    // externalizes its value.
    public void valueExternalized (uint64 slotIndex, ref const(Value) value)
    {
    }

    // ``nominatingValue`` is called every time the local instance nominates
    // a new value.
    public void nominatingValue (uint64 slotIndex, ref const(Value) value);

    // the following methods are used for monitoring of the SCP subsystem
    // most implementation don't really need to do anything with these

    // `updatedCandidateValue` is called every time a new candidate value
    // is included in the candidate set, the value passed in is
    // a composite value
    public void updatedCandidateValue (uint64 slotIndex,
        ref const(Value) value);

    // `startedBallotProtocol` is called when the ballot protocol is started
    // (ie attempts to prepare a new ballot)
    public void startedBallotProtocol (uint64 slotIndex,
        ref const(SCPBallot) ballot);

    // `acceptedBallotPrepared` every time a ballot is accepted as prepared
    public void acceptedBallotPrepared (uint64 slotIndex,
        ref const(SCPBallot) ballot);

    // `confirmedBallotPrepared` every time a ballot is confirmed prepared
    public void confirmedBallotPrepared (uint64 slotIndex,
        ref const(SCPBallot) ballot);

    // `acceptedCommit` every time a ballot is accepted commit
    public void acceptedCommit (uint64 slotIndex, ref const(SCPBallot) ballot);

    // `ballotDidHearFromQuorum` is called when we received messages related to
    // the current `mBallot` from a set of node that is a transitive quorum for
    // the local node.
    public void ballotDidHearFromQuorum (uint64 slotIndex,
        ref const(SCPBallot) ballot);
}
