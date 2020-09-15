
bool
Slot.federatedAccept(StatementPredicate voted, StatementPredicate accepted,
                      const(SCPEnvelope[NodeID]) envs)
{

}

bool
Slot.federatedRatify(StatementPredicate voted,
                      const(SCPEnvelope[NodeID]) envs)
{
    return LocalNode.isQuorum(
        getLocalNode().getQuorumSet(), envs,
        &this.getQuorumSetFromStatement, voted);
}

std.shared_ptr<LocalNode>
Slot.getLocalNode()
{
    return mSCP.getLocalNode();
}

SCPEnvelope[]
Slot.getEntireCurrentState()
{
    bool old = mFullyValidated;
    // fake fully validated to force returning all envelopes
    mFullyValidated = true;
    auto r = getCurrentState();
    mFullyValidated = old;
    return r;
}
}
