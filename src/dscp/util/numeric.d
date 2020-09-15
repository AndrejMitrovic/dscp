// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.util.numeric;

import core.stdc.stdint;

enum Rounding
{
    ROUND_DOWN,
    ROUND_UP
}

// calculates A*B/C when A*B overflows 64bits
long bigDivide(long A, long B, long C, Rounding rounding);
// no throw version, returns true if result is valid
bool bigDivide(ref long result, long A, long B, long C,
               Rounding rounding);

// no throw version, returns true if result is valid
bool bigDivide(ref ulong result, ulong A, ulong B, ulong C,
               Rounding rounding);

// todo: uint128_t is defined in libsodium, but might not need it
//bool bigDivide(ref long result, uint128_t a, long B, Rounding rounding);
//bool bigDivide(ref ulong result, uint128_t a, ulong B, Rounding rounding);
//long bigDivide(uint128_t a, long B, Rounding rounding);
//uint128_t bigMultiply(ulong a, ulong b);
//uint128_t bigMultiply(long a, long b);
