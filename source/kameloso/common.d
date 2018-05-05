/++
 +  Common functions used throughout the program, generic enough to be used in
 +  several places, not fitting into any specific one.
 +/
module kameloso.common;

import kameloso.bash : BashForeground;
import kameloso.uda;

import std.datetime.systime : SysTime;
import std.experimental.logger : Logger;
import std.range : isOutputRange;
import std.traits : Unqual, isType, isArray, isAssociativeArray;
import std.typecons : Flag, No, Yes;

@safe:

version(unittest)
shared static this()
{
    import kameloso.logger : KamelosoLogger;

    // This is technically before settings have been read...
    logger = new KamelosoLogger;
}


// logger
/++
 +  Instance of a `kameloso.logger.KamelosoLogger`, providing timestamped and
 +  coloured logging.
 +
 +  The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
 +  and `fatal`. It is not global, so instantiate a thread-local `Logger` if
 +  threading.
 +
 +  Having this here is unfortunate; ideally plugins should not use variables
 +  from other modules, but unsure of any way to fix this other than to have
 +  each plugin keep their own `Logger`.
 +/
Logger logger;


// initLogger
/++
 +  Initialises the `kameloso.logger.KamelosoLogger` logger for use in this
 +  thread.
 +
 +  It needs to be separately instantiated per thread.
 +
 +  Example:
 +  ------------
 +  initLogger(settings.monochrome, settings.brightTerminal);
 +  ------------
 +
 +  Params:
 +      monochrome = Whether the terminal is set to monochrome or not.
 +      bright = Whether the terminal has a bright background or not.
 +/
void initLogger(bool monochrome = settings.monochrome,
    bool bright = settings.brightTerminal)
{
    import kameloso.logger : KamelosoLogger;
    import std.experimental.logger : LogLevel;

    logger = new KamelosoLogger(LogLevel.all, monochrome, bright);
}


// settings
/++
 +  A local copy of the `CoreSettings` struct, housing certain runtime settings.
 +
 +  This will be accessed from other parts of the program, via
 +  `kameloso.common.settings`, so they know to use monochrome output or not. It
 +  is a problem that needs solving.
 +/
CoreSettings settings;


// ThreadMessage
/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use
 +  string literals to differentiate between messages and then have big
 +  switches inside the catching function, but with these you can actually
 +  have separate concurrency-receiving delegates for each.
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server `PONG` event.
    struct Pong {}

    /// Concurrency message type asking to verbosely send a line to the server.
    struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    struct Quietline {}

    /// Concurrency message type asking to verbosely send throttled messages.
    struct Throttleline {}

    /// Concurrency message type asking to quit the server and the program.
    struct Quit {}

    /// Concurrency message type asking for a plugin to shut down cleanly.
    struct Teardown {}

    /// Concurrency message type asking to have plugins' configuration saved.
    struct Save {}

    /++
     +  Concurrency message asking for a reference to the arrays of
     +  `kameloso.plugins.common.IRCPlugin`s in the current `Client`.
     +/
    struct PeekPlugins {}
}


// SupportColours
/++
 +  Set version `SupportsColours` depending on the build configuration.
 +
 +  We can't do "version(blah) || version(bluh)" because of design decisions,
 +  so we do it this way to accomodate for version `Cygwin_` implying both
 +  `Windows` and `Colours`.
 +/
version(Colours)
{
    version = SupportsColours;
}
else version (Cygwin_)
{
    version = SupportsColours;
}


// CoreSettings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct, they're nicely gathered and easy to pass around.
 +  Some defaults are hardcoded here.
 +/
struct CoreSettings
{
    version(SupportsColours)
    {
        bool monochrome = false;  /// Logger monochrome setting.
    }
    else
    {
        bool monochrome = true;  /// Mainly version Windows.
    }

    /// Flag denoting whether the program should reconnect after disconnect.
    bool reconnectOnFailure = true;

    /// Flag denoting that the terminal has a bright background.
    bool brightTerminal = false;

    /// Flag denoting that we should save to file on exit.
    bool saveOnExit = false;

    /// Character(s) that prefix a bot chat command.
    string prefix = "!";

