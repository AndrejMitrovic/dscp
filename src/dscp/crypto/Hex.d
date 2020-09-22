// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.crypto.Hex;

import dscp.crypto.ByteSlice;
import dscp.xdr.Stellar_types;

import std.conv;

import core.stdc.stdint;

// Hex-encode a ByteSlice.
string binToHex (in ByteSlice bin)
{
    return bin.to!string;
}

// Hex-encode a ByteSlice and return a 6-character prefix of it (for logging).
string hexAbbrev (in ByteSlice bin)
{
    return bin.to!string;
}

string hexAbbrev (in ubyte[64] bin)
{
    return bin.to!string;
}

string hexAbbrev (T)(T hash)
{
    return hash.to!string;
}
