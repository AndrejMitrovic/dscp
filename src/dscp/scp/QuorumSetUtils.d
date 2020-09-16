// Copyright 2016 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0

module dscp.scp.QuorumSetUtils;

import dscp.xdr.Stellar_types;
import dscp.xdr.Stellar_SCP;

import std.array;
import std.algorithm;

struct QuorumSetSanityChecker
{
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
    set!NodeID mKnownNodes;
    bool mIsSane;
    size_t mCount = 0;

    bool checkSanity(ref const(SCPQuorumSet) qSet, int depth, const(char)** reason)
    {
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

bool isQuorumSetSane(ref const(SCPQuorumSet) qSet, bool extraChecks,
    const(char)** reason = null)
{
    auto checker = QuorumSetSanityChecker(qSet, extraChecks, reason);
    return checker.isSane();
}

// normalize the quorum set, optionally removing idToRemove
void normalizeQSet(ref SCPQuorumSet qSet, const(NodeID)* idToRemove = null)
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

void normalizeQSetSimplify (ref SCPQuorumSet qSet, const(NodeID)* idToRemove)
{
    auto v = &qSet.validators;
    if (idToRemove)
    {
        auto old_len = qSet.validators.length;
        qSet.validators = qSet.validators.filter!(n => n == *idToRemove).array;
        qSet.threshold -= old_len - qSet.validators.length;
    }

    //foreach (idx; 0 .. qSet.innerSets)
    //auto i = &qSet.innerSets;
    //auto it = i.begin();
    //while (it != i.end())
    {
        normalizeQSetSimplify(qSet.innerSets[idx], idToRemove);
        // merge singleton inner sets into validator list
        if (it.threshold == 1 && it.validators.length == 1 &&
            it.innerSets.length == 0)
        {
            v ~= it.validators.front();
            it = i.erase(it);
        }
        else
        {
            it++;
        }
    }

    // simplify quorum set if needed
    if (qSet.threshold == 1 && v.length == 0 && i.length == 1)
    {
        auto t = qSet.innerSets.back();
        qSet = t;
    }
}

// helper function that reorders validators and inner sets
// in a standard way
void
normalizeQuorumSetReorder(ref SCPQuorumSet qset)
{
    std.sort(qset.validators.begin(), qset.validators.end());
    foreach (qs; qset.innerSets)
    {
        normalizeQuorumSetReorder(qs);
    }

    // now, we can reorder the inner sets
    qset.innerSets.sort!((a, b) => qSetCompareInt(a, b) < 0);
}

int
intLexicographicalCompare(InputIt1, InputIt2, Compare)(InputIt1 first1, InputIt1 last1, InputIt2 first2,
                          InputIt2 last2, Compare comp)
{
    for (; first1 != last1 && first2 != last2; first1++, first2++)
    {
        auto c = comp(*first1, *first2);
        if (c != 0)
        {
            return c;
        }
    }
    if (first1 == last1 && first2 != last2)
    {
        return -1;
    }
    if (first1 != last1 && first2 == last2)
    {
        return 1;
    }
    return 0;
}

// returns -1 if l < r ; 0 if l == r ; 1 if l > r
// lexicographical sort
// looking at, in order: validators, innerSets, threshold
int
qSetCompareInt(ref const(SCPQuorumSet) l, ref const(SCPQuorumSet) r)
{
    auto lvals = &l.validators;
    auto rvals = &r.validators;

    // compare by validators first
    auto res = intLexicographicalCompare(
        lvals.begin(), lvals.end(), rvals.begin(), rvals.end(),
        (ref const(PublicKey) l, ref const(PublicKey) r) {
            if (l < r)
            {
                return -1;
            }
            if (r < l)
            {
                return 1;
            }
            return 0;
        });
    if (res != 0)
    {
        return res;
    }

    // then compare by inner sets
    const li = &l.innerSets;
    const ri = &r.innerSets;
    res = intLexicographicalCompare(li.begin(), li.end(), ri.begin(), ri.end(),
                                    qSetCompareInt);
    if (res != 0)
    {
        return res;
    }

    // compare by threshold
    return (l.threshold < r.threshold) ? -1
                                       : ((l.threshold == r.threshold) ? 0 : 1);
}
