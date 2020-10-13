// Copyright 2016 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.QuorumSetUtils;

import dscp.xdr.Stellar_types;
import dscp.xdr.Stellar_SCP;

import std.array;
import std.algorithm;

import core.stdc.string;

struct QuorumSetSanityCheckerT (NodeID, alias hashPart)
{
    public alias SCPQuorumSet = SCPQuorumSetT!(NodeID, hashPart);

  public:
    this (ref const(SCPQuorumSet) qSet, bool extraChecks, const(char)** reason)
    {
        mExtraChecks = extraChecks;
        const(char)* msg = null;
        if (reason is null)
            reason = &msg;  // avoid null checks in checkSanity()

        mIsSane = checkSanity(qSet, 0, reason);
        if (mCount < 1)
        {
            *reason = "Number of validator nodes is zero";
            mIsSane = false;
        }
        else if (mCount > 1000)
        {
            *reason = "Number of validator nodes exceeds the limit of 1000";
            mIsSane = false;
        }

        // only one of the two may be true
        assert(mIsSane ^ (*reason !is null));
    }

    bool isSane() const
    {
        return mIsSane;
    }

  private:
    bool mExtraChecks;
    import std.container;
    alias Set (T) = RedBlackTree!(const(NodeID));

    Set!NodeID mKnownNodes;
    bool mIsSane;
    size_t mCount = 0;

    bool checkSanity(ref const(SCPQuorumSet) qSet, int depth, const(char)** reason)
    {
        mKnownNodes = new Set!NodeID;

        if (depth > 2)
        {
            *reason = "Cannot have sub-quorums with depth exceeding 2 levels";
            return false;
        }

        if (qSet.threshold < 1)
        {
            *reason = "The threshold for a quorum must equal at least 1";
            return false;
        }

        auto v = &qSet.validators;
        auto i = &qSet.innerSets;

        size_t totEntries = v.length + i.length;
        size_t vBlockingSize = totEntries - qSet.threshold + 1;
        mCount += v.length;

        if (qSet.threshold > totEntries)
        {
            *reason = "The threshold for a quorum exceeds total number of entries";
            return false;
        }

        // threshold is within the proper range
        if (mExtraChecks && qSet.threshold < vBlockingSize)
        {
            *reason = "Extra check: the threshold for a quorum is too low";
            return false;
        }

        foreach (n; *v)
        {
            if (mKnownNodes.insert(n) == 0)
            {
                *reason = "A duplicate node was configured within another quorum";
                // n was already present
                return false;
            }
        }

        foreach (iSet; *i)
        {
            if (!checkSanity(iSet, depth + 1, reason))
            {
                return false;
            }
        }

        return true;
    }
}

bool isQuorumSetSane(PublicKey, alias hashPart)(
    ref const(SCPQuorumSetT!(PublicKey, hashPart)) qSet,
    bool extraChecks, const(char)** reason = null)
{
    auto checker = QuorumSetSanityCheckerT!(PublicKey, hashPart)(
        qSet, extraChecks, reason);
    return checker.isSane();
}

// normalize the quorum set, optionally removing idToRemove
void normalizeQSet(PublicKey, alias hashPart)(
    ref SCPQuorumSetT!(PublicKey, hashPart) qSet,
    const(PublicKey)* idToRemove = null)
{
    normalizeQSetSimplify(qSet, idToRemove);
    normalizeQuorumSetReorder(qSet);
}

// helper function that:
//  * removes nodeID
//      { t: n, v: { ...BEFORE... , nodeID, ...AFTER... }, ...}
//      { t: n-1, v: { ...BEFORE..., ...AFTER...} , ... }
//  * simplifies singleton inner set into outerset
//      { t: n, v: { ... }, { t: 1, X }, ... }
//        into
//      { t: n, v: { ..., X }, .... }
//  * simplifies singleton innersets
//      { t:1, { innerSet } } into innerSet

void normalizeQSetSimplify (PublicKey, alias hashPart)(
    ref SCPQuorumSetT!(PublicKey, hashPart) qSet,
    const(PublicKey)* idToRemove)
{
    if (idToRemove)
    {
        auto old_len = qSet.validators.length;
        qSet.validators = qSet.validators.filter!(n => n != *idToRemove).array;
        qSet.threshold -= old_len - qSet.validators.length;
    }

    //foreach (idx; 0 .. qSet.innerSets)
    //auto i = &qSet.innerSets;
    //auto it = i.begin();
    //while (it != i.end())
    size_t idx;
    while (idx < qSet.innerSets.length)
    {
        normalizeQSetSimplify(qSet.innerSets[idx], idToRemove);
        // merge singleton inner sets into validator list
        if (qSet.innerSets[idx].threshold == 1 && qSet.innerSets[idx].validators.length == 1 &&
            qSet.innerSets[idx].innerSets.length == 0)
        {
            qSet.validators ~= qSet.innerSets[idx].validators.front();
            qSet.innerSets.dropIndex(idx);
        }

        idx++;
    }

    // simplify quorum set if needed
    if (qSet.threshold == 1 && qSet.validators.length == 0 &&
        qSet.innerSets.length == 1)
    {
        auto t = qSet.innerSets.back();
        qSet = t;
    }
}

private void dropIndex (T) (ref T[] arr, size_t index)
{
    assert(index < arr.length);
    immutable newLen = arr.length - 1;

    if (index != newLen)
        memmove(&(arr[index]), &(arr[index + 1]), T.sizeof * (newLen - index));

    arr.length = newLen;
}

// helper function that reorders validators and inner sets
// in a standard way
void normalizeQuorumSetReorder(PublicKey, alias hashPart)(
    ref SCPQuorumSetT!(PublicKey, hashPart) qset)
{
    sort(qset.validators);
    foreach (qs; qset.innerSets)
        normalizeQuorumSetReorder(qs);

    // now, we can reorder the inner sets
    qset.innerSets.sort!((a, b) => qSetCompareInt(a, b) < 0);
}

int intLexicographicalCompare(E, Compare)(E[] first, E[] last, Compare comp)
{
    foreach (idx, lhs; first)
    {
        if (idx < last.length)
        {
            auto c = comp(lhs, last[idx]);
            if (c != 0)
                return c;
        }
    }

    // todo: not sure about this
    if (first.length > last.length)
        return -1;

    if (last.length > first.length)
        return 1;

    return 0;
}

// returns -1 if l < r ; 0 if l == r ; 1 if l > r
// lexicographical sort
// looking at, in order: validators, innerSets, threshold
int qSetCompareInt(PublicKey, alias hashPart)
    (ref const(SCPQuorumSetT!(PublicKey, hashPart)) l,
    ref const(SCPQuorumSetT!(PublicKey, hashPart)) r)
{
    // compare by validators first
    auto res = intLexicographicalCompare(
        l.validators, r.validators,
        (ref const(PublicKey) l, ref const(PublicKey) r) {
            if (l < r)
                return -1;

            if (r < l)
                return 1;

            return 0;
        });

    if (res != 0)
        return res;

    // then compare by inner sets
    const li = &l.innerSets;
    const ri = &r.innerSets;
    res = intLexicographicalCompare(l.innerSets, r.innerSets, &qSetCompareInt);
    if (res != 0)
        return res;

    // compare by threshold
    return (l.threshold < r.threshold) ? -1
        : ((l.threshold == r.threshold) ? 0 : 1);
}
