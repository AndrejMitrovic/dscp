// Copyright 2015 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.xdr.Stellar_SCP;

import dscp.xdr.Stellar_types;

//alias Value = ubyte[];

struct SCPBallotT (Value)
{
    int opCmp (const ref SCPBallotT rhs) inout
    {
        if (this.counter < rhs.counter)
            return -1;

        if (this.value < rhs.value)
            return -1;

        return 0;
    }

    uint32 counter; // n
    Value value;    // x
}

enum SCPStatementType
{
    SCP_ST_PREPARE = 0,
    SCP_ST_CONFIRM = 1,
    SCP_ST_EXTERNALIZE = 2,
    SCP_ST_NOMINATE = 3
}

struct SCPNominationT (Hash, Value)
{
    Hash quorumSetHash; // D
    Value[] votes;      // X
    Value[] accepted;   // Y
}

struct SCPStatementT (NodeID, Hash, Value)
{
    private alias SCPBallot = SCPBallotT!Value;
    private alias SCPNomination = SCPNominationT!(Hash, Value);

    NodeID nodeID;    // v
    uint64 slotIndex; // i

    static struct _pledges_t
    {
        static struct _prepare_t
        {
            Hash quorumSetHash;       // D
            SCPBallot ballot;         // b
            SCPBallot* prepared;      // p
            SCPBallot* preparedPrime; // p'
            uint32 nC;                // c.n
            uint32 nH;                // h.n
        }

        static struct _confirm_t
        {
            SCPBallot ballot;   // b
            uint32 nPrepared;   // p.n
            uint32 nCommit;     // c.n
            uint32 nH;          // h.n
            Hash quorumSetHash; // D
        }

        static struct _externalize_t
        {
            SCPBallot commit;         // c
            uint32 nH;                // h.n
            Hash commitQuorumSetHash; // D used before EXTERNALIZE
        }

        // todo: use union, or replace with something better
        //static union
        //{
            _prepare_t prepare_;
            _confirm_t confirm_;
            _externalize_t externalize_;
            SCPNomination nominate_;
        //}

        SCPStatementType type_;
    }

    _pledges_t pledges;
}

struct SCPEnvelopeT (NodeID, Hash, Value, Signature)
{
    SCPStatementT!(NodeID, Hash, Value) statement;
    Signature signature;
}

// supports things like: A,B,C,(D,E,F),(G,H,(I,J,K,L))
// only allows 2 levels of nesting
struct SCPQuorumSetT (PublicKey)
{
    uint32 threshold;
    PublicKey[] validators;
    alias nodes = validators;
    SCPQuorumSetT!PublicKey[] innerSets;
    alias quorums = innerSets;

    public void computeHash (void delegate(scope const(ubyte)[]) dg)
        const nothrow @safe @nogc
    {
        // todo
        //hashPart(this.threshold, dg);

        //foreach (const ref node; this.validators)
        //    hashPart(node, dg);

        //foreach (const ref quorum; this.innerSets)
        //    hashPart(quorum, dg);
    }
}
