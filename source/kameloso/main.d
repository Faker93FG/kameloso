/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.main;

import kameloso.common;
import kameloso.irc;
import kameloso.ircdefs;

import core.thread : Fiber;
import std.typecons : Flag, No, Yes;

version(Windows)
shared static this()
{
    import core.sys.windows.windows : SetConsoleCP, SetConsoleOutputCP, CP_UTF8;

    // If we don't set the right codepage, the normal Windows cmd terminal won't
    // display international characters like åäö.
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
}

private:

/++
 +  Abort flag.
 +
 +  This is set when the program is interrupted (such as via Ctrl+C). Other
 +  parts of the program will be monitoring it, to take the cue and abort when
 +  it is set.
 +/
__gshared bool abort;


// signalHandler
/++
 +  Called when a signal is raised, usually `SIGINT`.
 +
 +  Sets the `abort` variable to `true` so other parts of the program knows to
 +  gracefully shut down.
 +
 +  Params:
 +      sig = Integer of the signal raised.
 +/
extern (C)
void signalHandler(int sig) nothrow @nogc @system
{
    import core.stdc.stdio : printf;

    printf("...caught signal %d!\n", sig);
    abort = true;

    // Restore signal handlers to the default
    resetSignals();
}


// throttleline
/++
 +  Send a string to the server in a throttled fashion, based on a simple
 +  `y = k*x + m` line.
 +
 +  This is so we don't get kicked by the server for spamming, if a lot of lines
 +  are to be sent at once.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      strings = Variadic list of strings to send.
 +/
void throttleline(Strings...)(ref Client client, const Strings strings)
{
    import core.thread : Thread;
    import core.time : seconds, msecs;
    import std.datetime.systime : Clock, SysTime;

    if (*(client.abort)) return;

    with (client.throttling)
    {
        immutable now = Clock.currTime;
        if (t0 == SysTime.init) t0 = now;

        double x = (now - t0).total!"msecs"/1000.0;
        auto y = k * x + m;

        if (y < 0)
        {
            t0 = now;
            m = 0;
            x = 0;
            y = 0;
        }

        while (y >= burst)
        {
            x = (Clock.currTime - t0).total!"msecs"/1000.0;
            y = k*x + m;
            interruptibleSleep(100.msecs, *(client.abort));
            if (*(client.abort)) return;
        }

        client.conn.sendline(strings);

        m = y + increment;
        t0 = Clock.currTime;
    }
}


// Next
/++
 +  Enum of flags carrying the meaning of "what to do next".
 +/
enum Next
{
    stayConnected,  /// Keep the connection active, treat disconnects as errors.
    reconnect,  /// Preemptively disconnect and reconnect to the server.
    quit,  /// Exit the program.
}


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was
 +  received.
 +
 +  The return value tells the caller whether the received action means the bot
 +  should exit or not.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +
 +  Returns:
 +      `Next.{stayConnected,reconnect,quit}` depending on what course of action
 +      to take next.
 +/
