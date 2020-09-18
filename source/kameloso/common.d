/++
    Common functions used throughout the program, generic enough to be used in
    several places, not fitting into any specific one.
 +/
module kameloso.common;

private:

import kameloso.logger : KamelosoLogger;
import dialect.defs : IRCClient, IRCServer;
import std.datetime.systime : SysTime;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;
import core.time : Duration, seconds;

public:

@safe:

version(unittest)
shared static this()
{
    import kameloso.kameloso : CoreSettings;
    import std.experimental.logger : LogLevel;

    // This is technically before settings have been read...
    logger = new KamelosoLogger(No.monochrome, No.brightTerminal, Yes.flush);

    // settings needs instantiating now.
    settings = new CoreSettings;
}


// Remove these when appropriate.

/*public*/ static import kameloso.kameloso;

deprecated("Import from `kameloso.kameloso` directly instead")
{
    alias Kameloso = kameloso.kameloso.Kameloso;
    alias CoreSettings = kameloso.kameloso.CoreSettings;
    alias ConnectionSettings = kameloso.kameloso.ConnectionSettings;
    alias IRCBot = kameloso.kameloso.IRCBot;
}


// logger
/++
    Instance of a `kameloso.logger.KamelosoLogger`, providing timestamped and
    coloured logging.

    The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
    and `fatal`. It is not `__gshared`, so instantiate a thread-local
    `kameloso.logger.KamelosoLogger` if threading.

    Having this here is unfortunate; ideally plugins should not use variables
    from other modules, but unsure of any way to fix this other than to have
    each plugin keep their own `kameloso.common.logger` pointer.
 +/
KamelosoLogger logger;


// initLogger
/++
    Initialises the `kameloso.logger.KamelosoLogger` logger for use in this thread.

    It needs to be separately instantiated per thread, and even so there may be
    race conditions. Plugins are encouraged to use `kameloso.thread.ThreadMessage`s
    to log to screen from other threads.

    Example:
    ---
    initLogger(No.monochrome, Yes.brightTerminal, Yes.flush);
    ---

    Params:
        monochrome = Whether the terminal is set to monochrome or not.
        bright = Whether the terminal has a bright background or not.
        flush = Whether or not to flush stdout after finishing writing to it.
 +/
void initLogger(const Flag!"monochrome" monochrome,
    const Flag!"brightTerminal" bright,
    const Flag!"flush" flush)
out (; (logger !is null), "Failed to initialise logger")
{
    import kameloso.logger : KamelosoLogger;
    logger = new KamelosoLogger(monochrome, bright, flush);
    Tint.monochrome = monochrome;
}


// settings
/++
    A `CoreSettings` struct global, housing certain runtime settings.

    This will be accessed from other parts of the program, via
    `kameloso.common.settings`, so they know to use monochrome output or not.
    It is a problem that needs solving.
 +/
kameloso.kameloso.CoreSettings* settings;


version(Colours)
{
    private import kameloso.terminal : TerminalForeground;
}

// printVersionInfo
/++
    Prints out the bot banner with the version number and GitHub URL, with the
    passed colouring.

    Example:
    ---
    printVersionInfo(TerminalForeground.white);
    ---

    Params:
        colourCode = Terminal foreground colour to display the text in.
 +/
version(Colours)
void printVersionInfo(TerminalForeground colourCode) @system
{
    import kameloso.terminal : colour;

    enum fgDefault = TerminalForeground.default_.colour.idup;
    return printVersionInfo(colourCode.colour, fgDefault);
}


// printVersionInfo
/++
    Prints out the bot banner with the version number and GitHub URL, optionally
    with passed colouring in string format. Overload that does not rely on
    `kameloso.terminal.TerminalForeground` being available, yet takes the necessary
    parameters to allow the other overload to reuse this one.

    Example:
    ---
    printVersionInfo();
    ---

    Params:
        pre = String to preface the line with, usually a colour code string.
        post = String to end the line with, usually a resetting code string.
 +/
