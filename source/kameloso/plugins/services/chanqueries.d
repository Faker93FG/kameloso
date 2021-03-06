/++
    The Channel Queries service queries channels for information about them (in
    terms of topic and modes) as well as their lists of participants. It does this
    shortly after having joined a channel, as a service to all other plugins,
    so they don't each have to independently do it themselves.

    It is qualified as a service, so while it is not technically mandatory, it
    is highly recommended if you plan on mixing in
    [kameloso.plugins.common.awareness.ChannelAwareness] into your plugins.
 +/
module kameloso.plugins.services.chanqueries;

version(WithPlugins):
version(WithChanQueriesService):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.delayawait;
import kameloso.plugins.common.awareness : ChannelAwareness, UserAwareness;
import dialect.defs;
import std.typecons : No, Yes;


version(OmniscientQueries)
{
    /++
        The [kameloso.plugins.common.core.ChannelPolicy] to mix in awareness with depending
        on whether version `OmniscientQueries` is set or not.
     +/
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    /// Ditto
    enum omniscientChannelPolicy = ChannelPolicy.home;
}


// ChannelState
/++
    Different states which tracked channels can be in.

    This is to keep track of which channels have been queried, which are
    currently queued for being queried, etc. It is checked by bitmask, so a
    channel can have several channel states.
 +/
enum ChannelState : ubyte
{
    unset = 1 << 0,      /// Initial value, invalid state.
    topicKnown = 1 << 1, /// Topic has been sent once, it is known.
    queued = 1 << 2,     /// Channel queued to be queried.
    queried = 1 << 3,    /// Channel has been queried.
}


// startChannelQueries
/++
    Queries channels for information about them and their users.

    Checks an internal list of channels once every [dialect.defs.IRCEvent.Type.PING],
    and if one we inhabit hasn't been queried, queries it.
 +/