Next checkMessages(ref Client client)
{
    import kameloso.plugins.common : IRCPlugin;
    import kameloso.common : initLogger, settings;
    import core.time : seconds;
    import std.concurrency : receiveTimeout;
    import std.variant : Variant;

    scope (failure) client.teardownPlugins();

    Next next;

    /// Send a message to the server bypassing throttling.
    void immediateline(ThreadMessage.Immediateline, string line)
    {
        // FIXME: quiet?
        logger.trace("--> ", line);
        client.conn.sendline(line);
    }

    /// Echo a line to the terminal and send it to the server.
    void sendline(ThreadMessage.Sendline, string line)
    {
        logger.trace("--> ", line);
        client.throttleline(line);
    }

    /// Send a line to the server without echoing it.
    void quietline(ThreadMessage.Quietline, string line)
    {
        client.throttleline(line);
    }

    /// Respond to `PING` with `PONG` to the supplied text as target.
    void pong(ThreadMessage.Pong, string target)
    {
        client.throttleline("PONG :", target);
    }

    /// Ask plugins to reload.
    void reload(ThreadMessage.Reload)
    {
        foreach (plugin; client.plugins)
        {
            plugin.reload();
        }
    }

    /// Quit the server with the supplied reason, or the default.
    void quitServer(ThreadMessage.Quit, string givenReason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision up the stack.
        immutable reason = givenReason.length ? givenReason : client.parser.bot.quitReason;
        logger.tracef(`--> QUIT :"%s"`, reason);
        client.conn.sendline("QUIT :\"", reason, "\"");
        next = Next.quit;
    }

    /// Disconnects from and reconnects to the server.
    void reconnect(ThreadMessage.Reconnect)
    {
        client.conn.sendline("QUIT :Reconnecting.");
        next = Next.reconnect;
    }

    /// Saves current configuration to disk.
    void save(ThreadMessage.Save)
    {
        client.writeConfigurationFile(settings.configFile);
    }

    /++
     +  Passes a reference to the main array of
     +  `kameloso.plugins.common.IRCPlugin`s array (housing all plugins) to the
     +  supplied `kameloso.plugins.common.IRCPlugin`.
     +/
    void peekPlugins(ThreadMessage.PeekPlugins, shared IRCPlugin sPlugin, IRCEvent event)
    {
        auto plugin = cast(IRCPlugin)sPlugin;
        plugin.peekPlugins(client.plugins, event);
    }

    /// Reloads all plugins.
    void reloadPlugins(ThreadMessage.Reload)
    {
        foreach (plugin; client.plugins)
        {
            plugin.reload();
        }
    }

    /// Reverse-formats an event and sends it to the server.
    void eventToServer(IRCEvent event)
    {
        import std.format : format;

        string line;

        with (IRCEvent.Type)
        with (event)
        with (client)
        switch (event.type)
        {
        case CHAN:
            line = "PRIVMSG %s :%s".format(channel, content);
            break;

        case QUERY:
            line = "PRIVMSG %s :%s".format(target.nickname, content);
            break;

        case EMOTE:
            alias I = IRCControlCharacter;
            immutable emoteTarget = target.nickname.length ? target.nickname : channel;
            line = "PRIVMSG %s :%s%s%s".format(emoteTarget, cast(int)I.ctcp, content, cast(int)I.ctcp);
            break;

        case MODE:
            line = "MODE %s %s :%s".format(channel, aux, content);
            break;

        case TOPIC:
            line = "TOPIC %s :%s".format(channel, content);
            break;

        case INVITE:
            line = "INVITE %s :%s".format(channel, target.nickname);
            break;

        case JOIN:
            line = "JOIN %s".format(channel);
            break;

        case KICK:
            immutable reason = content.length ? " :" ~ content : string.init;
            line = "KICK %s%s".format(channel, reason);
            break;

        case PART:
            immutable reason = content.length ? " :" ~ content : string.init;
            line = "PART %s%s".format(channel, reason);
            break;

        case QUIT:
            return quitServer(ThreadMessage.Quit(), content);

        case NICK:
            line = "NICK %s".format(target.nickname);
            break;

        case PRIVMSG:
            if (channel.length) goto case CHAN;
            else goto case QUERY;

        case UNSET:
            line = content;
            break;

        default:
            logger.warning("No outgoing event case for type ", type);
            line = content;
            break;
        }

        if (event.target.class_ == IRCUser.Class.special)
        {
            quietline(ThreadMessage.Quietline(), line);
        }
        else
        {
            sendline(ThreadMessage.Sendline(), line);
        }
    }

    /// `writeln`s the passed message.
    void proxyWriteln(ThreadMessage.TerminalOutput.Writeln, string message)
    {
        import std.stdio : writeln;
        writeln(message);
    }

    /// `trace`s the passed message.
    void proxyTrace(ThreadMessage.TerminalOutput.Trace, string message)
    {
        logger.trace(message);
    }

    /// `log`s the passed message.
    void proxyLog(ThreadMessage.TerminalOutput.Log, string message)
    {
        logger.log(message);
    }

    /// `info`s the passed message.
    void proxyInfo(ThreadMessage.TerminalOutput.Info, string message)
    {
        logger.info(message);
    }

    /// `warning`s the passed message.
    void proxyWarning(ThreadMessage.TerminalOutput.Warning, string message)
    {
        logger.warning(message);
    }

    /// `log`s the passed message.
    void proxyError(ThreadMessage.TerminalOutput.Error, string message)
    {
        logger.error(message);
    }

    /// Did the concurrency receive catch something?
    bool receivedSomething;

    /// Number of received concurrency messages this run.
    uint receivedInARow;

    /// After how many consecutive concurrency messages we should break.
    enum maxReceiveBeforeBreak = 5;

    do
    {
        static immutable instant = 0.seconds;

        receivedSomething = receiveTimeout(instant,
            &sendline,
            &quietline,
            &immediateline,
            &pong,
            &eventToServer,
            &proxyWriteln,
            &proxyTrace,
            &proxyLog,
            &proxyInfo,
            &proxyWarning,
            &proxyError,
            &quitServer,
            &save,
            &reloadPlugins,
            &peekPlugins,
            &reconnect,
            (Variant v)
            {
                // Caught an unhandled message
                logger.warning("Main thread received unknown Variant: ", v);
            }
        );

        if (receivedSomething) ++receivedInARow;
    }
    while (receivedSomething && (next == Next.stayConnected) &&
        (receivedInARow < maxReceiveBeforeBreak));

    return next;
}


