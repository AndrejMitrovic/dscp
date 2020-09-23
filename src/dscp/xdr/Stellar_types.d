// Copyright 2015 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.xdr.Stellar_types;

import std.container;

alias uint32 = uint;
alias int32 = int;

alias uint64 = ulong;
alias int64 = long;

// workaround for std.vector.length
auto size (T)(T[] val) { return val.length; }

enum CryptoKeyType
{
    KEY_TYPE_ED25519 = 0,
    KEY_TYPE_PRE_AUTH_TX = 1,
    KEY_TYPE_HASH_X = 2
}

enum PublicKeyType
{
    PUBLIC_KEY_TYPE_ED25519 = CryptoKeyType.KEY_TYPE_ED25519
}

enum SignerKeyType
{
    SIGNER_KEY_TYPE_ED25519 = CryptoKeyType.KEY_TYPE_ED25519,
    SIGNER_KEY_TYPE_PRE_AUTH_TX = CryptoKeyType.KEY_TYPE_PRE_AUTH_TX,
    SIGNER_KEY_TYPE_HASH_X = CryptoKeyType.KEY_TYPE_HASH_X
}

struct Curve25519Secret
{
    ubyte[32] key;
}

struct Curve25519Public
{
    ubyte[32] key;
}

struct HmacSha256Key
{
    ubyte[32] key;
}

struct HmacSha256Mac
{
    ubyte[32] mac;
}
