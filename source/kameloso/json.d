/++
 +  Simple JSON wrappers to make keeping JSON storages easier.
 +/
module kameloso.json;


@safe:


// JSONStorage
/++
 +  A wrapped `JSONValue` with helper functions.
 +
 +  This deduplicates some code currently present in more than one plugin.
 +
 +  Example:
 +  ---
 +  JSONStorage s;
 +  s.reset();  // not always necessary
 +  s.storage["foo"] = null;  // JSONValue quirk
 +  s.storage["foo"]["abc"] = JSONValue(42);
 +  s.storage["foo"]["def"] = JSONValue(3.14f);
 +  s.storage["foo"]["ghi"] = JSONValue([ "bar", "baz", "qux" ]);
 +  s.storage["bar"] = JSONValue("asdf");
 +  assert(s.storage.length == 2);
 +  ---
 +/
struct JSONStorage
{
    import std.json : JSONValue, parseJSON;

    /// The underlying `JSONValue` storage of this `JSONStorage`.
    JSONValue storage;

    alias storage this;

    // reset
    /++
     +  Initialises and clears the `JSONValue`, preparing it for object storage.
     +/
    void reset()
    {
        storage.object = null;
    }

    // load
    /++
     +  Loads JSON from disk.
     +
     +  In the case where the file doesn't exist or is otherwise invalid, then
     +  `JSONValue` is initialised to null (by way of `reset`).
     +
     +  Params:
     +      filename = Filename of file to read from.
     +
     +  Throws:
     +      Whatever `std.file.readText` and/or `std.json.parseJSON` throws.
     +/
    void load(const string filename)
    {
        import kameloso.common : FileTypeMismatchException;
        import std.file : exists, getAttributes, isFile, readText;
        import std.path : baseName;
        import std.json : JSONException;

        if (!filename.exists)
        {
            return reset();
        }
        else if (!filename.isFile)
        {
            reset();
            throw new FileTypeMismatchException("File exists but is not a file.",
                filename.baseName, cast(ushort)getAttributes(filename), __FILE__, __LINE__);
        }

        immutable fileContents = readText(filename);
        storage = parseJSON(fileContents.length ? fileContents : "{}");
    }

    // save
    /++
     +  Saves a JSON storage to disk (in its prettyString format).
     +
     +  Params:
     +      filename = Filename of file to read from.
     +/
    void save(const string filename)
    {
        import std.stdio : File, writeln;

        auto file = File(filename, "w");

        file.writeln(storage.toPrettyString);
    }
}

///
@system
unittest
{
    import std.conv : text;
    import std.json : JSONValue;

    JSONStorage s;
    s.reset();

    s.storage["key"] = null;
    s.storage["key"]["subkey1"] = "abc";
    s.storage["key"]["subkey2"] = "def";
    s.storage["key"]["subkey3"] = "ghi";
    assert((s.storage["key"].object.length == 3), s.storage["key"].object.length.text);

    s.storage["foo"] = null;
    s.storage["foo"]["arr"] = JSONValue([ "blah "]);
    s.storage["foo"]["arr"].array ~= JSONValue("bluh");
    assert((s.storage["foo"]["arr"].array.length == 2), s.storage["foo"]["arr"].array.length.text);
}
