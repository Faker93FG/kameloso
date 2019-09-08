/++
 +  The Admin plugin features bot commands which help with debugging the current
 +  state of the running bot, like printing the current list of users, the
 +  current channels, the raw incoming strings from the server, and some other
 +  things along the same line.
 +
 +  It also offers some less debug-y, more administrative functions, like adding
 +  and removing homes on-the-fly, whitelisting or de-whitelisting account
 +  names, joining or leaving channels, and such.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#admin
 +/
module kameloso.plugins.admin;

version(WithPlugins):
version(WithAdminPlugin):

//version = OmniscientAdmin;

private:

import kameloso.plugins.common;
import kameloso.common : logger, settings;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;

import std.concurrency : send;
import std.typecons : Flag, No, Yes;


// AdminSettings
/++
 +  All Admin plugin settings, gathered in a struct.
 +/
struct AdminSettings
{
    import lu.core.uda : Unconfigurable;

    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    @Unconfigurable
    {
        /++
         +  Toggles whether `onAnyEvent` prints the raw strings of all incoming
         +  events or not.
         +/
        bool printRaw;

        /++
         +  Toggles whether `onAnyEvent` prints the raw bytes of the *contents*
         +  of events or not.
         +/
        bool printBytes;

        /++
         +  Toggles whether `onAnyEvent` prints assert statements for incoming
         +  events or not.
         +/
        bool printAsserts;
    }
}


// onAnyEvent
/++
 +  Prints all incoming events to the local terminal, in forms depending on
 +  which flags have been set with bot commands.
 +
 +  If `AdminPlugin.printRaw` is set by way of invoking `onCommandPrintRaw`,
 +  prints all incoming server strings.
 +
 +  If `AdminPlugin.printBytes` is set by way of invoking `onCommandPrintBytes`,
 +  prints all incoming server strings byte per byte.
 +
 +  If `AdminPlugin.printAsserts` is set by way of invoking `onCommandPrintRaw`,
 +  prints all incoming events as assert statements, for use in generating source
 +  code `unittest` blocks.
 +/
debug
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
    import std.stdio : stdout, writefln, writeln;

    if (plugin.adminSettings.printRaw)
    {
        if (event.tags.length) writeln(event.tags, '$');
        writeln(event.raw, '$');
        if (settings.flush) stdout.flush();
    }

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }

        if (settings.flush) stdout.flush();
    }

    version(AssertsGeneration)
    {
        if (plugin.adminSettings.printAsserts)
        {
            import kameloso.debugging : formatEventAssertBlock;
            import lu.core.string : contains;

            if (event.raw.contains(1))
            {
                logger.warning("event.raw contains CTCP 1 which might not get printed");
            }

            formatEventAssertBlock(stdout.lockingTextWriter, event);
            writeln();

            if (plugin.state.client != plugin.previousClient)
            {
                import kameloso.debugging : formatDelta;

                /+writeln("/*");
                /*writeln("with (parser.client)");
                writeln("{");*/
                stdout.lockingTextWriter.formatDelta!(No.asserts)
                    (plugin.previousClient, plugin.state.client, 0);
                /*writeln("}");*/
                writeln("*/");
                writeln();+/

                writeln("with (parser.client)");
                writeln("{");
                stdout.lockingTextWriter.formatDelta!(Yes.asserts)
                    (plugin.previousClient, plugin.state.client, 1);
                writeln("}\n");

                plugin.previousClient = plugin.state.client;
            }

            if (settings.flush) stdout.flush();
        }
    }
}


// onCommandShowUser
/++
 +  Prints the details of one or more specific, supplied users to the local terminal.
 +
 +  It basically prints the matching `dialect.defs.IRCUser`.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "user")
@Description("[debug] Prints out information about one or more specific users " ~
    "to the local terminal.", "$command [nickname] [nickname] ...")
