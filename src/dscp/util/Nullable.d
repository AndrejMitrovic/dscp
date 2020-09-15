module dscp.util.Nullable;

// because std.typecons.Nullable is hot garbage
struct Nullable(T)
{
    this (T payload ) { this.ok = true; this._payload = payload; }
    bool ok = false;
    auto opCast(X = bool)() { return ok; }

    T _payload;
    alias _payload this;
}

///
unittest
{
    static struct Node { string[string] data; }

    // hardcoded example, the function will return an
    // error state if willSucceed is set to false
    static Nullable!Node getNode(bool willSucceed)
    {
        typeof(return) result;

        if (willSucceed)
            result.data["foo"] = "bar";
        else
            result.ok = false;

        return result;
    }

    if (auto node = getNode(true))
        assert(node.data == ["foo" : "bar"]);
    else
        assert(0);  // shouldn't get to here

    // enforce also works
    if (auto node = enforce(getNode(true)))
        assert(node.data == ["foo" : "bar"]);

    if (auto node = getNode(false))
        assert(0);  // shouldn't get to here

    try
    {
        // this will throw
        if (auto node = enforce(getNode(false))) { }
        assert(0);
    }
    catch (Exception)
    {
    }
}
