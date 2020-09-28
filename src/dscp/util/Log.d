module dscp.util.Log;

import std.stdio;

struct Log
{
    template log (string type)
    {
        public void log (T...)(T args)
        {
            //writefln("[%s] " ~ args[0], type, args[1 .. $]);
            writefln(args[0], args[1 .. $]);
        }
    }

    alias error = log!"error";
    alias trace = log!"trace";
    alias info = log!"info";
}

Log log;