    @Unconfigurable
    {
        @Hidden
        string configFile = "kameloso.conf";  /// Main configuration file.
    }
}


// printObjects
/++
 +  Prints out struct objects, with all their printable members with all their
 +  printable values.
 +
 +  This is not only convenient for debugging but also usable to print out
 +  current settings and state, where such is kept in structs.
 +
 +  Example:
 +  ------------
 +  struct Foo
 +  {
 +      int foo;
 +      string bar;
 +      float f;
 +      double d;
 +  }
 +
 +  Foo foo, bar;
 +  printObjects(foo, bar);
 +  ------------
 +
 +  Params:
 +      widthArg = The width with which to pad output columns.
 +      things = Variadic list of struct objects to enumerate.
 +/
void printObjects(uint widthArg = 0, Things...)(Things things) @trusted
{
    import std.stdio : stdout;

    // writeln trusts `lockingTextWriter` so we will too.

    version(Colours)
    {
        if (settings.monochrome)
        {
            formatObjectsImpl!(No.coloured, widthArg)
                (stdout.lockingTextWriter, things);
        }
        else
        {
            formatObjectsImpl!(Yes.coloured, widthArg)
                (stdout.lockingTextWriter, things);
        }
    }
    else
    {
        formatObjectsImpl!(No.coloured, widthArg)
            (stdout.lockingTextWriter, things);
    }

    version(Cygwin_) stdout.flush();
}


// printObject
/++
 +  Single-object `printObjects`.
 +
 +  A shorthand "alias" for when there is only one object to print.
 +
 +  Example:
 +  ------------
 +  struct Foo
 +  {
 +      int foo;
 +      string bar;
 +      float f;
 +      double d;
 +  }
 +
 +  Foo foo;
 +  printObject(foo);
 +  ------------
 +
 +  Params:
 +      widthArg = The width with which to pad output columns.
 +      thing = Struct object to enumerate.
 +/
void printObject(uint widthArg = 0, Thing)(Thing thing)
{
    printObjects!widthArg(thing);
}


// formatObjectsImpl
/++
 +  Formats a struct object, with all its printable members with all their
 +  printable values.
 +
 +  This is an implementation template and should not be called directly;
 +  instead use `printObject` and `printObjects`.
 +
 +  Example:
 +  ------------
 +  struct Foo
 +  {
 +      int foo = 42;
 +      string bar = "arr matey";
 +      float f = 3.14f;
 +      double d = 9.99;
 +  }
 +
 +  Foo foo, bar;
 +  Appender!string sink;
 +
 +  sink.formatObjectsImpl!(Yes.coloured)(foo);
 +  sink.formatObjectsImpl!(No.coloured)(bar);
 +  writeln(sink.data);
 +  ------------
 +
 +  Params:
 +      coloured = Whether to display in colours or not.
 +      widthArg = The width with which to pad output columns.
 +      sink = Output range to write to.
 +      things = Variadic list of structs to enumerate and format.
 +/
