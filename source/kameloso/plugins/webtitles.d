module kameloso.plugins.webtitles;

version(Webtitles):

pragma(msg, "Version: Webtitles");

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send, Tid;
import std.experimental.logger;
import std.regex : ctRegex;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Thread ID of the working thread that does the lookups
Tid workerThread;

/// Regex pattern to grep a web page title from the HTTP body
enum titlePattern = `<title>([^<]+)</title>`;

/// Regex engine to catch web titles
static titleRegex = ctRegex!(titlePattern, "i");

/// Regex pattern to match a URI, to see if one was pasted
enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;

/// Regex engine to catch URIs
static urlRegex = ctRegex!stephenhay;

/// Regex engine to match only the domain in a URI
enum domainPattern = `(?:https?://)(?:www\.)?([^/ ]+)/?.*`;

/// Regex engine to catch domains
static domainRegex = ctRegex!domainPattern;

/// Regex pattern to match YouTube urls
enum youtubePattern = `https?://(www.)?youtube.com/watch`;

/// Regex engine to match YouTube urls for replacement
static youtubeRegex = ctRegex!youtubePattern;

/// Thread-local logger
Logger tlsLogger;


// TitleLookup
/++
 +  A record of a URI lookup.
 +
 +  This is both used to aggregate information about the lookup, as well as to
 +  add hysteresis to lookups, so we don't look the same one up over and over
 +  if they were pasted over and over.
 +/
struct TitleLookup
{
    import std.datetime : SysTime;

    string title;
    string domain;
    SysTime when;
}


// onMessage
/++
 +  Parses a message to see if the message contains an URI.
 +
 +  It uses a simple regex and exhaustively tries to match every URI it detects.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("message")
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.friend)
@(Chainable.yes)
void onMessage(const IRCEvent event)
{
    import std.regex : matchAll;

    auto matches = event.content.matchAll(urlRegex);

    foreach (urlHit; matches)
    {
        if (!urlHit.length) continue;

        immutable url = urlHit[0];
        immutable target = (event.channel.length) ? event.channel : event.sender;

        logger.log(url);
        workerThread.send(url, target);
    }
}


// streamUntil
/++
 +  Streams text from a supplied stream until the supplied regex engine finds a
 +  match. This is used to stream a web page while applying a regex engine that
 +  looks for title tags.
 +
 +  Since streamed content comes in unpredictable chunks, a Sink is used and
 +  gradually filled so that the entirety can be scanned if the title tag was
 +  split between two chunks.
 +
 +  Params:
 +      Stream_ = template stream type.
 +      Regex_ = template regex type.
 +      Sink = template sink type.
 +
 +      stream = a stream of a web page.
 +      engine = a regex matcher engine looking for title tags
 +      sink = a sink to fill with the streamed content, for later whole-body lookup
 +
 +  Returns:
 +      the first hit generated by the regex engine.
 +/
string streamUntil(Stream_, Regex_, Sink)
    (ref Stream_ stream, Regex_ engine, ref Sink sink)
{
    import std.regex : matchFirst;

    foreach (const data; stream)
    {
        /*writefln("Received %d bytes, total received %d from document legth %d",
            stream.front.length, rq.contentReceived, rq.contentLength);*/

        /++
         +  matchFirst won't work directly on data, it's constrained to work
         +  with isSomeString, and types and data are const(ubyte[]).
         +  We can get away without doing idup and just casting to string here
         +  though, since sink.put below will copy.
         +/
        const hits = (cast(string)data).matchFirst(engine);
        sink.put(data);

        if (hits.length)
        {
            /*writefln("Found title mid-stream after %s bytes", rq.contentReceived);
            writefln("Appender size is %d", sink.data.length);
            writefln("capacity is %d", sink.capacity);*/
            return hits[1];
        }
    }

    // No hits, but sink might be filled
    return string.init;
}


// lookupTitle
/++
 +  Look up a web page and try to find its title (by its <title> tag, if any).
 +
 +  Params:
 +      url = the web page address
 +/
TitleLookup lookupTitle(const string url)
{
    import kameloso.stringutils : beginsWith;
    import requests : Request;
    import std.array : Appender;
    import std.datetime : Clock;

    TitleLookup lookup;
    Appender!string pageContent;
    pageContent.reserve(BufferSize.titleLookup);

    tlsLogger.log("URL: ", url);

    Request rq;
    rq.useStreaming = true;
    rq.keepAlive = false;
    rq.bufferSize = BufferSize.titleLookup;

    try
    {
        auto rs = rq.get(url);
        if (rs.code >= 400) return lookup;

        auto stream = rs.receiveAsRange();

        lookup.title = getTitleFromStream(stream);

        if (!lookup.title.length)
        {
            tlsLogger.info("zero-length title");
            return lookup;
        }
        else if (lookup.title == "YouTube" && (url.indexOf("youtube.com/watch?") != -1))
        {
            import std.regex : replaceFirst;

            tlsLogger.info("Bland YouTube title...");

            // this better not lead to infinite recursion...
            immutable onRepeatUrl = url.replaceFirst(youtubeRegex,
                "http://www.youtubeonrepeat.com/watch/");

            tlsLogger.info(onRepeatUrl);

            TitleLookup onRepeatLookup = lookupTitle(onRepeatUrl);

            tlsLogger.info(onRepeatLookup.title);

            if (onRepeatLookup.title.indexOf(" - Youtube On Repeat") == -1)
            {
                // No luck, return old lookup
                return lookup;
            }

            // "Blahblah - Youtube On Repeat" --> "Blahblah - Youtube"
            onRepeatLookup.title = onRepeatLookup.title[0..$-10];
            onRepeatLookup.domain = "youtube.com";
            return onRepeatLookup;
        }

        lookup.domain = getDomainFromURL(url);
        lookup.when = Clock.currTime;
    }
    catch (Exception e)
    {
        tlsLogger.error(e.msg);

        if (url.beginsWith("https://"))
        {
            // Try once more with HTTP instead of HTTPS, fixes some sites
            return lookupTitle("http" ~ url[5..$]);
        }
    }

    return lookup;
}


