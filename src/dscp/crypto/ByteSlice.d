// Copyright 2014 Stellar Development Foundation and contributors. Licensed
// under the Apache License, Version 2.0. See the COPYING file at the root
// of this distribution or at http://www.apache.org/licenses/LICENSE-2.0
module dscp.crypto.ByteSlice;

import core.stdc.string;

/**
 * Transient adaptor type to permit passing a few different sorts of
 * byte-container types into encoder functions.
 */
struct ByteSlice
{
    private const(ubyte)* mData;
    private const size_t mSize;

    // note: this used to be a templated ctor - but D does not support it
    this (ref const(ubyte[64]) arr)
    {
        mData = arr.ptr;
        mSize = arr.length;
    }

    //this (xdr::msg_ptr const& p)
    //{
    //    mData(p->data()), mSize(p->size());
    //}

    this (ubyte[] bytes)
    {
        mData = bytes.ptr;
        mSize = bytes.length;
    }

    this (string str)
    {
        mData = cast(typeof(mData))str.ptr;
        mSize = str.length;
    }

    this (const(char)* str)
    {
        this(cast(const(ubyte)*)str, strlen(str));
    }

    this (const(ubyte)* data, size_t size)
    {
        mData = data;
        mSize = size;
    }

    public const(ubyte)* data() const
    {
        return mData;
    }

    public const(ubyte)* begin() const
    {
        return data();
    }

    public const(ubyte)* end() const
    {
        return data() + size();
    }

    public ubyte opIndex (size_t i) const
    {
        if (i >= mSize)
            assert(0, "ByteSlice index out of bounds");

        return data()[i];
    }

    public size_t size () const
    {
        return mSize;
    }

    public bool empty () const
    {
        return mSize == 0;
    }
}
