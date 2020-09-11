/*
 *             Copyright Andrej Mitrovic 2020.
 *  Distributed under the Boost Software License, Version 1.0.
 *     (See accompanying file LICENSE_1_0.txt or copy at
 *           http://www.boost.org/LICENSE_1_0.txt)
 */
module dscp.nominate.nominator;

import dscp.types;

// todo: pass a delegate for processing a NominateMessage for validation
struct Nominator
{
    PublicKey node_id;
    Hash quorum_hash;
}