void onCommandShowUser(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.printing : printObject;
    import std.algorithm.iteration : splitter;

    foreach (immutable username; event.content.splitter(" "))
    {
        if (const user = username in plugin.state.users)
        {
            printObject(*user);
        }
        else
        {
            immutable message = settings.colouredOutgoing ?
                "No such user: " ~ username.ircColour(IRCColour.red).ircBold :
                "No such user: " ~ username;

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
}


// onCommandSave
/++
 +  Saves current configuration to disk.
 +
 +  This saves all plugins' settings, not just this plugin's, effectively
 +  regenerating the configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "save")
@BotCommand(PrefixPolicy.nickname, "writeconfig")
@Description("Saves current configuration to disk.")
void onCommandSave(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    privmsg(plugin.state, event.channel, event.sender.nickname, "Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
 +  Prints out the current `users` array of the `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState` to the local terminal.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "users")
@Description("[debug] Prints out the current users array to the local terminal.")
void onCommandShowUsers(AdminPlugin plugin)
{
    import kameloso.printing : printObject;
    import std.stdio : stdout, writeln;

    foreach (immutable name, const user; plugin.state.users)
    {
        writeln(name);
        printObject(user);
    }

    writeln(plugin.state.users.length, " users.");
    if (settings.flush) stdout.flush();
}


// onCommandSudo
/++
 +  Sends supplied text to the server, verbatim.
 +
 +  You need basic knowledge of IRC server strings to use this.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "sudo")
@Description("[debug] Sends supplied text to the server, verbatim.",
    "$command [raw string]")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    raw(plugin.state, event.content);
}


// onCommandQuit
/++
 +  Sends a `dialect.defs.IRCEvent.Type.QUIT` event to the server.
 +
 +  If any extra text is following the "`quit`" prefix, it uses that as the quit
 +  reason, otherwise it falls back to the default as specified in the configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "quit")
@Description("Send a QUIT event to the server and exits the program.",
    "$command [optional quit reason]")
void onCommandQuit(AdminPlugin plugin, const IRCEvent event)
{
    if (event.content.length)
    {
        quit(plugin.state, event.content);
    }
    else
    {
        quit(plugin.state);
    }
}


// onCommandAddHome
/++
 +  Adds a channel to the list of currently active home channels, in the
 +  `dialect.defs.IRCClient.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  Follows up with a `core.thread.Fiber` to verify that the channel was actually joined.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "addhome")
@Description("Adds a channel to the list of homes.", "$command [channel]")
void onCommandAddHome(AdminPlugin plugin, const IRCEvent event)
{
    import lu.core.string : stripped;
    import dialect.common : isValidChannel;
    import std.algorithm.searching : canFind;
    import std.uni : toLower;

    immutable channelToAdd = event.content.stripped.toLower;

    if (!channelToAdd.isValidChannel(plugin.state.client.server))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "Invalid channel name.");
        return;
    }

    if (plugin.state.client.homes.canFind(channelToAdd))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "We are already in that home channel.");
        return;
    }

    // We need to add it to the homes array so as to get ChannelPolicy.home
    // ChannelAwareness to pick up the SELFJOIN.
    plugin.state.client.homes ~= channelToAdd;
    plugin.state.client.updated = true;
    join(plugin.state, channelToAdd);
    privmsg(plugin.state, event.channel, event.sender.nickname, "Home added.");

    // We have to follow up and see if we actually managed to join the channel
    // There are plenty ways for it to fail.

    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;

    void dg()
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

        const followupEvent = thisFiber.payload;

        if (followupEvent.channel != channelToAdd)
        {
            // Different channel; yield fiber, wait for another event
            Fiber.yield();
            return dg();
        }

        with (IRCEvent.Type)
        switch (followupEvent.type)
        {
        case SELFJOIN:
            // Success!
            /*client.homes ~= followupChannel;
            client.updated = true;*/
            return;

        case ERR_LINKCHANNEL:
            // We were redirected. Still assume we wanted to add this one?
            logger.log("Redirected!");
            plugin.state.client.homes ~= followupEvent.content.toLower;
            // Drop down and undo original addition
            break;

        default:
            privmsg(plugin.state, event.channel, event.sender.nickname, "Failed to join home channel.");
            break;
        }

        // Undo original addition
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable homeIndex = plugin.state.client.homes.countUntil(followupEvent.channel);
        if (homeIndex != -1)
        {
            plugin.state.client.homes = plugin.state.client.homes
                .remove!(SwapStrategy.unstable)(homeIndex);
            plugin.state.client.updated = true;
        }
        else
        {
            logger.error("Tried to remove non-existent home channel.");
        }
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg);

    with (IRCEvent.Type)
    {
        static immutable IRCEvent.Type[13] types =
        [
            ERR_BANNEDFROMCHAN,
            ERR_INVITEONLYCHAN,
            ERR_BADCHANNAME,
            ERR_LINKCHANNEL,
            ERR_TOOMANYCHANNELS,
            ERR_FORBIDDENCHANNEL,
            ERR_CHANNELISFULL,
            ERR_BADCHANNELKEY,
            ERR_BADCHANNAME,
            RPL_BADCHANPASS,
            ERR_SECUREONLYCHAN,
            ERR_SSLONLYCHAN,
            SELFJOIN,
        ];

        plugin.awaitEvents(fiber, types);
    }
}


// onCommandDelHome
/++
 +  Removes a channel from the list of currently active home channels, from the
 +  `dialect.defs.IRCClient.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "delhome")