// getDomainFromURL
/++
 +  Fetches the slice of the domain name from a URL.
 +
 +  Params:
 +      url = an URL string.
 +
 +  Returns:
 +      the domain part of the URL string, or an empty string if no matches.
 +/
string getDomainFromURL(const string url) @safe
{
    import std.regex : matchFirst;

    auto domainHits = url.matchFirst(domainRegex);
    return domainHits.length ? domainHits[1] : string.init;
}

@safe unittest
{
    immutable d1 = getDomainFromURL("http://www.youtube.com/watch?asoidjsd&asd=kokofruit");
    assert((d1 == "youtube.com"), d1);

    immutable d2 = getDomainFromURL("https://www.com");
    assert((d2 == "com"), d2);

    immutable d3 = getDomainFromURL("ftp://ftp.sunet.se");
    assert(!d3.length, d3);

    immutable d4 = getDomainFromURL("http://");
    assert(!d4.length, d4);

    immutable d5 = getDomainFromURL("invalid line");
    assert(!d5.length, d5);

    immutable d6 = getDomainFromURL("");
    assert(!d6.length, d6);
}


// getTitleFromStream
/++
 +  Streams a web page off the network and looks for the content of the page's
 +  <tilte> tag.
 +
 +  Params:
 +      stream = the stream from which to stream the web page.
 +
 +  Returns:
 +      a title string if a match was found, else an empty string.
 +/
string getTitleFromStream(Stream_)(ref Stream_ stream)
{
    import std.array : Appender, arrayReplace = replace;
    import std.regex : matchFirst;
    import std.string : removechars, strip;

    Appender!string pageContent;
    pageContent.reserve(BufferSize.titleLookup);

    string title = stream.streamUntil(titleRegex, pageContent);

    if (!pageContent.data.length)
    {
        tlsLogger.warning("Could not get content. Bad URL?");
        return string.init;
    }

    if (!title.length)
    {
        auto titleHits = pageContent.data.matchFirst(titleRegex);

        if (titleHits.length)
        {
            tlsLogger.log("Found title in complete data (it was split)");
            title = titleHits[1];
        }
        else
        {
            tlsLogger.warning("No title...");
            return string.init;
        }
    }

    // TODO: Add DOM translation, &nbsp; etc.

    return title
        .removechars("\r")
        .arrayReplace("\n", " ")
        .strip;
}


// titleworker
/++
 +  Worker thread of the Webtitles plugin.
 +
 +  It sits and waits for concurrency messages of URLs to look up.
 +
 +  Params:
 +      sMainThread = a shared copy of the mainThread Tid, to which every
 +                    outgoing messages will be sent.
 +/
void titleworker(shared Tid sMainThread)
{
    import core.time : seconds;
    import std.concurrency : OwnerTerminated, receive;
    import std.datetime : Clock;
    import std.variant : Variant;

    Tid mainThread = cast(Tid)sMainThread;
    tlsLogger = new KamelosoLogger(LogLevel.all);

    /// Cache buffer of recently looked-up URIs
    TitleLookup[string] cache;
    bool halt;

    while (!halt)
    {
        receive(
            &onEvent,
            (string url, string target)
            {
                import std.format : format;

                TitleLookup lookup;
                const inCache = url in cache;

                if (inCache && ((Clock.currTime - inCache.when) < Timeout.titleCache.seconds))
                {
                    lookup = *inCache;
                }
                else
                {
                    try lookup = lookupTitle(url);
                    catch (Exception e)
                    {
                        logger.error(e.msg);
                    }
                }

                if (lookup == TitleLookup.init) return;

                cache[url] = lookup;

                if (lookup.domain.length)
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :[%s] %s".format(target, lookup.domain, lookup.title));
                }
                else
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG %s :%s".format(target, lookup.title));
                }
            },
            (ThreadMessage.Teardown)
            {
                halt = true;
            },
            (OwnerTerminated o)
            {
                halt = true;
            },
            (Variant v)
            {
                logger.error("titleworker received Variant: ", v);
            }
        );
    }
}


// initialise
/++
 +  Initialises the Webtitles plugin. Spawns the titleworker thread.
 +/
void initialise()
{
    import std.concurrency : spawn;

    const stateCopy = state;
    workerThread = spawn(&titleworker, cast(shared)(stateCopy.mainThread));
}


// teardown
/++
 +  Deinitialises the Webtitles plugin. Shuts down the titleworker thread.
 +/
void teardown()
{
    workerThread.send(ThreadMessage.Teardown());
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// Webtitles
/++
 +  The Webtitles plugin catches HTTP URI links in an IRC channel, connects to
 +  its server and and streams the web page itself, looking for the web page's
 +  title (in its <title> tags). This is then reported to the originating channel.
 +/
final class Webtitles : IRCPlugin
{
    mixin IRCPluginBasics;
}
