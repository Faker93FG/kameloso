module kameloso.plugins.sedreplace;

import kameloso.plugins.common;
import kameloso.ircdefs;

private:

/// Lifetime of a `Line` in `prevlines`, in seconds
enum replaceTimeoutSeconds = 3600;

/// Regex patterns to find lines like `s/foo/bar/`
enum sedPattern  = `^s/([^/]+)/([^/]*)/(g?)$`;
enum sedPattern2 = `^s#([^#]+)#([^#]*)#(g?)$`;
enum sedPattern3 = `^s\|([^|]+)\|([^|]*)\|(g?)$`;


// Line
/++
 +  Struct aggregate of a spoken line and the timestamp when it was said.
 +
 +  ------------
 +  struct Line
 +  {
 +      string content;
 +      long timestamp;
 +  }
 +  ------------
 +/
struct Line
{
    import std.datetime.systime : SysTime;

    /// Contents of last line uttered
    string content;

    /// When the last line was spoken, in UNIX time
    long timestamp;
}


// sedReplace
/++
 +  sed-replace a line with a substitution string.
 +
 +  This clones the behaviour of the UNIX-like `echo "foo" | sed 's/foo/bar'`
 +
 +  Params:
 +      originalLine = the line to apply the sed-replace pattern to.
 +      expression = the replace pattern to apply.
 +
 +  Returns:
 +      the original line with the changes the replace pattern caused.
 +/
string sedReplace(const string originalLine, const string expression) @safe
{
    import std.regex : matchAll, regex;

    static string doReplace(T)(T matches, const string originalLine) @safe
    {
        import std.regex : replaceAll, replaceFirst, regex;
        string result = originalLine;  // need mutable

        result = result
            .replaceAll(`\[`.regex, `\\[`)
            .replaceAll(`\]`.regex, `\\]`);

        foreach (const hit; matches)
        {
            const changeThis = hit[1];
            const toThis = hit[2];
            immutable globalFlag = (hit[3].length > 0);

            if (globalFlag)
            {
                result = result.replaceAll(changeThis.regex, toThis);
            }
            else
            {
                // We only care about the first result
                return result.replaceFirst(changeThis.regex, toThis);
            }
        }

        return result;
    }

    assert((expression.length > 2), originalLine);

    switch (expression[1])
    {
    case '/':
        return doReplace(expression.matchAll(sedPattern.regex), originalLine);

    case '#':
        return doReplace(expression.matchAll(sedPattern2.regex), originalLine);

    case '|':
        return doReplace(expression.matchAll(sedPattern3.regex), originalLine);

    default:
        return string.init;
    }
}

///
unittest
{
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789/");
        assert((after == "abc 789 def 456"), after);
    }

    {
        enum before = "I am a fish";
        immutable after = before.sedReplace("s|a|e|g");
        assert((after == "I em e fish"), after);
    }

    {
        enum before = "Lorem ipsum dolor sit amet";
        immutable after = before.sedReplace("s###g");
        assert((after == "Lorem ipsum dolor sit amet"), after);
    }

    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所/");
        assert((after == "閉所恐怖症"), after);
    }
}


// onMessage
/++
 +  Parses a channel message and looks for any sed-replace expressions therein,
 +  to apply on the previous message.
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.anyone)  // ?
@(ChannelPolicy.home)
void onMessage(SedReplacePlugin plugin, const IRCEvent event)
{
    import kameloso.messaging : chan;
    import kameloso.string : beginsWith;
    import core.time : seconds;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.string : strip;

    immutable stripped = event.content.strip();

    if (stripped.beginsWith("s") && (stripped.length > 2))
    {
        switch (stripped[1])
        {
        case '/':
        case '|':
        case '#':
            if (const line = event.sender.nickname in plugin.prevlines)
            {
                if ((Clock.currTime.toUnixTime - line.timestamp) >
                    replaceTimeoutSeconds)
                {
                    // Entry is too old, remove it
                    plugin.prevlines.remove(event.sender.nickname);
                    return;
                }

                immutable result = line.content.sedReplace(event.content);
                if ((result == event.content) || !result.length) return;

                plugin.chan(event.channel, "%s | %s"
                    .format(event.sender.nickname, result));

                plugin.prevlines.remove(event.sender.nickname);
            }

            // Processed a sed-replace command (succesfully or not); return
            return;

        default:
            // Drop down
            break;
        }
    }

    // We're either here because !stripped.beginsWith("s") *or* stripped[1]
    // is not '/', '|' nor '#'
    // --> normal message, store as previous line

    Line line;
    line.content = stripped;
    line.timestamp = Clock.currTime.toUnixTime;
    plugin.prevlines[event.sender.nickname] = line;
}


mixin UserAwareness;

public:


// SedReplacePlugin
/++
 +  The SedReplace plugin stores a buffer of the last said line of every user,
 +  and if a new message comes in with a sed-replace-like pattern in it, tries
 +  to apply it on the original message as a regex replace.
 +/
final class SedReplacePlugin : IRCPlugin
{
    /// A `Line[string]` 1-buffer of the previous line every user said,
    /// with nickname as key
    Line[string] prevlines;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