@Description("Removes a channel from the list of homes and leaves it.", "$command [channel]")
void onCommandDelHome(AdminPlugin plugin, const IRCEvent event)
{
    import lu.core.string : stripped;
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : SwapStrategy, remove;

    immutable channel = event.content.stripped;
    immutable homeIndex = plugin.state.client.homes.countUntil(channel);

    if (homeIndex == -1)
    {
        import std.format : format;

        enum pattern = "Channel %s was not listed as a home.";

        immutable message = settings.colouredOutgoing ?
            pattern.format(channel.ircBold) :
            pattern.format(channel);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }

    plugin.state.client.homes = plugin.state.client.homes
        .remove!(SwapStrategy.unstable)(homeIndex);
    plugin.state.client.updated = true;
    part(plugin.state, channel);
    privmsg(plugin.state, event.channel, event.sender.nickname, "Home removed.");
}


// onCommandWhitelist
/++
 +  Adds a nickname to the list of users who may trigger the bot, to the current
 +  `dialect.defs.IRCClient.Class.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `kameloso.plugins.common.PrivilegeLevel.whitelist` level, as
 +  opposed to `kameloso.plugins.common.PrivilegeLevel.anyone` and
 +  `kameloso.plugins.common.PrivilegeLevel.admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "whitelist")
@Description("Adds an account to the whitelist of users who may trigger the bot.",
    "$command [account to whitelist]")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    import lu.core.string : stripped;
    plugin.lookupEnlist(event.content.stripped, "whitelist", event);
}


// lookupEnlist
/++
 +  Adds an account to either the whitelist or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      specified = The nickname or account to white-/blacklist.
 +      list = Which of "whitelist" or "blacklist" to add to.
 +      event = Optional instigating `dialect.defs.IRCEvent`.
 +/
void lookupEnlist(AdminPlugin plugin, const string specified, const string list,
    const IRCEvent event = IRCEvent.init)
{
    import kameloso.common : settings;
    import lu.core.string : contains, stripped;
    import dialect.common : isValidNickname;

    /// Report result, either to the local terminal or to the IRC channel/sender
    void report(const AlterationResult result, const string id)
    {
        import std.format : format;

        if (event.sender.nickname.length)
        {
            // IRC report

            with (AlterationResult)
            final switch (result)
            {
            case success:
                enum pattern = "%sed %s.";

                immutable message = settings.colouredOutgoing ?
                    pattern.format(list, id.ircColourByHash.ircBold) :
                    pattern.format(list, id);

                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;

            case noSuchAccount:
                assert(0, "Invalid delist-only AlterationResult passed to report()");

            case alreadyInList:
                enum pattern = "Account %s already %sed.";

                immutable message = settings.colouredOutgoing ?
                    pattern.format(id.ircColourByHash.ircBold, list) :
                    pattern.format(id, list);

                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;
            }
        }
        else
        {
            // Terminal report

            string infotint, logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;

                    infotint = (cast(KamelosoLogger)logger).infotint;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            with (AlterationResult)
            final switch (result)
            {
            case success:
                logger.logf("%sed %s%s%s.", list, infotint, specified, logtint);
                break;

            case noSuchAccount:
                assert(0, "Invalid enlist-only AlterationResult passed to report()");

            case alreadyInList:
                logger.logf("Account %s%s%s already %sed.", infotint, specified, logtint, list);
                break;
            }
        }
    }

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        immutable result = plugin.alterAccountClassifier(Yes.add, list, user.account);
        return report(result, user.account);
    }
    else if (!specified.isValidNickname(plugin.state.client.server))
    {
        if (event.sender.nickname.length)
        {
            // IRC report

            immutable message = settings.colouredOutgoing ?
                "Invalid nickname/account: " ~ specified.ircColour(IRCColour.red).ircBold :
                "Invalid nickname/account: " ~ specified;

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
        else
        {
            // Terminal report

            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warning("Invalid nickname/account: ", logtint, specified);
        }
        return;
    }

    void onSuccess(const string id)
    {
        immutable result = plugin.alterAccountClassifier(Yes.add, list, id);
        report(result, id);
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    version(TwitchSupport)
    {
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
        {
            return onSuccess(specified);
        }
    }

    // User not on record or on record but no account; WHOIS and try based on results

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specified);
}