// mainLoop
/++
 +  This loops creates a `std.concurrency.Generator` `core.thread.Fiber` to loop
 +  over the over `std.socket.Socket`, reading and yielding lines as it goes.
 +
 +  Full lines are yielded in the `std.concurrency.Generator` to be caught here,
 +  consequently parsed into `kameloso.ircdefs.IRCEvent`s, and then dispatched
 +  to all the plugins.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +
 +  Returns:
 +      `Yes.quit` if circumstances mean the bot should exit, otherwise
 +      `No.quit.`
 +/
Next mainLoop(ref Client client)
{
    import kameloso.common : printObjects;
    import kameloso.connection : listenFiber;
    import core.exception : UnicodeException;
    import core.thread : Fiber;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock;
    import std.utf : UTFException;

    /// Enum denoting what we should do next loop.
    Next next;

    // Instantiate a Generator to read from the socket and yield lines
    auto generator = new Generator!string(() => listenFiber(client.conn, *(client.abort)));

    /// How often to check for timed `Fiber`s, multiples of `Timeout.receive`.
    enum checkTimedFibersEveryN = 3;

    /++
     +  How many more receive passes until it should next check for timed
     +  `Fiber`s.
     +/
    int timedFiberCheckCounter = checkTimedFibersEveryN;

    while (next == Next.stayConnected)
    {
        if (generator.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected; reconnect
            generator.reset();
            return Next.stayConnected;
        }

        immutable nowInUnix = Clock.currTime.toUnixTime;

        foreach (ref plugin; client.plugins)
        {
            plugin.periodically(nowInUnix);
        }

        // Call the generator, query it for event lines
        generator.call();

        with (client)
        with (client.parser)
        foreach (immutable line; generator)
        {
            // Go through Fibers awaiting a point in time, regardless of whether
            // something was read or not.

            /++
             +  At a cadence of once every `checkFiberFibersEveryN`, walk the
             +  array of plugins and see if they have timed `core.thread.Fiber`s
             +  to call.
             +/
            if (--timedFiberCheckCounter <= 0)
            {
                // Reset counter
                timedFiberCheckCounter = checkTimedFibersEveryN;

                foreach (plugin; plugins)
                {
                    if (!plugin.state.timedFibers.length) continue;

                    size_t[] toRemove;

                    foreach (immutable i, ref fiber; plugin.state.timedFibers)
                    {
                        if (fiber.id > nowInUnix)
                        {
                            import kameloso.constants : Timeout;
                            import std.algorithm.comparison : min;

                            // This Fiber shouldn't yet be triggered.
                            // Lower timedFiberCheckCounter to fire earlier, in
                            // case the time-to-fire is lower than the current
                            // counter value. This gives it more precision.

                            immutable nextTime = cast(int)(fiber.id - nowInUnix) / Timeout.receive;
                            timedFiberCheckCounter = min(timedFiberCheckCounter, nextTime);
                            continue;
                        }

                        try
                        {
                            if (fiber.state == Fiber.State.HOLD)
                            {
                                fiber.call();
                            }

                            // Always removed a timed Fiber after processing
                            toRemove ~= i;
                        }
                        catch (const IRCParseException e)
                        {
                            logger.warningf("IRC Parse Exception %s.timedFibers[%d]: %s", plugin.name, i, e.msg);
                            printObject(e.event);
                            toRemove ~= i;
                        }
                        catch (const Exception e)
                        {
                            logger.warningf("Exception %s.timedFibers[%d]: %s", plugin.name, i, e.msg);
                            toRemove ~= i;
                        }
                    }

                    // Clean up processed Fibers
                    foreach_reverse (immutable i; toRemove)
                    {
                        import std.algorithm.mutation : remove;
                        plugin.state.timedFibers = plugin.state.timedFibers.remove(i);
                    }
                }
            }

            // Empty line yielded means nothing received; break and try again
            if (!line.length) break;

            IRCEvent mutEvent;

            scope(failure)
            {
                logger.error("scopeguard tripped.");
                printObject(mutEvent);
            }

            try
            {
                import std.encoding : sanitize;
                // Sanitise and try again once on UTF/Unicode exceptions

                try
                {
                    mutEvent = parser.toIRCEvent(line);
                }
                catch (const UTFException e)
                {
                    mutEvent = parser.toIRCEvent(sanitize(line));
                }
                catch (const UnicodeException e)
                {
                    mutEvent = parser.toIRCEvent(sanitize(line));
                }

                if (bot.updated)
                {
                    // Parsing changed the bot; propagate
                    bot.updated = false;
                    propagateBot(bot);
                }

                foreach (plugin; plugins)
                {
                    plugin.postprocess(mutEvent);

                    if (plugin.state.bot.updated)
                    {
                        // Postprocessing changed the bot; propagate
                        bot = plugin.state.bot;
                        bot.updated = false;
                        propagateBot(bot);
                    }
                }

                immutable IRCEvent event = mutEvent;

                // Let each plugin process the event
                foreach (plugin; plugins)
                {
                    try
                    {
                        plugin.onEvent(event);

                        // Go through Fibers awaiting IRCEvent.Types
                        if (auto fibers = event.type in plugin.state.awaitingFibers)
                        {
                            size_t[] toRemove;

                            foreach (immutable i, ref fiber; *fibers)
                            {
                                try
                                {
                                    if (fiber.state == Fiber.State.HOLD)
                                    {
                                        fiber.call();
                                    }

                                    if (fiber.state == Fiber.State.TERM)
                                    {
                                        toRemove ~= i;
                                    }
                                }
                                catch (const IRCParseException e)
                                {
                                    logger.warningf("IRC Parse Exception %s.awaitingFibers[%d]: %s",
                                        plugin.name, i, e.msg);
                                    printObject(e.event);
                                    toRemove ~= i;
                                }
                                catch (const Exception e)
                                {
                                    logger.warningf("Exception %s.awaitingFibers[%d]: %s",
                                        plugin.name, i, e.msg);
                                    printObject(event);
                                    toRemove ~= i;
                                }
                            }

                            // Clean up processed Fibers
                            foreach_reverse (immutable i; toRemove)
                            {
                                import std.algorithm.mutation : remove;
                                *fibers = (*fibers).remove(i);
                            }

                            // If no more Fibers left, remove the Type entry in the AA
                            if (!(*fibers).length)
                            {
                                plugin.state.awaitingFibers.remove(event.type);
                            }
                        }

                        // Fetch any queued `WHOIS` requests and handle
                        client.handleWHOISQueue(plugin.state.whoisQueue);

                        if (plugin.state.bot.updated)
                        {
                            /*  Plugin `onEvent` or `WHOIS` reaction updated the
                                bot. There's no need to check for both
                                separately since this is just a single plugin
                                processing; it keeps its update internally
                                between both passes.
                            */
                            bot = plugin.state.bot;
                            bot.updated = false;
                            parser.bot = bot;
                            propagateBot(bot);
                        }
                    }
                    catch (const UTFException e)
                    {
                        logger.warningf("UTFException %s.onEvent: %s", plugin.name, e.msg);
                    }
                    catch (const Exception e)
                    {
                        logger.warningf("Exception %s.onEvent: %s", plugin.name, e.msg);
                        printObject(event);
                    }
                }
            }
            catch (const IRCParseException e)
            {
                logger.warningf("IRC Parse Exception at %s:%d: %s", e.file, e.line, e.msg);
                printObject(e.event);
            }
            catch (const UTFException e)
            {
                logger.warning("UTFException: ", e.msg);
            }
            catch (const UnicodeException e)
            {
                logger.warning("UnicodeException: ", e.msg);
            }
            catch (const Exception e)
            {
                logger.warningf("Unhandled exception at %s:%d: %s", e.file, e.line, e.msg);

                if (mutEvent != IRCEvent.init)
                {
                    printObject(mutEvent);
                }
                else
                {
                    logger.warningf(`Offending line: "%s"`, line);
                }
            }
        }

        // Check concurrency messages to see if we should exit, else repeat
        next = checkMessages(client);
    }

    return next;
}