private void formatObjectsImpl(Flag!"coloured" coloured = Yes.coloured,
    uint widthArg = 0, Sink, Things...)
    (auto ref Sink sink, Things things)
{
    import kameloso.string : stripSuffix;
    import kameloso.traits : isConfigurableVariable, longestMemberName, UnqualArray;
    import std.format : formattedWrite;
    import std.traits : hasUDA;

    static if (coloured)
    {
        import kameloso.bash : colour;
    }

    // workaround formattedWrite taking Appender by value
    version(LDC) sink.put(string.init);

    enum width = !widthArg ? longestMemberName!Things.length : widthArg;

    immutable bright = .settings.brightTerminal;

    with (BashForeground)
    foreach (thing; things)
    {
        alias Thing = Unqual!(typeof(thing));
        static if (coloured)
        {
            immutable titleColour = bright ? black : white;
            sink.formattedWrite("%s-- %s\n", titleColour.colour, Unqual!Thing
                .stringof
                .stripSuffix("Settings"));
        }
        else
        {
            sink.formattedWrite("-- %s\n", Unqual!Thing
                .stringof
                .stripSuffix("Settings"));
        }

        foreach (immutable i, member; thing.tupleof)
        {
            static if (!isType!member &&
                isConfigurableVariable!member &&
                !hasUDA!(thing.tupleof[i], Hidden) &&
                !hasUDA!(thing.tupleof[i], Unconfigurable))
            {
                import std.traits : isArray, isSomeString;

                alias T = Unqual!(typeof(member));
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (isSomeString!T)
                {
                    static if (coloured)
                    {
                        enum stringPattern = `%s%9s %s%-*s %s"%s"%s(%d)` ~ '\n';
                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;
                        immutable lengthColour = bright ? lightgrey : darkgrey;

                        sink.formattedWrite(stringPattern,
                            cyan.colour, T.stringof,
                            memberColour.colour, (width + 2), memberstring,
                            valueColour.colour, member,
                            lengthColour.colour, member.length);
                    }
                    else
                    {
                        enum stringPattern = `%9s %-*s "%s"(%d)` ~ '\n';
                        sink.formattedWrite(stringPattern, T.stringof,
                            (width + 2), memberstring,
                            member, member.length);
                    }
                }
                else static if (isArray!T)
                {
                    static if (coloured)
                    {
                        immutable thisWidth = member.length ?
                            (width + 2) : (width + 4);

                        enum arrayPattern = "%s%9s %s%-*s%s%s%s(%d)\n";
                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;
                        immutable lengthColour = bright ? lightgrey : darkgrey;

                        sink.formattedWrite(arrayPattern,
                            cyan.colour, UnqualArray!T.stringof,
                            memberColour.colour, thisWidth, memberstring,
                            valueColour.colour, member,
                            lengthColour.colour, member.length);
                    }
                    else
                    {
                        immutable thisWidth = member.length ?
                            (width + 2) : (width + 4);

                        enum arrayPattern = "%9s %-*s%s(%d)\n";

                        sink.formattedWrite(arrayPattern,
                            UnqualArray!T.stringof,
                            thisWidth, memberstring,
                            member,
                            member.length);
                    }
                }
                else
                {
                    static if (coloured)
                    {
                        enum normalPattern = "%s%9s %s%-*s  %s%s\n";
                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;

                        sink.formattedWrite(normalPattern,
                            cyan.colour, T.stringof,
                            memberColour.colour, (width + 2), memberstring,
                            valueColour.colour, member);
                    }
                    else
                    {
                        enum normalPattern = "%9s %-*s  %s\n";
                        sink.formattedWrite(normalPattern, T.stringof,
                            (width + 2), memberstring, member);
                    }
                }
            }
        }

        static if (coloured)
        {
            sink.put(default_.colour);
        }

        sink.put('\n');
    }
}

///
@system unittest
{
    import kameloso.string : has;
    import std.array : Appender;

    // Monochrome

    struct StructName
    {
        int i = 12_345;
        string s = "foo";
        bool b = true;
        float f = 3.14f;
        double d = 99.9;
    }

    StructName s;
    Appender!(char[]) sink;

    sink.reserve(128);  // ~119
    sink.formatObjectsImpl!(No.coloured)(s);

    enum structNameSerialised =
`-- StructName
      int i    12345
   string s   "foo"(3)
     bool b    true
    float f    3.14
   double d    99.9

`;
    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Adding Settings does nothing
    alias StructNameSettings = StructName;
    StructNameSettings so;
    sink.clear();
    sink.formatObjectsImpl!(No.coloured)(so);

    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Colour
    struct StructName2
    {
        int int_ = 12_345;
        string string_ = "foo";
        bool bool_ = true;
        float float_ = 3.14f;
        double double_ = 99.9;
    }

    version(Colours)
    {
        StructName2 s2;

        sink.clear();
        sink.reserve(256);  // ~239
        sink.formatObjectsImpl!(Yes.coloured)(s2);

        assert((sink.data.length > 12), "Empty sink after coloured fill");

        assert(sink.data.has("-- StructName"));
        assert(sink.data.has("int_"));
        assert(sink.data.has("12345"));

        assert(sink.data.has("string_"));
        assert(sink.data.has(`"foo"`));

        assert(sink.data.has("bool_"));
        assert(sink.data.has("true"));

        assert(sink.data.has("float_"));
        assert(sink.data.has("3.14"));

        assert(sink.data.has("double_"));
        assert(sink.data.has("99.9"));

        // Adding Settings does nothing
        alias StructName2Settings = StructName2;
        immutable sinkCopy = sink.data.idup;
        StructName2Settings s2o;

        sink.clear();
        sink.formatObjectsImpl!(Yes.coloured)(s2o);
        assert((sink.data == sinkCopy), sink.data);
    }
}