// delist
/++
 +  Removes a nickname from either the whitelist or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      account = The account to delist as whitelisted/blacklisted.
 +      list = Which of "whitelist" or "blacklist" to remove from.
 +      event = Optional instigating `dialect.defs.IRCEvent`.
 +/
void delist(AdminPlugin plugin, const string account, const string list,
    const IRCEvent event = IRCEvent.init)
{
    import std.format : format;

    if (!account.length)
    {
        if (event.sender.nickname.length)
        {
            // IRC report
            privmsg(plugin.state, event.channel, event.sender.nickname, "No account specified.");
        }
        else
        {
            // Terminal report
            logger.warning("No account specified.");
        }
        return;
    }

    immutable result = plugin.alterAccountClassifier(No.add, list, account);

    if (event.sender.nickname.length)
    {
        // IRC report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only AlterationResult returned to delist()");

        case noSuchAccount:
            enum pattern = "No such account %s to de%s.";

            immutable message = settings.colouredOutgoing ?
                pattern.format(account.ircColourByHash.ircBold, list) :
                pattern.format(account, list);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;

        case success:
            enum pattern = "de%sed %s.";

            immutable message = settings.colouredOutgoing ?
                pattern.format(list, account.ircColourByHash.ircBold) :
                pattern.format(list, account);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;
        }
    }
    else
    {
        // Terminal report

        string infotint, logtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
            }
        }

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only AlterationResult returned to delist()");

        case noSuchAccount:
            logger.logf("No such account %s%s%s to de%s.", infotint, account, logtint, list);
            break;

        case success:
            logger.logf("de%sed %s%s%s.", list, infotint, account, logtint);
            break;
        }
    }
}


// onCommandDewhitelist
/++
 +  Removes a nickname from the list of users who may trigger the bot, from the
 +  `dialect.defs.IRCClient.Class.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `kameloso.plugins.common.PrivilegeLevel.whitelist` level, as
 +  opposed to `kameloso.plugins.common.PrivilegeLevel.admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "dewhitelist")
@Description("Removes an account from the whitelist of users who may trigger the bot.",
    "$command [account to remove from whitelist]")
void onCommandDewhitelist(AdminPlugin plugin, const IRCEvent event)
{
    import lu.core.string : stripped;
    plugin.delist(event.content.stripped, "whitelist", event);
}


// onCommandBlacklist
/++
 +  Adds a nickname to the list of users who may not trigger the bot whatsoever,
 +  even on actions annotated `kameloso.plugins.common.PrivilegeLevel.anyone`.
 +
 +  This is on a `kameloso.plugins.common.PrivilegeLevel.whitelist` level, as
 +  opposed to `kameloso.plugins.common.PrivilegeLevel.anyone` and
 +  `kameloso.plugins.common.PrivilegeLevel.admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "blacklist")
@Description("Adds an account to the blacklist, exempting them from triggering the bot.",
    "$command [account to blacklist]")
void onCommandBlacklist(AdminPlugin plugin, const IRCEvent event)
{
    import lu.core.string : stripped;
    plugin.lookupEnlist(event.content.stripped, "blacklist", event);
}


// onCommandDeblacklist
/++
 +  Removes a nickname from the list of users who may not trigger the bot whatsoever.
 +
 +  This is on a `kameloso.plugins.common.PrivilegeLevel.whitelist` level, as
 +  opposed to `kameloso.plugins.common.PrivilegeLevel.admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "deblacklist")
@Description("Removes an account from the blacklist, allowing them to trigger the bot again.",
    "$command [account to remove from whitelist]")
void onCommandDeblacklist(AdminPlugin plugin, const IRCEvent event)
{
    import lu.core.string : stripped;
    plugin.delist(event.content.stripped, "blacklist", event);
}