void printVersionInfo(const string pre = string.init, const string post = string.init) @safe
{
    import kameloso.constants : KamelosoInfo;
    import std.stdio : writefln;

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        pre,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        post);
}


// printStacktrace
/++
    Prints the current stacktrace to the terminal.

    This is so we can get the stacktrace even outside a thrown Exception.
 +/
version(PrintStacktraces)
void printStacktrace() @system
{
    import core.runtime : defaultTraceHandler;
    import std.stdio : writeln;

    writeln(defaultTraceHandler);
}


// OutgoingLine
/++
    A string to be sent to the IRC server, along with whether the message
    should be sent quietly or if it should be displayed in the terminal.
 +/
struct OutgoingLine
{
    /// String line to send.
    string line;

    /// Whether this message should be sent quietly or verbosely.
    bool quiet;

    /// Constructor.
    this(const string line, const Flag!"quiet" quiet = No.quiet)
    {
        this.line = line;
        this.quiet = quiet;
    }
}


// findURLs
/++
    Finds URLs in a string, returning an array of them. Does not filter out duplicates.

    Replacement for regex matching using much less memory when compiling
    (around ~300mb).

    To consider: does this need a `dstring`?

    Example:
    ---
    // Replaces the following:
    // enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
    // static urlRegex = ctRegex!stephenhay;

    string[] urls = findURL("blah https://google.com http://facebook.com httpx://wefpokwe");
    assert(urls.length == 2);
    ---

    Params:
        line = String line to examine and find URLs in.

    Returns:
        A `string[]` array of found URLs. These include fragment identifiers.
 +/
string[] findURLs(const string line) @safe pure
{
    import lu.string : contains, nom, strippedRight;
    import std.string : indexOf;
    import std.typecons : Flag, No, Yes;

    enum wordBoundaryTokens = ".,!?:";

    string[] hits;
    string slice = line;  // mutable

    ptrdiff_t httpPos = slice.indexOf("http");

    while (httpPos != -1)
    {
        if ((httpPos > 0) && (slice[httpPos-1] != ' '))
        {
            // Run-on http address (character before the 'h')
            slice = slice[httpPos+4..$];
            httpPos = slice.indexOf("http");
            continue;
        }

        slice = slice[httpPos..$];

        if (slice.length < 11)
        {
            // Too short, minimum is "http://a.se".length
            break;
        }
        else if ((slice[4] != ':') && (slice[4] != 's'))
        {
            // Not http or https, something else
            // But could still be another link after this
            slice = slice[5..$];
            httpPos = slice.indexOf("http");
            continue;
        }
        else if (!slice[8..$].contains('.'))
        {
            break;
        }
        else if (!slice.contains(' ') &&
            (slice[10..$].contains("http://") ||
            slice[10..$].contains("https://")))
        {
            // There is a second URL in the middle of this one
            break;
        }

        // nom until the next space if there is one, otherwise just inherit slice
        // Also strip away common punctuation
        hits ~= slice.nom!(Yes.inherit)(' ').strippedRight(wordBoundaryTokens);
        httpPos = slice.indexOf("http");
    }

    return hits;
}

///
unittest
{
    import std.conv : text;

    {
        const urls = findURLs("http://google.com");
        assert((urls.length == 1), urls.text);
        assert((urls[0] == "http://google.com"), urls[0]);
    }
    {
        const urls = findURLs("blah https://a.com http://b.com shttps://c https://d.asdf.asdf.asdf        ");
        assert((urls.length == 3), urls.text);
        assert((urls == [ "https://a.com", "http://b.com", "https://d.asdf.asdf.asdf" ]), urls.text);
    }
    {
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("http://a.sehttp://a.shttp://a.http://http:");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("blahblah https://motorbörsen.se blhblah");
        assert(urls.length, urls.text);
    }
    {
        // Let dlang-requests attempt complex URLs, don't validate more than necessary
        const urls = findURLs("blahblah https://高所恐怖症。co.jp blhblah");
        assert(urls.length, urls.text);
    }
    {
        const urls = findURLs("nyaa is now at https://nyaa.si, https://nyaa.si? " ~
            "https://nyaa.si. https://nyaa.si! and you should use it https://nyaa.si:");

        foreach (immutable url; urls)
        {
            assert((url == "https://nyaa.si"), url);
        }
    }
    {
        const urls = findURLs("https://google.se httpx://google.se https://google.se");
        assert((urls == [ "https://google.se", "https://google.se" ]), urls.text);
    }
}


