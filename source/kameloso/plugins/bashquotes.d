/++
 +  The Bash Quotes plugin fetches quotes from `www.bash.org` and displays them
 +  in a channel (or to a private query). It can fetch a random one or one
 +  by quote ID.
 +
 +  It has one command:
 +
 +  `bash`
 +
 +  It requires version `Web`.
 +/
module kameloso.plugins.bashquotes;

version(Web):

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

private:


// BashQuotesSettings
/++
 +  All `BashQuotesPlugin` settings, gathered in a struct.
 +/
struct BashQuotesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;
}


// onMessage
/++
 +  Fetch a random or specified `bash.org` quote.
 +
 +  Defers to the worker subthread.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("bash")
@BotCommand(NickPolicy.required, "bash")
@Description("Fetch a random or specified bash.org quote.")
void onMessage(BashQuotesPlugin plugin, const IRCEvent event)
{
    if (!plugin.bashQuotesSettings.enabled) return;

    import std.concurrency : spawn;

    // Defer all work to the worker thread
    spawn(&worker, cast(shared)plugin.state, event);
}


// worker
/++
 +  Looks up a Bash quote and reports it to the appropriate nickname or
 +  channel.
 +
 +  Supposed to be run in its own, shortlived thread. As such, it initialises
 +  its own `kameloso.logger.KamelosoLogger`.
 +/
void worker(shared IRCPluginState sState, const IRCEvent event)
{
    import kameloso.common;
    import kameloso.messaging : privmsg;
    import arsd.dom : Document, htmlEntitiesDecode;
    import requests : getContent;
    import std.algorithm.iteration : splitter;
    import std.format : format;
    import std.regex : regex, replaceAll;

    IRCPluginState state = cast(IRCPluginState)sState;

    kameloso.common.settings = state.settings;
    initLogger(state.settings.monochrome, state.settings.brightTerminal);

    //logger.info("Bashquotes worker spawned.");

    immutable url = !event.content.length ? "http://bash.org/?random" :
        "http://bash.org/?" ~ event.content;

    immutable target = event.channel.length ?
        event.channel : event.sender.nickname;

    auto qtEngine = `<p class="qt">`.regex;
    auto pEngine = `</p>`.regex;
    auto brEngine = `<br />`.regex;

    try
    {
        import std.exception : assumeUnique;

        immutable content = (cast(char[])getContent(url).data).assumeUnique;
        auto doc = new Document;
        doc.parseGarbage(content);

        auto numBlock = doc.getElementsByClassName("quote");

        if (!numBlock.length)
        {
            state.privmsg(event.channel, event.sender.nickname,
                "No such bash.org quote: %s".format(event.content));
            return;
        }

        immutable num = numBlock[0]
            .getElementsByTagName("p")[0]
            .getElementsByTagName("b")[0]
            .toString[4..$-4];

        auto range = doc
            .getElementsByClassName("qt")[0]
            .toString
            .htmlEntitiesDecode
            .replaceAll(qtEngine, string.init)
            .replaceAll(pEngine, string.init)
            .replaceAll(brEngine, string.init)
            .splitter("\n");

        state.privmsg(event.channel, event.sender.nickname,
            "[bash.org] #%s".format(num));

        foreach (line; range)
        {
            state.privmsg(event.channel, event.sender.nickname, line);
        }
    }
    catch (const Exception e)
    {
        logger.warning("Bashquotes could not fetch ", url, ": ", e.msg);
    }
}


mixin MinimalAuthentication;

public:


// BashQuotesPlugin
/++
 +  The Bash Quotes plugin fetches quotes from `www.bash.org` and displays them
 +  in a channel (or to a private query). It can fetch a random one or one
 +  by quote ID.
 +/
final class BashQuotesPlugin : IRCPlugin
{
    /// All BashQuotes options gathered.
    @Settings BashQuotesSettings bashQuotesSettings;

    mixin IRCPluginImpl;
}