// scopeguard
/++
 +  Generates a string mixin of *scopeguards*.
 +
 +  This is a convenience function to automate basic
 +  `scope(exit|success|failure)` messages, as well as a custom "entry" message.
 +  Which scope to guard is passed by ORing the states.
 +
 +  Example:
 +  ------------
 +  mixin(scopeguard(entry|exit));
 +  ------------
 +
 +  Params:
 +      states = Bitmask of which states to guard.
 +      scopeName = Optional scope name to print. If none is supplied, the
 +          current function name will be used.
 +
 +  Returns:
 +      One or more scopeguards in string form. Mix them in to use.
 +/
string scopeguard(ubyte states = exit, string scopeName = string.init)
{
    import std.array : Appender;
    Appender!string app;

    string scopeString(const string state)
    {
        import std.string : format, toLower;

        if (scopeName.length)
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    logger.info("[%2$s] %3$s");
                }
            }.format(state.toLower, state, scopeName);
        }
        else
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    import std.string : indexOf;
                    enum __%2$sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%2$sfunName = __FUNCTION__[(__%2$sdotPos+1)..$];
                    logger.infof("[%%s] %2$s", __%2$sfunName);
                }
            }.format(state.toLower, state);
        }
    }

    string entryString(const string state)
    {
        import std.string : format, toLower;

        if (scopeName.length)
        {
            return
            q{
                logger.info("[%s] %s");
            }.format(scopeName, state);
        }
        else
        {
            return
            q{
                import std.string : indexOf;
                enum __%1$sdotPos  = __FUNCTION__.indexOf('.');
                enum __%1$sfunName = __FUNCTION__[(__%1$sdotPos+1)..$];
                logger.infof("[%%s] %1$s", __%1$sfunName);
            }.format(state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}

/++
 +  Bitflags used in combination with the `scopeguard` function, to generate
 +  *scopeguard* mixins.
 +/
enum : ubyte
{
    entry   = 1 << 0,  /// On entry of function.
    exit    = 1 << 1,  /// On exit of function.
    success = 1 << 2,  /// On successful exit of function.
    failure = 1 << 3,  /// On thrown exception or error in function.
}


// getMultipleOf
/++
 +  Given a number, calculate the largest multiple of `n` needed to reach that
 +  number.
 +
 +  It rounds up, and if supplied `Yes.alwaysOneUp` it will always overshoot.
 +  This is good for when calculating format pattern widths.
 +
 +  Example:
 +  ------------
 +  immutable width = 16.getMultipleOf(4);
 +  assert(width == 16);
 +  immutable width2 = 16.getMultipleOf!(Yes.oneUp)(4);
 +  assert(width2 == 20);
 +  ------------
 +
 +  Params:
 +      oneUp = Whether to always overshoot.
 +      num = Number to reach.
 +      n = Base value to find a multiplier for.
 +
 +  Returns:
 +      The multiple of `n` that reaches and possibly overshoots `num`.
 +/
uint getMultipleOf(Flag!"alwaysOneUp" oneUp = No.alwaysOneUp, Number)
    (Number num, int n)
{
    assert((n > 0), "Cannot get multiple of 0 or negatives");
    assert((num >= 0), "Cannot get multiples for a negative number");

    if (num == 0) return 0;

    if (num == n)
    {
        static if (oneUp) return (n * 2);
        else
        {
            return n;
        }
    }

    const frac = (num / double(n));
    const floor_ = cast(uint)frac;

    static if (oneUp)
    {
        const mod = (floor_ + 1);
    }
    else
    {
        const mod = (floor_ == frac) ? floor_ : (floor_ + 1);
    }

    return (mod * n);
}

///
unittest
{
    import std.conv : text;

    immutable n1 = 15.getMultipleOf(4);
    assert((n1 == 16), n1.text);

    immutable n2 = 16.getMultipleOf!(Yes.alwaysOneUp)(4);
    assert((n2 == 20), n2.text);

    immutable n3 = 16.getMultipleOf(4);
    assert((n3 == 16), n3.text);
    immutable n4 = 0.getMultipleOf(5);
    assert((n4 == 0), n4.text);

    immutable n5 = 1.getMultipleOf(1);
    assert((n5 == 1), n5.text);

    immutable n6 = 1.getMultipleOf!(Yes.alwaysOneUp)(1);
    assert((n6 == 2), n6.text);
}


// interruptibleSleep
/++
 +  Sleep in small periods, checking the passed `abort` bool inbetween to see
 +  if we should break and return.
 +
 +  This is useful when a different signal handler has been set up, as triggeing
 +  it won't break sleeps. This way it does, assuming the `abort` bool is the
 +  signal handler one.
 +
 +  Example:
 +  ------------
 +  interruptibleSleep(1.seconds, abort);
 +  ------------
 +
 +  Params:
 +      dur = Duration to sleep for.
 +      abort = Reference to the bool flag which, if set, means we should
 +          interrupt and return early.
 +/
void interruptibleSleep(D)(const D dur, ref bool abort) @system
{
    import core.thread : Thread, msecs, seconds;
    import std.algorithm.comparison : min;

    const step = 250.msecs;

    D left = dur;

    static immutable nothing = 0.seconds;

    while (left > nothing)
    {
        if (abort) return;

        const nextStep = min((left-step), step);

        if (nextStep <= nothing) break;

        Thread.sleep(nextStep);
        left -= step;
    }
}


@system:


// Client
/++
 +  State needed for the kameloso bot, aggregated in a struct for easier passing
 +  by reference.
 +/
struct Client
{
    import kameloso.connection : Connection;
    import kameloso.ircdefs : IRCBot;
    import kameloso.irc : IRCParser;
    import kameloso.plugins.common : IRCPlugin;

    // ThrottleValues
    /++
     +  Aggregate of values and state needed to throttle messages without
     +  polluting namespace too much.
     +/
    struct ThrottleValues
    {
        /// Graph constant modifier (inclination, MUST be negative).
        enum k = -1.2;

        /// Origo of x-axis (last sent message).
        SysTime t0;

        /// y at t0 (ergo y at x = 0, weight at last sent message).
        double m = 0.0;

        /// Increment to y on sent message.
        double increment = 1.0;

        /++
         +  Burst limit; how many messages*increment can be sent initially
         +  before throttling kicks in.
         +/
        double burst = 3.0;

        /// Don't copy this, just keep one instance.
        @disable this(this);
    }

    /// Nickname and other IRC variables for the bot.
    IRCBot bot;

    /// Runtime settings for bot behaviour.
    CoreSettings settings;

    /// The socket we use to connect to the server.
    Connection conn;

    /++
     +  A runtime array of all plugins. We iterate these when we have finished
     +  parsing an `kameloso.ircdefs.IRCEvent`, and call the relevant event
     +  handlers of each.
     +/
    IRCPlugin[] plugins;

    /// When a nickname was called `WHOIS` on, for hysteresis.
    long[string] whoisCalls;

    /// Parser instance.
    IRCParser parser;

    /// Curent day of the month, so we can track changes in day.
    ubyte today;

    /// Values and state needed to throttle sending messages.
    ThrottleValues throttling;

    /++
     +  When this is set by signal handlers, the program should exit. Other
     +  parts of the program will be monitoring it.
     +/
    __gshared bool* abort;

    /// Never copy this.
    @disable this(this);


    // initPlugins
    /++
     +  Resets and *minimally* initialises all plugins.
     +
     +  It only initialises them to the point where they're aware of their
     +  settings, and not far enough to have loaded any resources.
     +
     +  Params:
     +      customSettings = String array of custom settings to apply to plugins
     +          in addition to those read from the configuration file.
     +/
    void initPlugins(string[] customSettings)
    {
        import kameloso.plugins;
        import kameloso.plugins.common : IRCPluginState;
        import std.concurrency : thisTid;
        import std.datetime.systime : Clock;

        teardownPlugins();

        IRCPluginState state;
        state.bot = bot;
        state.settings = settings;
        state.mainThread = thisTid;
        const now = Clock.currTime;
        today = now.day;

        plugins.reserve(EnabledPlugins.length + 4);

        // Instantiate all plugin types in the `EnabledPlugins` `AliasSeq` in
        // `kameloso.plugins.package`
        foreach (Plugin; EnabledPlugins)
        {
            plugins ~= new Plugin(state);
        }

        version(Web)
        {
            plugins ~= new WebtitlesPlugin(state);
            plugins ~= new RedditPlugin(state);
            plugins ~= new BashQuotesPlugin(state);
        }

        version(Posix)
        {
            plugins ~= new PipelinePlugin(state);
        }

        foreach (plugin; plugins)
        {
            plugin.loadConfig(state.settings.configFile);
            plugin.rehashCounter = now.hour + 1;  // rehash next hour
        }

        plugins.applyCustomSettings(customSettings);
    }


    // teardownPlugins
    /++
    +  Tears down all plugins, deinitialising them and having them save their
    +  settings for a clean shutdown.
    +
    +  Think of it as a plugin destructor.
    +/
    void teardownPlugins()
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            try plugin.teardown();
            catch (const Exception e)
            {
                logger.warningf("Exception when tearing down %s: %s",
                    plugin.name, e.msg);
            }
        }

        // Zero out old plugins array
        plugins.length = 0;
    }


    // startPlugins
    /++
    +  *start* all plugins, loading any resources they may want.
    +
    +  This has to happen after `initPlugins` or there will not be any plugins
    +  in the `plugins` array to start.
    +/
    void startPlugins()
    {
        foreach (plugin; plugins)
        {
            plugin.start();
            auto pluginBot = plugin.bot;

            if (pluginBot != bot)
            {
                // start changed the bot; propagate
                bot = pluginBot;
                parser.bot = bot;
                propagateBot(bot);
            }
        }
    }


    // propagateBot
    /++
    +  Takes a bot and passes it out to all plugins.
    +
    +  This is called when a change to the bot has occured and we want to update
    +  all plugins to have an updated copy of it.
    +
    +  Params:
    +      bot = `kameloso.ircdefs.IRCBot` to propagate to all plugins.
    +/
    void propagateBot(IRCBot bot) pure nothrow @nogc @safe
    {
        foreach (plugin; plugins)
        {
            plugin.bot = bot;
        }
    }
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, with the
 +  passed colouring.
 +
 +  Example:
 +  ------------
 +  printVersionInfo(BashForeground.white);
 +  ------------
 +
 +  Params:
 +      colourCode = Bash foreground colour to display the text in.
 +/
void printVersionInfo(BashForeground colourCode = BashForeground.default_)
{
    import kameloso.constants : KamelosoInfo;
    import std.stdio : writefln, stdout;

    string pre;
    string post;

    version(Colours)
    {
        import kameloso.bash : colour;
        pre = colourCode.colour;
        post = BashForeground.default_.colour;
    }

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        pre,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        post);

    version(Cygwin_) stdout.flush();
}