// timeSinceInto
/++
    Express how much time has passed in a `core.time.Duration`, in natural
    (English) language. Overload that writes the result to the passed output range `sink`.

    Example:
    ---
    Appender!string sink;

    immutable then = Clock.currTime;
    Thread.sleep(1.seconds);
    immutable now = Clock.currTime;

    immutable duration = (now - then);
    immutable inEnglish = duration.timeSinceInto(sink);
    ---

    Params:
        abbreviate = Whether or not to abbreviate the output, using `h` instead
            of `hours`, `m` instead of `minutes`, etc.
        numUnits = Number of units to include in the output text, where such is
            "weeks", "days", "hours", "minutes" and "seconds", a fake approximate
            unit "months", and a fake "years" based on it. Passing a `numUnits`
            of 7 will express the time difference using all units. Passing one
            of 4 will only express it in days, hours, minutes and seconds.
            Passing 1 will express it in only seconds.
        truncateUnits = Number of units to skip from output, going from least
            significant (seconds) to most significant (years).
        duration = A period of time.
        sink = Output buffer sink to write to.
 +/
void timeSinceInto(Flag!"abbreviate" abbreviate = No.abbreviate,
    uint numUnits = 7, uint truncateUnits = 0, Sink)
    (const Duration duration, auto ref Sink sink) pure
