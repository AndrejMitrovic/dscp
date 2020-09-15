// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

#pragma once

namespace stellar
{
void assertThreadIsMain();

#ifdef NDEBUG

#define assert(expression) ((void)0)

#else

#define assert(expression) (void)((!!(expression)) || (assert(0), 0))

#endif
}