// writeConfigurationFile
/++
 +  Write all settings to the configuration filename passed.
 +
 +  It gathers configuration text from all plugins before formatting it into
 +  nice columns, then writes it all in one go.
 +
 +  Example:
 +  ------------
 +  Client client;
 +  client.writeConfigurationFile(client.settings.configFile);
 +  ------------
 +
 +  Params:
 +      client = Refrence to the current `Client`, with all its settings.
 +      filename = String filename of the file to write to.
 +/
void writeConfigurationFile(ref Client client, const string filename)
{
    import kameloso.config : justifiedConfigurationText, serialise, writeToDisk;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(512);

    with (client)
    {
        sink.serialise(bot, bot.server, settings);

        foreach (plugin; plugins)
        {
            plugin.addToConfig(sink);
        }

        immutable justified = sink.data.justifiedConfigurationText;
        writeToDisk!(Yes.addBanner)(filename, justified);
    }
}


// deepSizeof
/++
 +  Naïvely sums up the size of something in memory.
 +
 +  It enumerates all fields in classes and structs and recursively sums up the
 +  space everything takes. It's naïve in that it doesn't take into account
 +  that some arrays and such may have been allocated in a larger chunk than the
 +  length of the array itself.
 +
 +  Example:
 +  ------------
 +  struct Foo
 +  {
 +      string asdf = "qwertyuiopasdfghjklxcvbnm";
 +      int i = 42;
 +      float f = 3.14f;
 +  }
 +
 +  Foo foo;
 +  writeln(foo.deepSizeof);
 +  ------------
 +
 +  Params:
 +      thing = Object to enumerate and add up the members of.
 +
 +  Returns:
 +      The calculated *minimum* number of bytes allocated for the passed
 +      object.
 +/
