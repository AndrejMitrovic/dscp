// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.crypto.Hash;

import dscp.xdr.Stellar_SCP;
import dscp.xdr.Stellar_types;

import core.stdc.stdint;

/*******************************************************************************

    Prototypes of the hashing routines which should be implemented
    by the client code of SCP.

    Params:
        qset = the SCP quorum set to hash

    Returns:
        the 64-byte hash

*******************************************************************************/

uint512 getHashOf (ref const(SCPQuorumSet))
{
    // todo: fixup
    return uint512.init;
}

/// Ditto
uint512 getHashOf (ref const(Value))
{
    // todo: fixup
    return uint512.init;
}

/// Ditto
uint512 getHashOf (uint64_t, ref const(Value), uint32_t, int32_t, ref const(NodeID))
{
    // todo: fixup
    return uint512.init;
}

/// Ditto
uint512 getHashOf (uint64_t, ref const(Value), uint32_t, int32_t, ref const(Value))
{
    // todo: fixup
    return uint512.init;
}
