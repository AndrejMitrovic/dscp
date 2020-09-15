// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

#include "crypto/Hex.h"
#include <sodium.h>

namespace stellar
{

std.string
binToHex(ByteSlice const& bin)
{
    // NB: C++ standard says we can't go modifying the contents of a std.string
    // just by const_cast'ing away const on .data(), so we use a vector<char> to
    // write to.
    if (bin.empty())
        return "";
    ubyte[] hex(bin.length * 2 + 1, '\0');
    if (sodium_bin2hex(hex.data(), hex.length, bin.data(), bin.length) !=
        hex.data())
    {
        throw std.runtime_error(
            "error in stellar.binToHex(ubyte[])");
    }
    return std.string(hex.begin(), hex.end() - 1);
}

std.string
hexAbbrev(ByteSlice const& bin)
{
    size_t sz = bin.length;
    if (sz > 3)
    {
        sz = 3;
    }
    return binToHex(ByteSlice(bin.data(), sz));
}

ubyte[]
hexToBin(std.string const& hex)
{
    ubyte[] bin(hex.length / 2, 0);
    if (sodium_hex2bin(bin.data(), bin.length, hex.data(), hex.length, null,
                       null, null) != 0)
    {
        throw std.runtime_error("error in stellar.hexToBin(std.string)");
    }
    return bin;
}

uint256
hexToBin256(std.string const& hex)
{
    uint256 out;
    auto bin = hexToBin(hex);
    if (bin.length != out.length)
    {
        throw std.runtime_error(
            "wrong number of hex bytes when decoding uint256");
    }
    memcpy(out.data(), bin.data(), bin.length);
    return out;
}
}