// AlterationResult
/++
 +  Enum embodying the results of an account alteration.
 +
 +  Returned by functions to report success or failure, to let them give terminal
 +  or IRC feedback appropriately.
 +/
enum AlterationResult
{
    alreadyInList,  /// When enlisting, an account already existed.
    noSuchAccount,  /// When delisting, an account could not be found.
    success,        /// Successful enlist/delist.
}


// alterAccountClassifier
/++
 +  Adds or removes an account from the file of user classifier definitions,
 +  and reloads all plugins to make them read the updated lists.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      add = Whether to add to or remove from lists.
 +      list = Which list to add to or remove from; `whitelist` or `blacklist`.
 +      account = Services account name to add or remove.
 +
 +  Returns:
 +      `AlterationResult.alreadyInList` if enlisting (`Yes.add`) and the account
 +      was already in the specified list.
 +      `AlterationResult.noSuchAccount` if delisting (`No.add`) and no such
 +      account could be found in the specified list.
 +      `AlterationResult.success` if enlisting or delisting succeeded.
 +/
AlterationResult alterAccountClassifier(AdminPlugin plugin, const Flag!"add" add,
    const string list, const string account)
{
    import kameloso.thread : ThreadMessage;
    import lu.json : JSONStorage;
    import std.concurrency : send;
    import std.json : JSONValue;

    assert(((list == "whitelist") || (list == "blacklist")), list);

    JSONStorage json;
    json.reset();
    json.load(plugin.userFile);

    /*if ("admin" !in json)
    {
        json["admin"] = null;
        json["admin"].array = null;
    }*/

    if ("whitelist" !in json)
    {
        json["whitelist"] = null;
        json["whitelist"].array = null;
    }

    if ("blacklist" !in json)
    {
        json["blacklist"] = null;
        json["blacklist"].array = null;
    }

    immutable accountAsJSON = JSONValue(account);

    if (add)
    {
        import std.algorithm.searching : canFind;

        if (json[list].array.canFind(accountAsJSON))
        {
            return AlterationResult.alreadyInList;
        }
        else
        {
            json[list].array ~= accountAsJSON;
        }
    }
    else
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable index = json[list].array.countUntil(accountAsJSON);

        if (index == -1)
        {
            return AlterationResult.noSuchAccount;
        }

        json[list] = json[list].array.remove!(SwapStrategy.unstable)(index);
    }

    json.save!(JSONStorage.KeyOrderStrategy.adjusted)(plugin.userFile);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
    return AlterationResult.success;
}


// onCommandResetTerminal
/++
 +  Outputs the ASCII control character *`15`* to the terminal.
 +
 +  This helps with restoring it if the bot has accidentally printed a different
 +  control character putting it would-be binary mode, like what happens when
 +  you try to `cat` a binary file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "resetterm")
@Description("Outputs the ASCII control character 15 to the terminal, " ~
    "to recover from binary garbage mode")
void onCommandResetTerminal()
{
    import kameloso.terminal : TerminalToken;
    import std.stdio : stdout, write;

    write(cast(char)TerminalToken.reset);
    if (settings.flush) stdout.flush();
}


// onCommandPrintRaw
/++
 +  Toggles a flag to print all incoming events *raw*.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printraw")
@Description("[debug] Toggles a flag to print all incoming events raw.")
void onCommandPrintRaw(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;

    immutable message = settings.colouredOutgoing ?
        "Printing all: " ~ plugin.adminSettings.printRaw.text.ircBold :
        "Printing all: " ~ plugin.adminSettings.printRaw.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandPrintBytes
/++
 +  Toggles a flag to print all incoming events *as individual bytes*.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printbytes")
@Description("[debug] Toggles a flag to print all incoming events as bytes.")
void onCommandPrintBytes(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;

    immutable message = settings.colouredOutgoing ?
        "Printing bytes: " ~ plugin.adminSettings.printBytes.text.ircBold :
        "Printing bytes: " ~ plugin.adminSettings.printBytes.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandAsserts
/++
 +  Toggles a flag to print *assert statements* of incoming events.
 +
 +  This is used to creating unittest blocks in the source code.
 +/
debug
version(AssertsGeneration)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printasserts")
@Description("[debug] Toggles a flag to generate assert statements for incoming events")
void onCommandAsserts(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;
    import std.stdio : stdout;

    plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;

    immutable message = settings.colouredOutgoing ?
        "Printing asserts: " ~ plugin.adminSettings.printAsserts.text.ircBold :
        "Printing asserts: " ~ plugin.adminSettings.printAsserts.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);

    if (plugin.adminSettings.printAsserts)
    {
        import kameloso.debugging : formatClientAssignment;
        // Print the bot assignment but only if we're toggling it on
        formatClientAssignment(stdout.lockingTextWriter, plugin.state.client);
    }

    if (settings.flush) stdout.flush();
}


// onCommandJoinPart
/++
 +  Joins or parts a supplied channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "join")