if (isOutputRange!(Sink, char[]))
in ((duration >= 0.seconds), "Cannot call `timeSinceInto` on a negative duration")
{
    import lu.string : plurality;
    import std.algorithm.comparison : min;
    import std.format : formattedWrite;
    import std.meta : AliasSeq;

    static if ((numUnits < 1) || (numUnits > 7))
    {
        import std.format : format;

        enum pattern = "Invalid number of units passed to `timeSinceInto`: " ~
            "expected `1` to `7`, got `%d`";
        static assert(0, pattern.format(numUnits));
    }

    static if ((truncateUnits < 0) || (truncateUnits > 6))
    {
        import std.format : format;

        enum pattern = "Invalid number of units to truncate passed to `timeSinceInto`: " ~
            "expected `0` to `6`, got `%d`";
        static assert(0, pattern.format(truncateUnits));
    }

    alias units = AliasSeq!("weeks", "days", "hours", "minutes", "seconds");
    enum daysInAMonth = 30;  // The real average is 30.42 but we get unintuitive results.

    immutable diff = duration.split!(units[units.length-min(numUnits, 5)..$]);

    bool putSomething;

    static if (numUnits >= 1)
    {
        immutable trailingSeconds = (diff.seconds && (truncateUnits < 1));
    }

    static if (numUnits >= 2)
    {
        immutable trailingMinutes = (diff.minutes && (truncateUnits < 2));
    }

    static if (numUnits >= 3)
    {
        immutable trailingHours = (diff.hours && (truncateUnits < 3));
    }

    static if (numUnits >= 4)
    {
        immutable trailingDays = (diff.days && (truncateUnits < 4));
        long days = diff.days;
    }

    static if (numUnits >= 5)
    {
        immutable trailingWeeks = (diff.weeks && (truncateUnits < 5));
        long weeks = diff.weeks;
    }

    static if (numUnits >= 6)
    {
        uint months;

        {
            immutable totalDays = (diff.weeks * 7) + diff.days;
            months = cast(uint)(totalDays / daysInAMonth);
            days = cast(uint)(totalDays % daysInAMonth);
            weeks = (days / 7);
            days %= 7;
        }
    }

    static if (numUnits >= 7)
    {
        uint years;

        if (months >= 12) // && (truncateUnits < 7))
        {
            years = cast(uint)(months / 12);
            months %= 12;
        }
    }

    // -------------------------------------------------------------------------

    static if (numUnits >= 7)
    {
        if (years)
        {
            static if (abbreviate)
            {
                sink.formattedWrite("%dy", years);
            }
            else
            {
                sink.formattedWrite("%d %s", years,
                    years.plurality("year", "years"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 6)
    {
        if (months && (!putSomething || (truncateUnits < 6)))
        {
            static if (abbreviate)
            {
                static if (numUnits >= 7)
                {
                    if (putSomething) sink.put(' ');
                }

                sink.formattedWrite("%dm", months);
            }
            else
            {
                static if (numUnits >= 7)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours ||
                            trailingDays ||
                            trailingWeeks)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                sink.formattedWrite("%d %s", months,
                    months.plurality("month", "months"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 5)
    {
        if (weeks && (!putSomething || (truncateUnits < 5)))
        {
            static if (abbreviate)
            {
                static if (numUnits >= 6)
                {
                    if (putSomething) sink.put(' ');
                }

                sink.formattedWrite("%dw", weeks);
            }
            else
            {
                static if (numUnits >= 6)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours ||
                            trailingDays)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                sink.formattedWrite("%d %s", weeks,
                    weeks.plurality("week", "weeks"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 4)
    {
        if (days && (!putSomething || (truncateUnits < 4)))
        {
            static if (abbreviate)
            {
                static if (numUnits >= 5)
                {
                    if (putSomething) sink.put(' ');
                }

                sink.formattedWrite("%dd", days);
            }
            else
            {
                static if (numUnits >= 5)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                sink.formattedWrite("%d %s", days,
                    days.plurality("day", "days"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 3)
    {
        if (diff.hours && (!putSomething || (truncateUnits < 3)))
        {
            static if (abbreviate)
            {
                static if (numUnits >= 4)
                {
                    if (putSomething) sink.put(' ');
                }

                sink.formattedWrite("%dh", diff.hours);
            }
            else
            {
                static if (numUnits >= 4)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                sink.formattedWrite("%d %s", diff.hours,
                    diff.hours.plurality("hour", "hours"));
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 2)
    {
        if (diff.minutes && (!putSomething || (truncateUnits < 2)))
        {
            static if (abbreviate)
            {
                static if (numUnits >= 3)
                {
                    if (putSomething) sink.put(' ');
                }

                sink.formattedWrite("%dm", diff.minutes);
            }
            else
            {
                static if (numUnits >= 3)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                sink.formattedWrite("%d %s", diff.minutes,
                    diff.minutes.plurality("minute", "minutes"));
            }

            putSomething = true;
        }
    }

    if (trailingSeconds || !putSomething)
    {
        static if (abbreviate)
        {
            if (putSomething)
            {
                sink.put(' ');
            }

            sink.formattedWrite("%ds", diff.seconds);
        }
        else
        {
            if (putSomething)
            {
                sink.put(" and ");
            }

            sink.formattedWrite("%d %s", diff.seconds,
                diff.seconds.plurality("second", "seconds"));
        }
    }
}

///
unittest
{
    import core.time;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for formattedWrite < 2.076

    {
        immutable dur = 0.seconds;
        dur.timeSinceInto(sink);
        assert((sink.data == "0 seconds"), sink.data);
        sink.clear();
        dur.timeSinceInto!(Yes.abbreviate)(sink);
        assert((sink.data == "0s"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3_141_519_265.msecs;
        dur.timeSinceInto!(No.abbreviate, 4, 1)(sink);
        assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(Yes.abbreviate, 4, 1)(sink);
        assert((sink.data == "36d 8h 38m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(No.abbreviate, 2, 1)(sink);
        assert((sink.data == "59 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(Yes.abbreviate, 2, 1)(sink);
        assert((sink.data == "59m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 3.days + 35.minutes;
        dur.timeSinceInto!(No.abbreviate, 4, 1)(sink);
        assert((sink.data == "3 days and 35 minutes"), sink.data);
        sink.clear();
        dur.timeSinceInto!(Yes.abbreviate, 4, 1)(sink);
        assert((sink.data == "3d 35m"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 57.weeks + 1.days + 2.hours + 3.minutes + 4.seconds;
        dur.timeSinceInto!(No.abbreviate, 7, 4)(sink);
        assert((sink.data == "1 year, 1 month and 1 week"), sink.data);
        sink.clear();
        dur.timeSinceInto!(Yes.abbreviate, 7, 4)(sink);
        assert((sink.data == "1y 1m 1w"), sink.data);
        sink.clear();
    }
    {
        immutable dur = 4.seconds;
        dur.timeSinceInto!(No.abbreviate, 7, 4)(sink);
        assert((sink.data == "4 seconds"), sink.data);
        sink.clear();
        dur.timeSinceInto!(Yes.abbreviate, 7, 4)(sink);
        assert((sink.data == "4s"), sink.data);
        sink.clear();
    }
}


// timeSince
/++
    Express how much time has passed in a `core.time.Duration`, in natural
    (English) language. Overload that returns the result as a new string.

    Example:
    ---
    immutable then = Clock.currTime;
    Thread.sleep(1.seconds);
    immutable now = Clock.currTime;

    immutable duration = (now - then);
    immutable inEnglish = timeSince(duration);
    ---

    Params:
        abbreviate = Whether or not to abbreviate the output, using `h` instead
            of `hours`, `m` instead of `minutes`, etc.
        numUnits = Number of units to include in the output text, where such is
            "weeks", "days", "hours", "minutes" and "seconds", a fake approximate
            unit "months", and a fake "years" based on it. Passing a `numUnits`
            of 7 will express the time difference using all units. Passing one
            of 4 will only express it in days, hours, minutes and seconds.
            Passing 1 will express it in only seconds.
        truncateUnits = Number of units to skip from output, going from least
            significant (seconds) to most significant (years).
        duration = A period of time.

    Returns:
        A string with the passed duration expressed in natural English language.
 +/
string timeSince(Flag!"abbreviate" abbreviate = No.abbreviate,
    uint numUnits = 7, uint truncateUnits = 0)
    (const Duration duration) pure
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(60);
    duration.timeSinceInto!(abbreviate, numUnits, truncateUnits)(sink);
    return sink.data;
}

///
unittest
{
    import core.time;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince!(No.abbreviate, 4, 1);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 4, 1);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince!(No.abbreviate, 5, 1);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 5, 1);
        assert((since == "1 week, 2 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "1w 2d 3h 16m"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 1);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 1);
        assert((since == "789383 seconds"), since);
        assert((abbrev == "789383s"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 2, 0);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 2, 0);
        assert((since == "13156 minutes and 23 seconds"), since);
        assert((abbrev == "13156m 23s"), abbrev);
    }
    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince!(No.abbreviate, 7, 1);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 7, 1);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }
    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }
    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }
    {
        immutable dur = 1.days + 1.minutes + 1.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 7, 0);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 7, 0);
        assert((since == "1 day, 1 minute and 1 second"), since);
        assert((abbrev == "1d 1m 1s"), abbrev);
    }
    {
        immutable dur = 3.weeks + 6.days + 10.hours;
        immutable since = dur.timeSince!(No.abbreviate);
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "3 weeks, 6 days and 10 hours"), since);
        assert((abbrev == "3w 6d 10h"), abbrev);
    }
    {
        immutable dur = 377.days + 11.hours;
        immutable since = dur.timeSince!(No.abbreviate, 6);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 6);
        assert((since == "12 months, 2 weeks, 3 days and 11 hours"), since);
        assert((abbrev == "12m 2w 3d 11h"), abbrev);
    }
    {
        immutable dur = 395.days + 11.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 7, 1);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 7, 1);
        assert((since == "1 year, 1 month and 5 days"), since);
        assert((abbrev == "1y 1m 5d"), abbrev);
    }
    {
        immutable dur = 1.weeks + 9.days;
        immutable since = dur.timeSince!(No.abbreviate, 5);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 5);
        assert((since == "2 weeks and 2 days"), since);
        assert((abbrev == "2w 2d"), abbrev);
    }
    {
        immutable dur = 30.days + 1.weeks;
        immutable since = dur.timeSince!(No.abbreviate, 5);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 5);
        assert((since == "5 weeks and 2 days"), since);
        assert((abbrev == "5w 2d"), abbrev);
    }
    {
        immutable dur = 30.days + 1.weeks + 1.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 4, 0);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 4, 0);
        assert((since == "37 days and 1 second"), since);
        assert((abbrev == "37d 1s"), abbrev);
    }
    {
        immutable dur = 267.weeks + 4.days + 9.hours + 15.minutes + 1.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 7, 0);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 7, 0);
        assert((since == "5 years, 2 months, 1 week, 6 days, 9 hours, 15 minutes and 1 second"), since);
        assert((abbrev == "5y 2m 1w 6d 9h 15m 1s"), abbrev);
    }
    {
        immutable dur = 360.days + 350.days;
        immutable since = dur.timeSince!(No.abbreviate, 7, 6);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 7, 6);
        assert((since == "1 year"), since);
        assert((abbrev == "1y"), abbrev);
    }
    {
        immutable dur = 267.weeks + 4.days + 9.hours + 15.minutes + 1.seconds;
        immutable since = dur.timeSince!(No.abbreviate, 7, 3);
        immutable abbrev = dur.timeSince!(Yes.abbreviate, 7, 3);
        assert((since == "5 years, 2 months, 1 week and 6 days"), since);
        assert((abbrev == "5y 2m 1w 6d"), abbrev);
    }
}


// stripSeparatedPrefix
/++
    Strips a prefix word from a string, optionally also stripping away some
    non-word characters (currently ":;?! ").

    This is to make a helper for stripping away bot prefixes, where such may be
    "kameloso: ".

    Example:
    ---
    string prefixed = "kameloso: sudo MODE +o #channel :user";
    string command = prefixed.stripSeparatedPrefix("kameloso");
    assert((command == "sudo MODE +o #channel :user"), command);
    ---

    Params:
        demandSep = Makes it a necessity that `line` is followed
            by one of the prefix letters ":;?! ". If it isn't, the `line` string
            will be returned as is.
        line = String line prefixed with `prefix`, potentially including separating characters.
        prefix = Prefix to strip.

    Returns:
        The passed line with the `prefix` sliced away.
 +/
string stripSeparatedPrefix(Flag!"demandSeparatingChars" demandSep = Yes.demandSeparatingChars)
    (const string line, const string prefix) pure @nogc
in (prefix.length, "Tried to strip separated prefix but no prefix was given")
{
    import lu.string : nom, strippedLeft;

    enum separatingChars = ": !?;";  // In reasonable order of likelihood

    string slice = line.strippedLeft;  // mutable

    // the onus is on the caller that slice begins with prefix, else this will throw
    slice.nom!(Yes.decode)(prefix);

    static if (demandSep)
    {
        import std.algorithm.comparison : among;
        import std.meta : aliasSeqOf;

        // Return the whole line, a non-match, if there are no separating characters
        // (at least one of the chars in separatingChars)
        if (!slice.length || !slice[0].among!(aliasSeqOf!separatingChars)) return line;
        slice = slice[1..$];
    }

    return slice.strippedLeft(separatingChars);
}

///
unittest
{
    immutable lorem = "say: lorem ipsum".stripSeparatedPrefix("say");
    assert((lorem == "lorem ipsum"), lorem);

    immutable notehello = "note!!!! zorael hello".stripSeparatedPrefix("note");
    assert((notehello == "zorael hello"), notehello);

    immutable sudoquit = "sudo quit :derp".stripSeparatedPrefix("sudo");
    assert((sudoquit == "quit :derp"), sudoquit);

    /*immutable eightball = "8ball predicate?".stripSeparatedPrefix("");
    assert((eightball == "8ball predicate?"), eightball);*/

    immutable isnotabot = "kamelosois a bot".stripSeparatedPrefix("kameloso");
    assert((isnotabot == "kamelosois a bot"), isnotabot);

    immutable isabot = "kamelosois a bot"
        .stripSeparatedPrefix!(No.demandSeparatingChars)("kameloso");
    assert((isabot == "is a bot"), isabot);
}


// Tint
/++
    Provides an easy way to access the `*tint` members of our
    `kameloso.logger.KamelosoLogger` instance `logger`.

    It still accesses the global `kameloso.common.logger` instance, but is now
    independent of `kameloso.common.settings`.

    Example:
    ---
    logger.logf("%s%s%s am a %1$s%4$s%3$s!", Tint.info, "I", Tint.log, "fish");
    ---

    If the inner `monochrome` member is true, `Tint.*` will just return an empty string.
 +/
struct Tint
{
    /++
        Whether or not output should be coloured at all.
     +/
    static bool monochrome;

    version(Colours)
    {
        // opDispatch
        /++
            Provides the string that corresponds to the tint of the
            `std.experimental.logger.core.LogLevel` that was passed in string form
            as the `tint` `opDispatch` template parameter.

            This saves us the boilerplate of copy/pasting one function for each
            `std.experimental.logger.core.LogLevel`.
         +/
        pragma(inline, true)
        static string opDispatch(string tint)()
        in ((logger !is null), "`Tint." ~ tint ~ "` was called with an uninitialised `logger`")
        {
            import std.traits : isSomeFunction;

            enum tintfun = "logger." ~ tint ~ "tint";

            static if (__traits(hasMember, logger, tint ~ "tint") &&
                isSomeFunction!(mixin(tintfun)))
            {
                return monochrome ? string.init : mixin(tintfun);
            }
            else
            {
                static assert(0, "Unknown tint `" ~ tint ~ "` passed to `Tint.opDispatch`");
            }
        }
    }
    else
    {
        /++
            Returns an empty string, since we're not versioned `Colours`.
         +/
        pragma(inline, true)
        static string log()
        {
            return string.init;
        }

        alias info = log;
        alias warning = log;
        alias error = log;
        alias fatal = log;
        alias trace = log;
        alias reset = trace;
    }
}

///
unittest
{
    if (logger !is null)
    {
        version(Colours)
        {
            assert(Tint.log is logger.logtint);
            assert(Tint.info is logger.infotint);
            assert(Tint.warning is logger.warningtint);
            assert(Tint.error is logger.errortint);
            assert(Tint.fatal is logger.fataltint);
            assert(Tint.trace is logger.tracetint);
            assert(Tint.reset is logger.resettint);
        }
        else
        {
            assert(Tint.log == string.init);
            assert(Tint.info == string.init);
            assert(Tint.warning == string.init);
            assert(Tint.error == string.init);
            assert(Tint.fatal == string.init);
            assert(Tint.trace == string.init);
            assert(Tint.reset == string.init);
        }
    }
}


// replaceTokens
/++
    Apply some common text replacements. Used on part and quit reasons.

    Params:
        line = String to replace tokens in.
        client = The current `dialect.defs.IRCClient`.

    Returns:
        A modified string with token occurrences replaced.
 +/
string replaceTokens(const string line, const IRCClient client) @safe pure nothrow
{
    import kameloso.constants : KamelosoInfo;
    import std.array : replace;

    return line
        .replace("$nickname", client.nickname)
        .replace("$version", cast(string)KamelosoInfo.version_)
        .replace("$source", cast(string)KamelosoInfo.source);
}

///
unittest
{
    import kameloso.constants : KamelosoInfo;
    import std.format : format;

    IRCClient client;
    client.nickname = "harbl";

    {
        immutable line = "asdf $nickname is kameloso version $version from $source";
        immutable expected = "asdf %s is kameloso version %s from %s"
            .format(client.nickname, cast(string)KamelosoInfo.version_,
                cast(string)KamelosoInfo.source);
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
    {
        immutable line = "";
        immutable expected = "";
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
    {
        immutable line = "blerp";
        immutable expected = "blerp";
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
}


// replaceTokens
/++
    Apply some common text replacements. Used on part and quit reasons.
    Overload that doesn't take an `dialect.defs.IRCClient` and as such can't
    replace `$nickname`.

    Params:
        line = String to replace tokens in.

    Returns:
        A modified string with token occurrences replaced.
 +/
string replaceTokens(const string line) @safe pure nothrow
{
    import kameloso.constants : KamelosoInfo;
    import std.array : replace;

    return line
        .replace("$version", cast(string)KamelosoInfo.version_)
        .replace("$source", cast(string)KamelosoInfo.source);
}


// nextMidnight
/++
    Returns a `std.datetime.systime.SysTime` of the following midnight, for use
    with setting the periodical timestamp.

    Example:
    ---
    immutable now = Clock.currTime;
    immutable midnight = now.nextMidnight;
    writeln("Time until next midnight: ", (midnight - now));
    ---

    Params:
        now = A `std.date.systime.SysTime` of the base date from which to proceed
            to the next midnight.

    Returns:
        A `std.datetime.systime.SysTime` of the midnight following the date
        passed as argument.
 +/
SysTime nextMidnight(const SysTime now)
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;

    /+
        The difference between rolling and adding is that rolling does not affect
        larger units. For instance, rolling a SysTime one year's worth of days
        gets the exact same SysTime.
     +/

    auto next = SysTime(DateTime(now.year, now.month, now.day, 0, 0, 0), now.timezone)
        .roll!"days"(1);

    if (next.day == 1)
    {
        next.add!"months"(1);
    }

    return next;
}

///
unittest
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : UTC;

    immutable utc = UTC();

    immutable christmasEve = SysTime(DateTime(2018, 12, 24, 12, 34, 56), utc);
    immutable nextDay = christmasEve.nextMidnight;
    immutable christmasDay = SysTime(DateTime(2018, 12, 25, 0, 0, 0), utc);
    assert(nextDay.toUnixTime == christmasDay.toUnixTime);

    immutable someDay = SysTime(DateTime(2018, 6, 30, 12, 27, 56), utc);
    immutable afterSomeDay = someDay.nextMidnight;
    immutable afterSomeDayToo = SysTime(DateTime(2018, 7, 1, 0, 0, 0), utc);
    assert(afterSomeDay == afterSomeDayToo);

    immutable newyearsEve = SysTime(DateTime(2018, 12, 31, 0, 0, 0), utc);
    immutable newyearsDay = newyearsEve.nextMidnight;
    immutable alsoNewyearsDay = SysTime(DateTime(2019, 1, 1, 0, 0, 0), utc);
    assert(newyearsDay == alsoNewyearsDay);

    immutable troubleDay = SysTime(DateTime(2018, 6, 30, 19, 14, 51), utc);
    immutable afterTrouble = troubleDay.nextMidnight;
    immutable alsoAfterTrouble = SysTime(DateTime(2018, 7, 1, 0, 0, 0), utc);
    assert(afterTrouble == alsoAfterTrouble);

    immutable novDay = SysTime(DateTime(2019, 11, 30, 12, 34, 56), utc);
    immutable decDay = novDay.nextMidnight;
    immutable alsoDecDay = SysTime(DateTime(2019, 12, 1, 0, 0, 0), utc);
    assert(decDay == alsoDecDay);

    immutable lastMarch = SysTime(DateTime(2005, 3, 31, 23, 59, 59), utc);
    immutable firstApril = lastMarch.nextMidnight;
    immutable alsoFirstApril = SysTime(DateTime(2005, 4, 1, 0, 0, 0), utc);
    assert(firstApril == alsoFirstApril);
}