uint deepSizeof(T)(const T thing) pure @nogc @safe @property
{
    import std.traits : isArray, isAssociativeArray;

    uint total;

    total += T.sizeof;

    static if (is(T == struct) || is(T == class))
    {
        foreach (immutable i, value; thing.tupleof)
        {
            total += deepSizeof(thing.tupleof[i]);
        }
    }
    else static if (isArray!T)
    {
        import std.range : ElementEncodingType;
        alias E = ElementEncodingType!T;
        total += (E.sizeof * thing.length);
    }
    else static if (isAssociativeArray!T)
    {
        foreach (immutable elem; thing)
        {
            total += deepSizeof(elem);
        }
    }
    else
    {
        // T.sizeof is enough
    }

    return total;
}


// Labeled
/++
 +  Labels an item by wrapping it in a struct with an `id` field.
 +
 +  Access to the `thing` is passed on by use of `std.typecons.Proxy`, so this
 +  will transparently act like the original `thing` in most cases. The original
 +  object can be accessed via the `thing` member when it doesn't.
 +/
struct Labeled(Thing, Label, Flag!"disableThis" disableThis = No.disableThis)
{
public:
    import std.typecons : Proxy;

    /// The wrapped item.
    Thing thing;

    /// The label applied to the wrapped item.
    Label id;