@BotCommand(PrefixPolicy.nickname, "part")
@Description("Joins/parts a channel.", "$command [channel]")
void onCommandJoinPart(AdminPlugin plugin, const IRCEvent event)
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : joiner, splitter;
    import std.conv : to;
    import std.uni : asLowerCase;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "No channels supplied ...");
        return;
    }

    immutable channels = event.content
        .splitter(" ")
        .joiner(",")
        .to!string;

    if (event.aux.asLowerCase.equal("join"))
    {
        join(plugin.state, channels);
    }
    else
    {
        part(plugin.state, channels);
    }
}


// onSetCommand
/++
 +  Sets a plugin option by variable string name.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.nickname, "set")
@Description("Changes a plugin's settings", "$command [plugin.setting=value]")
void onSetCommand(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : CarryingFiber, ThreadMessage;
    import std.concurrency : send;

    void dg()
    {
        import core.thread : Fiber;
        import std.conv : ConvException;

        auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        try
        {
            immutable success = thisFiber.payload.applyCustomSettings([ event.content ]);

            if (success)
            {
                privmsg(plugin.state, event.channel, event.sender.nickname, "Setting changed.");
            }
            else
            {
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "Invalid syntax or plugin/settings name.");
            }
        }
        catch (ConvException e)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "There was a conversion error. Please verify the values in your setting.");
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg);
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);
}


// onCommandAuth
/++
 +  Asks the `kamloso.plugins.connect.ConnectService` to (re-)authenticate to services.
 +/
version(WithConnectService)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.nickname, "auth")
@Description("(Re-)authenticates with services. Useful if the server has forcefully logged us out.")
void onCommandAuth(AdminPlugin plugin)
{
    version(TwitchSupport)
    {
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch) return;
    }

    import kameloso.thread : ThreadMessage, busMessage;
    import std.concurrency : send;

    plugin.state.mainThread.send(ThreadMessage.BusMessage(), "connect", busMessage("auth"));
}


// onCommandStatus
/++
 +  Dumps information about the current state of the bot to the local terminal.
 +
 +  This can be very spammy.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "status")
@Description("[debug] Dumps information about the current state of the bot to the local terminal.")
void onCommandStatus(AdminPlugin plugin)
{
    import kameloso.printing : printObjects;
    import std.stdio : stdout, writeln;

    logger.log("Current state:");
    printObjects!(Yes.printAll)(plugin.state.client, plugin.state.client.server);
    writeln();

    logger.log("Channels:");
    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        writeln(channelName);
        printObjects(channel);
    }
    //writeln();

    /*logger.log("Users:");
    foreach (immutable nickname, const user; plugin.state.users)
    {
        writeln(nickname);
        printObject(user);
    }*/
}


// onCommandBus
/++
 +  Sends an internal bus message to other plugins, much like how such can be
 +  sent with the Pipeline plugin.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "bus")
@Description("[DEBUG] Sends an internal bus message.", "$command [header] [content...]")
void onCommandBus(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage, busMessage;
    import lu.core.string : contains, nom;
    import std.stdio : stdout, writeln;

    if (!event.content.length) return;

    if (!event.content.contains!(Yes.decode)(" "))
    {
        logger.info("Sending bus message.");
        writeln("Header: ", event.content);
        writeln("Content: (empty)");
        if (settings.flush) stdout.flush();

        plugin.state.mainThread.send(ThreadMessage.BusMessage(), event.content);
    }
    else
    {
        string slice = event.content;  // mutable
        immutable header = slice.nom(" ");

        logger.info("Sending bus message.");
        writeln("Header: ", header);
        writeln("Content: ", slice);
        if (settings.flush) stdout.flush();

        plugin.state.mainThread.send(ThreadMessage.BusMessage(),
            header, busMessage(slice));
    }
}