// handleFibers
/++
 +  Takes an array of `core.thread.Fiber`s and processes them.
 +
 +  If passed `Yes.exhaustive` they are removed from the arrays after they are
 +  called, so they won't be triggered again next pass. Otherwise only the
 +  finished ones are removed.
 +
 +  Params:
 +      exhaustive = Whether to always remove `core.thread.Fiber`s after
 +          processing.
 +      fibers = Reference to an array of `core.thread.Fiber`s to process.
 +/
void handleFibers(Flag!"exhaustive" exhaustive = No.exhaustive)(ref Fiber[] fibers)
{
    size_t[] emptyIndices;

    foreach (immutable i, ref fiber; fibers)
    {
        if (fiber.state == Fiber.State.TERM)
        {
            emptyIndices ~= i;
        }
        else if (fiber.state == Fiber.State.HOLD)
        {
            fiber.call();
        }
        else
        {
            assert(0, "Invalid Fiber state");
        }
    }

    static if (exhaustive)
    {
        // Remove all called Fibers
        fibers.length = 0;
    }
    else
    {
        // Remove completed Fibers
        foreach_reverse (i; emptyIndices)
        {
            import std.algorithm.mutation : remove;
            fibers = fibers.remove(i);
        }
    }
}


// handleWHOISQueue
/++
 +  Takes a queue of `WHOISRequest` objects and emits `WHOIS` requests for each
 +  one.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      reqs = Reference to an associative array of `WHOISRequest`s.
 +/