@(IRCEvent.Type.PING)
void startChannelQueries(ChanQueriesService service)
{
    import core.thread : Fiber;

    if (service.querying) return;  // Try again next PING

    string[] querylist;

    foreach (immutable channelName, ref state; service.channelStates)
    {
        if (state & (ChannelState.queried | ChannelState.queued))
        {
            // Either already queried or queued to be
            continue;
        }

        state |= ChannelState.queued;
        querylist ~= channelName;
    }

    // Continue anyway if eagerLookups
    if (!querylist.length && !service.state.settings.eagerLookups) return;

    void dg()
    {
        import kameloso.thread : CarryingFiber, ThreadMessage, busMessage;
        import std.concurrency : send;
        import std.datetime.systime : Clock;
        import std.string : representation;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        service.querying = true;  // "Lock"

        scope(exit)
        {
            service.queriedAtLeastOnce = true;
            service.querying = false;  // "Unlock"
        }

        foreach (immutable i, immutable channelName; querylist)
        {
            if (channelName !in service.channelStates) continue;

            if (i > 0)
            {
                // Delay between runs after first since aMode probes don't delay at end
                delay(service, service.secondsBetween, Yes.yield);
            }

            version(WithPrinterPlugin)
            {
                immutable squelchMessage = "squelch " ~ channelName;
            }

            /// Common code to send a query, await the results and unlist the fiber.
            void queryAwaitAndUnlist(Types)(const string command, const Types types)
            {
                import kameloso.messaging : raw;
                import std.conv : text;

                await(service, types);
                scope(exit) unawait(service, types);

                version(WithPrinterPlugin)
                {
                    service.state.mainThread.send(ThreadMessage.BusMessage(),
                        "printer", busMessage(squelchMessage));
                }

                raw(service.state, text(command, ' ', channelName),
                    (service.hideOutgoingQueries ? Yes.quiet : No.quiet), Yes.background);
                Fiber.yield();  // Awaiting specified types

                while (thisFiber.payload.channel != channelName) Fiber.yield();

                delay(service, service.secondsBetween, Yes.yield);
            }

            /// Event types that signal the end of a query response.
            static immutable topicTypes =
            [
                IRCEvent.Type.RPL_TOPIC,
                IRCEvent.Type.RPL_NOTOPIC,
            ];

            queryAwaitAndUnlist("TOPIC", topicTypes);
            queryAwaitAndUnlist("WHO", IRCEvent.Type.RPL_ENDOFWHO);
            queryAwaitAndUnlist("MODE", IRCEvent.Type.RPL_CHANNELMODEIS);

            // MODE generic

            foreach (immutable n, immutable modechar; service.state.server.aModes.representation)
            {
                import std.format : format;

                if (n > 0)
                {
                    // Cannot await by event type; there are too many types.
                    delay(service, service.secondsBetween, Yes.yield);
                }

                version(WithPrinterPlugin)
                {
                    // It's very common to get ERR_CHANOPRIVSNEEDED when querying
                    // channels for specific modes.
                    // [chanoprivsneeded] [#d] sinisalo.freenode.net: "You're not a channel operator" (#482)
                    // Ask the Printer to squelch those messages too.
                    service.state.mainThread.send(ThreadMessage.BusMessage(),
                        "printer", busMessage(squelchMessage));
                }

                import kameloso.messaging : mode;
                mode(service.state, channelName, "+%c".format((cast(char)modechar)), string.init,
                    (service.hideOutgoingQueries ? Yes.quiet : No.quiet), Yes.background);
            }

            if (channelName !in service.channelStates) continue;

            // Overwrite state with [ChannelState.queried];
            // [ChannelState.topicKnown] etc are no longer relevant.
            service.channelStates[channelName] = ChannelState.queried;
        }

        // Stop here if we can't or are not interested in going further
        if (!service.serverSupportsWHOIS || !service.state.settings.eagerLookups) return;

        import kameloso.constants : Timeout;

        immutable now = Clock.currTime.toUnixTime;
        bool[string] uniqueUsers;

        foreach (immutable channelName, const channel; service.state.channels)
        {
            foreach (immutable nickname; channel.users.byKey)
            {
                if (nickname == service.state.client.nickname) continue;

                const user = nickname in service.state.users;

                if (!user || !user.account.length || ((now - user.updated) > Timeout.whoisRetry))
                {
                    // No user, or no account and sufficient amount of time passed since last WHOIS
                    uniqueUsers[nickname] = true;
                }
            }
        }

        if (!uniqueUsers.length) return;  // Early exit

        uniqueUsers = uniqueUsers.rehash();

        /// Event types that signal the end of a WHOIS response.
        static immutable whoisTypes =
        [
            IRCEvent.Type.RPL_ENDOFWHOIS,
            IRCEvent.Type.ERR_UNKNOWNCOMMAND,
        ];

        await(service, whoisTypes);

        scope(exit)
        {
            unawait(service, whoisTypes);

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("unsquelch"));
            }
        }

        long lastQueryResults;

        whoisloop:
        foreach (immutable nickname; uniqueUsers.byKey)
        {
            import kameloso.common : logger;
            import kameloso.messaging : whois;

            if ((nickname !in service.state.users) ||
                (service.state.users[nickname].account.length))
            {
                // User disappeared, or something else WHOISed it already.
                continue;
            }

            // Delay between runs after first since aMode probes don't delay at end
            delay(service, service.secondsBetween, Yes.yield);

            while ((Clock.currTime.toUnixTime - lastQueryResults) < service.secondsBetween-1)
            {
                delay(service, 1, Yes.yield);
            }

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch " ~ nickname));
            }

            whois(service.state, nickname, No.force,
                (service.hideOutgoingQueries ? Yes.quiet : No.quiet), Yes.background);
            Fiber.yield();  // Await whois types registered above

            enum maxConsecutiveUnknownCommands = 3;
            uint consecutiveUnknownCommands;

            while (true)
            {
                with (IRCEvent.Type)
                switch (thisFiber.payload.type)
                {
                case RPL_ENDOFWHOIS:
                    consecutiveUnknownCommands = 0;

                    if (thisFiber.payload.target.nickname == nickname)
                    {
                        // Saw the expected response
                        lastQueryResults = Clock.currTime.toUnixTime;
                        continue whoisloop;
                    }
                    else
                    {
                        // Something else caused a WHOIS; yield until the right one comes along
                        Fiber.yield();
                        continue;
                    }

                case ERR_UNKNOWNCOMMAND:
                    if (!thisFiber.payload.aux.length)
                    {
                        // A different flavour of ERR_UNKNOWNCOMMAND doesn't include the command
                        // We can't say for sure it's erroring on "WHOIS" specifically
                        // If consecutive three errors, assume it's not supported

                        if (++consecutiveUnknownCommands >= maxConsecutiveUnknownCommands)
                        {
                            import kameloso.common : Tint;

                            // Cannot WHOIS on this server (assume)
                            logger.error("Error: This server does not seem " ~
                                "to support user accounts?");
                            logger.errorf("Consider enabling %sCore%s.%1$spreferHostmasks%2$s.",
                                Tint.log, Tint.warning);
                            service.serverSupportsWHOIS = false;
                            return;
                        }
                    }
                    else if (thisFiber.payload.aux == "WHOIS")
                    {
                        // Cannot WHOIS on this server
                        // Connect will display an error, so don't do it here again
                        service.serverSupportsWHOIS = false;
                        return;
                    }
                    else
                    {
                        // Something else issued an unknown command; yield and try again
                        consecutiveUnknownCommands = 0;
                        Fiber.yield();
                        continue;
                    }
                    break;

                default:
                    import lu.conv : Enum;
                    assert(0, "Unexpected event type triggered query Fiber: " ~
                        "`IRCEvent.Type." ~ Enum!(IRCEvent.Type).toString(thisFiber.payload.type) ~ '`');
                }
            }

            assert(0, "Escaped `while (true)` loop in query Fiber delegate");
        }
    }

    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, BufferSize.fiberStack);
    fiber.call();
}


