module kameloso.plugins.admin2;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.stringutils;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.concurrency;
import std.traits;
import std.string;
import std.algorithm;

private:

IrcPluginState state;
bool printAll;


void updateBot()
{
    with (state)
    {
        shared botCopy = cast(shared)bot;
        mainThread.send(botCopy);
    }
}


@(Description("sudo", "Sends a command as-is to the server"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "sudo"))
void onCommandSudo(const IrcEvent event)
{
    if (state.users[event.sender].login != state.bot.master)
    {
        writefln("Failsafe triggered: bot is not master (%s)", event.sender);
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(), event.content);
}


@(Description("quit", "Disconnects from the server with the supplied message"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "quit"))
void onCommandQuit(const IrcEvent event)
{
    if (state.users[event.sender].login != state.bot.master)
    {
        writefln("Failsafe triggered: bot is not master (%s)", event.sender);
        return;
    }
    // By sending a concurrency message it should quit nicely
    /*string message = event.content;
    message.nom!(Decode.yes)(" ");
    message = message.strip;

    state.mainThread.send(ThreadMessage.Quit(), "QUIT :" ~ message);*/
    state.mainThread.send(ThreadMessage.Quit(), event.content);
}


@(Description("addchan", "Adds a channel to the list of channels to be active in"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "addchan"))
@(Prefix(NickPrefixPolicy.required, "addhome"))
void onCommandAddChan(const IrcEvent event)
{
    import std.algorithm.searching : canFind;
    import std.string : strip;

    immutable channel = event.content.strip();

    // Add an "active" channel, in which the bot should react
    if (!channel.isValidChannel)
    {
        writeln("invalid channel: ", channel);
        return;
    }

    if (!state.bot.channels.canFind(channel))
    {
        state.mainThread.send(ThreadMessage.Sendline(), "JOIN :" ~ channel);
    }

    writeln("Adding channel: ", channel);
    state.bot.channels ~= channel;
    updateBot();
}


@(Description("delchan", "Removes a channel from the list of channels to be active in"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "delchan"))
@(Prefix(NickPrefixPolicy.required, "delhome"))
void onCommandDelChan(const IrcEvent event)
{
    // Remove a channel from the active list

    immutable channel = event.content.strip();

    if (!channel.isValidChannel)
    {
        writeln("invalid channel: ", channel);
        return;
    }

    const chanIndex = state.bot.channels.countUntil(channel);

    if (chanIndex == -1)
    {
        writefln("Channel %s was not in bot.channels", channel);
        return;
    }

    state.bot.channels = state.bot.channels.remove(chanIndex);
    state.mainThread.send(ThreadMessage.Sendline(), "PART :" ~ channel);
    updateBot();
}


@(Description("addfriend", "Add a *NickServ login* to the list of friends who may use the bot's services"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "addfriend"))
void onCommandAddFriend(const IrcEvent event)
{
    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        writeln("No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        writeln("Nickname must not contain spaces");
        return;
    }

    state.bot.friends ~= nickname;
    writefln("%s added to friends", nickname);
    updateBot();
}


@(Description("delfriend", "Removes a *NickServ login* from the friends list"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "delfriend"))
void onCommandDelFriend(const IrcEvent event)
{
    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        writeln("No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        writeln("Nickname must not contain spaces");
        return;
    }

    auto friendIndex = state.bot.friends.countUntil(nickname);

    if (friendIndex == -1)
    {
        writefln("No such friend");
        return;
    }

    state.bot.friends = state.bot.friends.remove(friendIndex);
    writefln("%s removed from friends", nickname);
    updateBot();
}


@(Description("resetterm", "Outputs ASCII control character 15 to reset the terminal if it has entered binary mode"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "resetterm"))
void onCommandResetTerminal(const IrcEvent event)
{
    import std.stdio : write;
    write(ControlCharacter.termReset);
}


@(Description("printall", "Sets a flag to print all incoming IRC strings, raw"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "printall"))
void onCommandPrintAll(const IrcEvent event)
{
    printAll = !printAll;
    writeln("Printing all: ", printAll);
}


@(Description("status", "Prints the current bot status to the terminal"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "status"))
void onCommandStatus(const IrcEvent event)
{
    state.mainThread.send(ThreadMessage.Status());
}


@(Description("join/part", "Joins or parts a channel"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "join"))
@(Prefix(NickPrefixPolicy.required, "part"))
void onCommandJoinPart(const string prefix, const IrcEvent event)
{
    import std.algorithm.iteration : splitter, joiner;
    import std.format : format;

    if (!event.content.length)
    {
        writeln("No channels supplied...");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(prefix, event.content.splitter(' ').joiner(",")));
}


// -------------------------------------- FIX THIS COPYPASTE

@(Description("whoislogin", "Catch a whois-login event to update the list of tracked users"))
@(IrcEvent.Type.WHOISLOGIN)
void onWhoisLogin(const IrcEvent event)
{
    state.users[event.target] = userFromEvent(event);
}


@(Description("endofwhois", "Catch an end-of-whois event to remove queued events"))
@(IrcEvent.Type.RPL_ENDOFWHOIS)
void onEndOfWhois(const IrcEvent event)
{
    state.queue.remove(event.target);
}


@(Description("part/quit", "Catch a part event to remove the nickname from the list of tracked users"))
@(IrcEvent.Type.PART)
@(IrcEvent.Type.QUIT)
void onLeave(const IrcEvent event)
{
    state.users.remove(event.sender);
}


@(Description("selfnick", "Catch a selfnick event to properly update the bot's (nickname) state"))
@(IrcEvent.Type.SELFNICK)
void onSelfNick(const IrcEvent event)
{
    // writeln("[!] on selfnick");
    if (state.bot.nickname == event.content)
    {
        writefln("%s saw SELFNICK but already had that nick...", __MODULE__);
    }
    else
    {
        state.bot.nickname = event.content;
    }
}

// -------------------------------------- FIX THIS COPYPASTE


mixin onEventImpl!__MODULE__;

public:

// AdminPlugin
/++
 +  A plugin aimed for adḿinistrative use. It was historically part of Chatbot but now lives
 +  by itself, sadly with much code between them duplicated. FIXME.
 +/
final class AdminPlugin2 : IrcPlugin
{
    mixin IrcPluginBasics2;
}