void handleWHOISQueue(W)(ref Client client, ref W[string] reqs)
{
    // Walk through requests and call `WHOIS` on those that haven't been
    // `WHOIS`ed in the last `Timeout.whois` seconds

    foreach (key, value; reqs)
    {
        if (!key.length) continue;

        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;
        import core.time : seconds;

        const then = key in client.whoisCalls;
        immutable now = Clock.currTime.toUnixTime;

        if (!then || ((now - *then) > Timeout.whois))
        {
            logger.trace("--> WHOIS ", key);
            client.throttleline("WHOIS ", key);
            client.whoisCalls[key] = Clock.currTime.toUnixTime;
        }
        else
        {
            //logger.log(key, " too soon...");
        }
    }
}


// setupSignals
/++
 +  Registers `SIGINT` (and optionally `SIGHUP` on Posix systems) to redirect to
 +  our own `signalHandler`, so we can catch Ctrl+C and gracefully shut down.
 +/
void setupSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIGINT;

    signal(SIGINT, &signalHandler);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, &signalHandler);
    }
}


// resetSignals
/++
 +  Resets `SIGINT` (and `SIGHUP` handlers) to the system default.
 +/
void resetSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIG_DFL, SIGINT;

    signal(SIGINT, SIG_DFL);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, SIG_DFL);
    }
}


public:

version(unittest)
/++
 +  Unittesting main; does nothing.
 +/
void main()
{
    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't reinit here.
    logger.info("All tests passed successfully!");
    // No need to Cygwin-flush; the logger did that already
}
else
/++
 +  Entry point of the program.
 +/