// onSelfjoin
/++
    Adds a channel we join to the internal [ChanQueriesService.channels] list of
    channel states.
 +/
@(IRCEvent.Type.SELFJOIN)
@omniscientChannelPolicy
void onSelfjoin(ChanQueriesService service, const ref IRCEvent event)
{
    service.channelStates[event.channel] = ChannelState.unset;
}


// onSelfpart
/++
    Removes a channel we part from the internal [ChanQueriesService.channels]
    list of channel states.
 +/
@(IRCEvent.Type.SELFPART)
@(IRCEvent.Type.SELFKICK)
@omniscientChannelPolicy
void onSelfpart(ChanQueriesService service, const ref IRCEvent event)
{
    service.channelStates.remove(event.channel);
}


// onTopic
/++
    Registers that we have seen the topic of a channel.

    We do this so we know not to query it later. Mostly cosmetic.
 +/
@(IRCEvent.Type.RPL_TOPIC)
@omniscientChannelPolicy
void onTopic(ChanQueriesService service, const ref IRCEvent event)
{
    service.channelStates[event.channel] |= ChannelState.topicKnown;
}


// onEndOfNames
/++
    After listing names (upon joining a channel), initiate a channel query run
    unless one is already running. Additionally don't do it before it has been
    done at least once, after login.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@omniscientChannelPolicy
void onEndOfNames(ChanQueriesService service)
{
    if (!service.querying && service.queriedAtLeastOnce)
    {
        service.startChannelQueries();
    }
}


// onMyInfo
/++
    After successful connection, start a delayed channel query on all channels.
 +/
@(IRCEvent.Type.RPL_MYINFO)
void onMyInfo(ChanQueriesService service)
{
    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;

    void dg()
    {
        service.startChannelQueries();
    }

    delay(service, &dg, service.secondsBeforeInitialQueries);
}


version(OmniscientQueries)
{
    mixin UserAwareness!(ChannelPolicy.any);
    mixin ChannelAwareness!(ChannelPolicy.any);
}
else
{
    mixin UserAwareness;
    mixin ChannelAwareness;
}


public:


// ChanQueriesService
/++
    The Channel Queries service queries channels for information about them (in
    terms of topic and modes) as well as its list of participants.
 +/
final class ChanQueriesService : IRCPlugin
{
private:
    /++
        Extra seconds delay between channel mode/user queries. Not delaying may
        cause kicks and disconnects if results are returned quickly.
     +/
    enum secondsBetween = 3;

    /// Seconds after welcome event before the first round of channel-querying will start.
    enum secondsBeforeInitialQueries = 60;

    /++
        Short associative array of the channels the bot is in and which state(s)
        they are in.
     +/
    ubyte[string] channelStates;

    /// Whether or not a channel query Fiber is running.
    bool querying;

    /// Whether or not at least one channel query has been made.
    bool queriedAtLeastOnce;

    /// Whether or not the server is known to support WHOIS queries. (Default to true.)
    bool serverSupportsWHOIS = true;

    /// Whether or not to display outgoing queries, as a debugging tool.
    enum hideOutgoingQueries = true;


    // isEnabled
    /++
        Override [kameloso.plugins.common.core.IRCPluginImpl.isEnabled] and inject
        a server check, so this service does nothing on Twitch servers.

        Returns:
            `true` if this service should react to events; `false` if not.
     +/
    version(TwitchSupport)
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return (state.server.daemon != IRCServer.Daemon.twitch);
    }

    mixin IRCPluginImpl;
}