    /// Create a new `Labeled` struct with the passed `id` identifier.
    this(Thing thing, Label id) pure nothrow @nogc @safe
    {
        this.thing = thing;
        this.id = id;
    }

    static if (disableThis)
    {
        /// Never copy this.
        @disable this(this);
    }

    /// Tranparently proxy all `Thing`-related calls to `thing`.
    mixin Proxy!thing;
}

///
unittest
{
    struct Foo {}
    Foo foo;
    Foo bar;

    Labeled!(Foo,int)[] arr;

    arr ~= labeled(foo, 1);
    arr ~= labeled(bar, 2);

    assert(arr[0].id == 1);
    assert(arr[1].id == 2);
}


// labeled
/++
 +  Convenience function to create a `Labeled` struct while inferring the
 +  template parameters from the runtime arguments.
 +
 +  Example:
 +  ------------
 +  Foo foo;
 +  auto namedFoo = labeled(foo, "hello world");
 +
 +  Foo bar;
 +  auto numberedBar = labeled(bar, 42);
 +  ------------
 +
 +  Params:
 +      thing = Object to wrap.
 +      label = Label ID to apply to the wrapped item.
 +
 +  Returns:
 +      The passed object, wrapped and labeled with the supplied ID.
 +/
auto labeled(Thing, Label, Flag!"disableThis" disableThis = No.disableThis)
    (Thing thing, Label label) pure nothrow @nogc @safe
{
    return Labeled!(Unqual!Thing, Unqual!Label, disableThis)(thing, label);
}

///
unittest
{
    auto foo = labeled("FOO", "foo");
    assert(is(typeof(foo) == Labeled!(string, string)));

    assert(foo.thing == "FOO");
    assert(foo.id == "foo");
}