int main(string[] args)
{
    import kameloso.common : printObjects;
    import kameloso.config : FileIsNotAFileException;
    import std.conv : ConvException;
    import std.getopt : GetOptException;
    import std.stdio : writeln;

    // Initialise the main Client. Set its abort pointer to the global abort.
    Client client;
    client.abort = &abort;

    // Prepare an array for `handleGetopt` to fill by ref with custom settings
    // set on the command-line using `--set plugin.setting=value`
    string[] customSettings;

    // Initialise the logger immediately so it's always available, reinit later
    // when we know the settings for monochrome
    initLogger(settings.monochrome, settings.brightTerminal);

    scope(failure)
    {
        import kameloso.bash : TerminalToken;
        logger.error("We just crashed!", cast(char)TerminalToken.bell);
        client.teardownPlugins();
        resetSignals();
    }

    setupSignals();

    try
    {
        import kameloso.getopt : handleGetopt;
        // Act on arguments getopt, quit if whatever was passed demands it
        if (client.handleGetopt(args, customSettings) == Yes.quit) return 0;
    }
    catch (const GetOptException e)
    {
        logger.error("Error parsing command-line arguments: ", e.msg);
        return 1;
    }
    catch (const ConvException e)
    {
        logger.error("Error converting command-line arguments: ", e.msg);
        return 1;
    }
    catch (const FileIsNotAFileException e)
    {
        string infotint, errortint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.bash : colour;
                import kameloso.logger : KamelosoLogger;
                import std.experimental.logger : LogLevel;

                infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                errortint = KamelosoLogger.tint(LogLevel.error, settings.brightTerminal).colour;
            }
        }

        logger.errorf("Specified configuration file %s%s%s is not a file!",
            infotint, e.filename, errortint);

        return 1;
    }
    catch (const Exception e)
    {
        logger.error("Unhandled exception handling command-line arguments: ", e.msg);
        return 1;
    }

    with (client)
    with (client.parser)
    {
        import kameloso.bash : BashForeground;

        BashForeground tint = BashForeground.default_;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                tint = settings.brightTerminal ? BashForeground.black : BashForeground.white;
            }
        }

        printVersionInfo(tint);
        writeln();

        // Print the current settings to show what's going on.
        printObjects(bot, bot.server);

        if (!bot.homes.length && !bot.admins.length)
        {
            complainAboutMissingConfiguration(bot, args);
            return 1;
        }

        // Initialise plugins outside the loop once, for the error messages
        const invalidEntries = initPlugins(customSettings);
        complainAboutInvalidConfigurationEntries(invalidEntries);

        // Save the original nickname *once*, outside the connection loop.
        // It will change later and knowing this is useful when authenticating
        bot.origNickname = bot.nickname;

        // Save a backup snapshot of the bot, for restoring upon reconnections
        IRCBot backupBot = bot;

        /// Enum denoting what we should do next loop.
        Next next;

        /++
         +  Bool whether this is the first connection attempt or if we have
         +  connected at least once already.
         +/
        bool firstConnect = true;

        do
        {
            import kameloso.ircdefs : IRCBot;  // fix visibility warning
            import kameloso.irc : IRCParser;

            if (!firstConnect)
            {
                import kameloso.constants : Timeout;
                import core.time : seconds;

                // Carry some values but otherwise restore the pristine bot backup
                backupBot.nickname = bot.nickname;
                backupBot.homes = bot.homes;
                backupBot.channels = bot.channels;
                bot = backupBot;

                logger.log("Please wait a few seconds...");
                interruptibleSleep(Timeout.retry.seconds, *abort);

                // Reinit plugins here so it isn't done on the first connect attempt
                initPlugins(customSettings);
            }

            conn.reset();
            immutable resolved = conn.resolve(bot.server.address, bot.server.port, settings.ipv6, *abort);

            if (!resolved)
            {
                teardownPlugins();
                logger.info("Exiting...");
                return 1;
            }

            string infotint, logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.bash : colour;
                    import kameloso.logger : KamelosoLogger;
                    import std.experimental.logger : LogLevel;

                    infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                    logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
                }
            }

            logger.infof("%s%s resolved into %s%s%s IPs.",
                bot.server.address, logtint.colour, infotint.colour,
                conn.ips.length, logtint.colour);

            conn.connect(*abort);

            if (!conn.connected)
            {
                // Save if configuration says we should
                if (settings.saveOnExit)
                {
                    client.writeConfigurationFile(settings.configFile);
                }

                teardownPlugins();
                logger.info("Exiting...");
                return 1;
            }

            parser = IRCParser(bot);
            startPlugins();

            // Start the main loop
            next = client.mainLoop();
            firstConnect = false;

            // Save if we're exiting and configuration says we should.
            if (((next == Next.quit) || *abort) && settings.saveOnExit)
            {
                client.writeConfigurationFile(settings.configFile);
            }

            // Always teardown after connection ends
            teardownPlugins();
        }
        while (!(*abort) && ((next == Next.reconnect) ||
            ((next == Next.stayConnected) && settings.reconnectOnFailure)));

        if (*abort)
        {
            // Ctrl+C
            logger.error("Aborting...");
            return 1;
        }
        else
        {
            logger.info("Exiting...");
            return 0;
        }
    }
}
