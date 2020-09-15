// Copyright 2016 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.QuorumSetUtils;

import dscp.xdr.Stellar_types;
import dscp.xdr.Stellar_SCP;

bool isQuorumSetSane(ref const(SCPQuorumSet) qSet, bool extraChecks,
    const char** reason = null);

// normalize the quorum set, optionally removing idToRemove
void normalizeQSet(ref SCPQuorumSet qSet, const(NodeID)* idToRemove = null);