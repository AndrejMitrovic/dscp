module dscp.util.Log;

struct Log
{
    public void info (T...)(T args)
    {
    }

    alias error = info;
    alias trace = info;
}

Log log;