import kameloso.thread : Sendable;

// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`admin`" header,
 +  and calls functions based on the payload message.
 +
 +  This is used in the Pipeline plugin, to allow us to trigger admin verbs via
 +  the command-line pipe.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
version(Posix)  // No need to compile this in on pipeline-less builds
void onBusMessage(AdminPlugin plugin, const string header, shared Sendable content)
{
    if (header != "admin") return;

    // Don't return if disabled, as it blocks us from re-enabling with verb set

    import kameloso.printing : printObject;
    import kameloso.thread : BusMessage;
    import lu.core.string : contains, nom, strippedRight;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    string slice = message.payload.strippedRight;
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    debug
    {
        case "status":
            return plugin.onCommandStatus();

        case "users":
            return plugin.onCommandShowUsers();

        case "user":
            if (const user = slice in plugin.state.users)
            {
                printObject(*user);
            }
            else
            {
                logger.error("No such user: ", slice);
            }
            break;

        case "state":
            printObject(plugin.state);
            break;

        case "printraw":
            plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;
            return;

        case "printbytes":
            plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;
            return;

        debug
        version(AssertsGeneration)
        {
            case "printasserts":
                plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;

                if (plugin.adminSettings.printAsserts)
                {
                    import kameloso.debugging : formatClientAssignment;
                    import std.stdio : stdout;

                    // Print the bot assignment but only if we're toggling it on
                    formatClientAssignment(stdout.lockingTextWriter, plugin.state.client);
                }
                return;
        }
    }

    case "resetterm":
        return onCommandResetTerminal();

    case "set":
        import kameloso.thread : CarryingFiber, ThreadMessage;

        void dg()
        {
            import core.thread : Fiber;
            import std.conv : ConvException;

            auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

            immutable success = thisFiber.payload.applyCustomSettings([ slice ]);
            if (success) logger.log("Setting changed.");
            // applyCustomSettings displays its own error messages
        }

        auto fiber = new CarryingFiber!(IRCPlugin[])(&dg);
        return plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);

    case "save":
        import kameloso.thread : ThreadMessage;

        logger.log("Saving configuration to disk.");
        return plugin.state.mainThread.send(ThreadMessage.Save());

    case "whitelist":
    case "blacklist":
        return plugin.lookupEnlist(slice, verb);

    case "dewhitelist":
    case "deblacklist":
        return plugin.delist(slice, verb[2..$]);

    default:
        logger.error("Unimplemented piped verb: ", verb);
        break;
    }
}


// start
/++
 +  Print the initial assignment of client member fields, if we're printing asserts.
 +
 +  This lets us copy and paste the environment of later generated asserts.
 +
 +  `printAsserts` is debug-only, so gate this behind debug too.
 +/
debug
version(AssertsGeneration)
void start(AdminPlugin plugin)
{
    if (!plugin.adminSettings.printAsserts) return;

    import kameloso.debugging : formatClientAssignment;
    import std.stdio : stdout, writeln;

    writeln();
    formatClientAssignment(stdout.lockingTextWriter, plugin.state.client);
    writeln();

    plugin.previousClient = plugin.state.client;
}


version(OmniscientAdmin)
{
    mixin UserAwareness!(ChannelPolicy.any);
    mixin ChannelAwareness!(ChannelPolicy.any);

    version(TwitchSupport)
    {
        mixin TwitchAwareness!(ChannelPolicy.any);
    }
}
else
{
    mixin UserAwareness;
    mixin ChannelAwareness;

    version(TwitchSupport)
    {
        mixin TwitchAwareness;
    }
}

public:


// AdminPlugin
/++
 +  The Admin plugin is a plugin aimed for adḿinistrative use and debugging.
 +
 +  It was historically part of the `kameloso.plugins.chatbot.ChatbotPlugin`.
 +/
final class AdminPlugin : IRCPlugin
{
private:
    /// All Admin options gathered.
    @Settings AdminSettings adminSettings;

    debug
    version(AssertsGeneration)
    {
        /// Snapshot of the previous `dialect.defs.IRCClient`.
        IRCClient previousClient;
    }

    /// File with user definitions. Must be the same as in persistence.d.
    @Resource string userFile = "users.json";

    mixin IRCPluginImpl;
}
