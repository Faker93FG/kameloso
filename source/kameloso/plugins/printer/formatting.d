/++
 +  Implementation of Printer plugin functionality that concerns formatting.
 +  For internal use.
 +
 +  The `dialect.defs.IRCEvent`-annotated handlers must be in the same module
 +  as the `kameloso.plugins.admin.AdminPlugin`, but these implementation
 +  functions can be offloaded here to limit module size a bit.
 +/
module kameloso.plugins.printer.formatting;

version(WithPlugins):
version(WithPrinterPlugin):

private:

import kameloso.plugins.printer : PrinterPlugin;

import kameloso.plugins.core;
import kameloso.irccolours;
import dialect.defs;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

version(Colours) import kameloso.terminal : TerminalForeground;

package:


version(Colours)
{
    alias TF = TerminalForeground;

    /++
     +  Default colours for printing events on a dark terminal background.
     +/
    enum EventPrintingDark : TerminalForeground
    {
        type      = TF.lightblue,
        error     = TF.lightred,
        sender    = TF.lightgreen,
        target    = TF.cyan,
        channel   = TF.yellow,
        content   = TF.default_,
        aux       = TF.white,
        count     = TF.green,
        altcount  = TF.lightgreen,
        num       = TF.darkgrey,
        badge     = TF.white,
        emote     = TF.cyan,
        highlight = TF.white,
        query     = TF.lightgreen,
    }

    /++
     +  Default colours for printing events on a bright terminal background.
     +/
    enum EventPrintingBright : TerminalForeground
    {
        type      = TF.blue,
        error     = TF.red,
        sender    = TF.green,
        target    = TF.cyan,
        channel   = TF.yellow,
        content   = TF.default_,
        aux       = TF.black,
        count     = TF.lightgreen,
        altcount  = TF.green,
        num       = TF.lightgrey,
        badge     = TF.black,
        emote     = TF.lightcyan,
        highlight = TF.black,
        query     = TF.green,
    }
}


// put
/++
 +  Puts a variadic list of values into an output range sink.
 +
 +  Params:
 +      colours = Whether or not to accept terminal colour tokens and use
 +          them to tint the text.
 +      sink = Output range to sink items into.
 +      args = Variadic list of things to put into the output range.
 +/
void put(Flag!"colours" colours = No.colours, Sink, Args...)
    (auto ref Sink sink, Args args)
if (isOutputRange!(Sink, char[]))
{
    import std.conv : to;
    import std.traits : Unqual;

    foreach (arg; args)
    {
        alias T = Unqual!(typeof(arg));

        bool coloured;

        version(Colours)
        {
            import kameloso.terminal : isAColourCode;

            static if (colours && isAColourCode!T)
            {
                import kameloso.terminal : colourWith;
                sink.colourWith(arg);
                coloured = true;
            }
        }

        if (coloured) continue;

        static if (__traits(compiles, sink.put(T.init)) && !is(T == bool))
        {
            sink.put(arg);
        }
        else static if (is(T == bool))
        {
            sink.put(arg ? "true" : "false");
        }
        else static if (is(T : int))
        {
            import lu.conv : toAlphaInto;
            arg.toAlphaInto(sink);
        }
        else
        {
            sink.put(arg.to!string);
        }
    }
}

///
unittest
{
    import std.array : Appender;

    Appender!string sink;

    .put(sink, "abc", 123, "def", 456, true);
    assert((sink.data == "abc123def456true"), sink.data);

    version(Colours)
    {
        import kameloso.terminal : TerminalBackground, TerminalForeground, TerminalReset;

        sink = typeof(sink).init;

        .put!(Yes.colours)(sink, "abc", TerminalForeground.white, "def",
            TerminalBackground.red, "ghi", TerminalReset.all, "123");
        assert((sink.data == "abc\033[97mdef\033[41mghi\033[0m123"), sink.data);
    }
}


// formatMessageMonochrome
/++
 +  Formats an `dialect.defs.IRCEvent` into an output range sink, in monochrome.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `dialect.defs.IRCEvent` into.
 +      event = The `dialect.defs.IRCEvent` that is to be formatted.
 +      bellOnMention = Whether or not to emit a terminal bell when the bot's
 +          nickname is mentioned in chat.
 +      bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
void formatMessageMonochrome(Sink)(PrinterPlugin plugin, auto ref Sink sink, IRCEvent event,
    const Flag!"bellOnMention" bellOnMention,
    const Flag!"bellOnError" bellOnError)
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : Enum;
    import std.algorithm.comparison : equal;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;
    import std.uni : asLowerCase, asUpperCase;

    immutable typestring = Enum!(IRCEvent.Type).toString(event.type).withoutTypePrefix;

    bool shouldBell;

    static if (!__traits(hasMember, Sink, "data"))
    {
        scope(exit)
        {
            sink.put('\n');
        }
    }

    with (event)
    {
        void putSender()
        {
            if (sender.isServer)
            {
                sink.put(sender.address);
            }
            else
            {
                bool putDisplayName;

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        sender.displayName.length)
                    {
                        sink.put(sender.displayName);
                        putDisplayName = true;

                        if ((sender.displayName != sender.nickname) &&
                            !sender.displayName.asLowerCase.equal(sender.nickname))
                        {
                            .put(sink, " <", sender.nickname, '>');
                        }
                    }
                }

                if (!putDisplayName && sender.nickname.length)
                {
                    // Can be no-nick special: [PING] *2716423853
                    sink.put(sender.nickname);
                }

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        plugin.printerSettings.twitchBadges && sender.badges.length)
                    {
                        with (IRCEvent.Type)
                        switch (type)
                        {
                        case JOIN:
                        case SELFJOIN:
                        case PART:
                        case SELFPART:
                        case QUERY:
                        //case SELFQUERY:  // Doesn't seem to happen
                            break;

                        default:
                            sink.put(" [");
                            if (plugin.printerSettings.abbreviatedBadges)
                            {
                                sink.abbreviateBadges(sender.badges);
                            }
                            else
                            {
                                sink.put(sender.badges);
                            }
                            sink.put(']');
                        }
                    }
                }
            }
        }

        void putTarget()
        {
            sink.put(" (");

            bool putDisplayName;

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    target.displayName.length)
                {
                    .put(sink, target.displayName, ')');
                    putDisplayName = true;

                    if ((target.displayName != target.nickname) &&
                        !target.displayName.asLowerCase.equal(target.nickname))
                    {
                        .put(sink, " <", target.nickname, '>');
                    }
                }
            }

            if (!putDisplayName)
            {
                .put(sink, target.nickname, ')');
            }

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    plugin.printerSettings.twitchBadges && target.badges.length)
                {
                    sink.put(" [");
                    if (plugin.printerSettings.abbreviatedBadges)
                    {
                        sink.abbreviateBadges(target.badges);
                    }
                    else
                    {
                        sink.put(target.badges);
                    }
                    sink.put(']');
                }
            }
        }

        void putContent()
        {
            if (sender.isServer || sender.nickname.length)
            {
                immutable isEmote = (event.type == IRCEvent.Type.EMOTE) ||
                    (event.type == IRCEvent.Type.SELFEMOTE);

                if (isEmote)
                {
                    sink.put(' ');
                }
                else
                {
                    sink.put(`: "`);
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                case TWITCH_SUBGIFT:
                    if (plugin.state.client.nickname.length &&
                        content.containsNickname(plugin.state.client.nickname))
                    {
                        // Nick was mentioned (certain)
                        shouldBell = bellOnMention;
                    }
                    break;

                default:
                    break;
                }

                sink.put(content);
                if (!isEmote) sink.put('"');
            }
            else
            {
                // PING or ERROR likely
                sink.put(content);  // No need for indenting space
            }
        }

        event.content = stripEffects(event.content);

        sink.put('[');

        (cast(DateTime)SysTime
            .fromUnixTime(event.time))
            .timeOfDay
            .toString(sink);

        sink.put("] [");

        if (plugin.printerSettings.uppercaseTypes) sink.put(typestring);
        else sink.put(typestring.asLowerCase);

        sink.put("] ");

        if (channel.length) .put(sink, '[', channel, "] ");

        putSender();

        if (target.nickname.length) putTarget();

        if (content.length) putContent();

        if (aux.length) .put(sink, " (", aux, ')');

        if (count != 0)
        {
            sink.put(" {");
            .put(sink, count);
            sink.put('}');
        }

        if (altcount != 0)
        {
            sink.put(" {");
            .put(sink, altcount);
            sink.put('}');
        }

        if (num > 0)
        {
            import lu.conv : toAlphaInto;

            //sink.formattedWrite(" (#%03d)", num);
            sink.put(" (#");
            num.toAlphaInto!(3, 3)(sink);
            sink.put(')');
        }

        if (errors.length && !plugin.printerSettings.silentErrors)
        {
            .put(sink, " ! ", errors, " !");
        }

        shouldBell = shouldBell || ((target.nickname == plugin.state.client.nickname) &&
            ((event.type == IRCEvent.Type.QUERY) ||
            (event.type == IRCEvent.Type.TWITCH_SUBGIFT)));
        shouldBell = shouldBell || (errors.length && bellOnError &&
            !plugin.printerSettings.silentErrors);

        if (shouldBell)
        {
            import kameloso.terminal : TerminalToken;
            sink.put(TerminalToken.bell);
        }
    }
}

///
unittest
{
    import std.array : Appender;

    Appender!string sink;

    IRCPluginState state;
    state.server.daemon = IRCServer.Daemon.twitch;
    PrinterPlugin plugin = new PrinterPlugin(state);

    IRCEvent event;

    with (event.sender)
    {
        nickname = "nickname";
        address = "127.0.0.1";
        version(TwitchSupport) displayName = "Nickname";
        //account = "n1ckn4m3";
        class_ = IRCUser.Class.whitelist;
    }

    event.type = IRCEvent.Type.JOIN;
    event.channel = "#channel";

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable joinLine = sink.data[11..$];
    version(TwitchSupport) assert((joinLine == "[join] [#channel] Nickname"), joinLine);
    else assert((joinLine == "[join] [#channel] nickname"), joinLine);
    sink = typeof(sink).init;

    event.type = IRCEvent.Type.CHAN;
    event.content = "Harbl snarbl";

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable chanLine = sink.data[11..$];
    version(TwitchSupport) assert((chanLine == `[chan] [#channel] Nickname: "Harbl snarbl"`), chanLine);
    else assert((chanLine == `[chan] [#channel] nickname: "Harbl snarbl"`), chanLine);
    sink = typeof(sink).init;

    version(TwitchSupport)
    {
        plugin.printerSettings.abbreviatedBadges = true;
        event.sender.badges = "broadcaster/0,moderator/1,subscriber/9";
        //colour = "#3c507d";

        plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
        immutable twitchLine = sink.data[11..$];
        version(TwitchSupport) assert((twitchLine == `[chan] [#channel] Nickname [BMS]: "Harbl snarbl"`), twitchLine);
        else assert((twitchLine == `[chan] [#channel] nickname [BMS]: "Harbl snarbl"`), twitchLine);
        sink = typeof(sink).init;
        event.sender.badges = string.init;
    }

    event.type = IRCEvent.Type.ACCOUNT;
    event.channel = string.init;
    event.content = string.init;
    event.sender.account = "n1ckn4m3";
    event.aux = "n1ckn4m3";

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable accountLine = sink.data[11..$];
    version(TwitchSupport) assert((accountLine == "[account] Nickname (n1ckn4m3)"), accountLine);
    else assert((accountLine == "[account] nickname (n1ckn4m3)"), accountLine);
    sink = typeof(sink).init;

    event.errors = "DANGER WILL ROBINSON";
    event.content = "Blah balah";
    event.num = 666;
    event.count = -42;
    event.aux = string.init;
    event.type = IRCEvent.Type.ERROR;

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable errorLine = sink.data[11..$];
    version(TwitchSupport) assert((errorLine == `[error] Nickname: "Blah balah" {-42} (#666) ` ~
        "! DANGER WILL ROBINSON !"), errorLine);
    else assert((errorLine == `[error] nickname: "Blah balah" {-42} (#666) ` ~
        "! DANGER WILL ROBINSON !"), errorLine);
    //sink = typeof(sink).init;
}


// formatMessageColoured
/++
 +  Formats an `dialect.defs.IRCEvent` into an output range sink, coloured.
 +
 +  It formats the timestamp, the type of the event, the sender or the sender's
 +  display name, the channel or target, the content body, as well as auxiliary
 +  information and numbers.
 +
 +  Params:
 +      plugin = Current `PrinterPlugin`.
 +      sink = Output range to format the `dialect.defs.IRCEvent` into.
 +      event = The `dialect.defs.IRCEvent` that is to be formatted.
 +      bellOnMention = Whether or not to emit a terminal bell when the bot's
 +          nickname is mentioned in chat.
 +      bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
version(Colours)
void formatMessageColoured(Sink)(PrinterPlugin plugin, auto ref Sink sink, IRCEvent event,
    const Flag!"bellOnMention" bellOnMention,
    const Flag!"bellOnError" bellOnError)
if (isOutputRange!(Sink, char[]))
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal : FG = TerminalForeground, colourWith;
    import lu.conv : Enum;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;
    alias Timestamp = DefaultColours.TimestampColour;

    immutable rawTypestring = Enum!(IRCEvent.Type).toString(event.type);
    immutable typestring = rawTypestring.withoutTypePrefix;

    bool shouldBell;

    immutable bright = plugin.state.settings.brightTerminal ? Yes.bright : No.bright;

    /++
     +  Outputs a terminal ANSI colour token based on the hash of the passed
     +  nickname.
     +
     +  It gives each user a random yet consistent colour to their name.
     +/
    FG colourByHash(const string nickname)
    {
        import std.traits : EnumMembers;

        alias foregroundMembers = EnumMembers!TerminalForeground;

        static immutable TerminalForeground[foregroundMembers.length+(-3)] fgBright =
        [
            //FG.default_,
            FG.black,
            FG.red,
            FG.green,
            //FG.yellow,  // Blends too much with channel
            FG.blue,
            FG.magenta,
            FG.cyan,
            FG.lightgrey,
            FG.darkgrey,
            FG.lightred,
            FG.lightgreen,
            FG.lightyellow,
            FG.lightblue,
            FG.lightmagenta,
            FG.lightcyan,
            //FG.white,
        ];

        static immutable TerminalForeground[foregroundMembers.length+(-3)] fgDark =
        [
            //FG.default_,
            //FG.black,
            FG.red,
            FG.green,
            //FG.yellow,
            FG.blue,
            FG.magenta,
            FG.cyan,
            FG.lightgrey,
            FG.darkgrey,
            FG.lightred,
            FG.lightgreen,
            FG.lightyellow,
            FG.lightblue,
            FG.lightmagenta,
            FG.lightcyan,
            FG.white,
        ];

        if (plugin.printerSettings.randomNickColours)
        {
            import kameloso.terminal : colourByHash;
            return colourByHash(nickname, bright ? fgBright[] : fgDark[]);
        }
        else
        {
            // Don't differentiate between sender and target? Consistency?
            return bright ? Bright.sender : Dark.sender;
        }
    }

    /++
     +  Outputs a terminal truecolour token based on the #RRGGBB value stored in
     +  `user.colour`.
     +
     +  This is for Twitch servers that assign such values to users' messages.
     +  By catching it we can honour the setting by tinting users accordingly.
     +/
    void colourUserTruecolour(Sink)(auto ref Sink sink, const IRCUser user)
    if (isOutputRange!(Sink, char[]))
    {
        bool coloured;

        version(TwitchSupport)
        {
            if (!user.isServer && user.colour.length && plugin.printerSettings.truecolour)
            {
                import kameloso.terminal : truecolour;
                import lu.conv : numFromHex;

                int r, g, b;
                user.colour.numFromHex(r, g, b);

                if (plugin.printerSettings.normaliseTruecolour)
                {
                    sink.truecolour!(Yes.normalise)(r, g, b, bright);
                }
                else
                {
                    sink.truecolour!(No.normalise)(r, g, b, bright);
                }
                coloured = true;
            }
        }

        if (!coloured)
        {
            sink.colourWith(colourByHash(user.isServer ? user.address : user.nickname));
        }
    }

    static if (!__traits(hasMember, Sink, "data"))
    {
        scope(exit)
        {
            sink.put('\n');
        }
    }

    with (event)
    {
        void putSender()
        {
            colourUserTruecolour(sink, sender);

            if (sender.isServer)
            {
                sink.put(sender.address);
            }
            else
            {
                bool putDisplayName;

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        sender.displayName.length)
                    {
                        sink.put(sender.displayName);
                        putDisplayName = true;

                        import std.algorithm.comparison : equal;
                        import std.uni : asLowerCase;

                        if ((sender.displayName != sender.nickname) &&
                            !sender.displayName.asLowerCase.equal(sender.nickname))
                        {
                            .put!(Yes.colours)(sink, FG.default_, " <");
                            colourUserTruecolour(sink, event.sender);
                            .put!(Yes.colours)(sink, sender.nickname, FG.default_, '>');
                        }
                    }
                }

                if (!putDisplayName && sender.nickname.length)
                {
                    // Can be no-nick special: [PING] *2716423853
                    sink.put(sender.nickname);
                }

                version(TwitchSupport)
                {
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        plugin.printerSettings.twitchBadges && sender.badges.length)
                    {
                        with (IRCEvent.Type)
                        switch (type)
                        {
                        case JOIN:
                        case SELFJOIN:
                        case PART:
                        case SELFPART:
                            break;

                        default:
                            .put!(Yes.colours)(sink, bright ? Bright.badge : Dark.badge, " [");
                            if (plugin.printerSettings.abbreviatedBadges)
                            {
                                sink.abbreviateBadges(sender.badges);
                            }
                            else
                            {
                                sink.put(sender.badges);
                            }
                            sink.put(']');
                        }
                    }
                }
            }
        }

        void putTarget()
        {
            // No need to check isServer; target is never server
            .put!(Yes.colours)(sink, FG.default_, " (");
            colourUserTruecolour(sink, event.target);

            bool putDisplayName;

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    target.displayName.length)
                {
                    .put!(Yes.colours)(sink, target.displayName, FG.default_, ')');
                    putDisplayName = true;

                    import std.algorithm.comparison : equal;
                    import std.uni : asLowerCase;

                    if ((target.displayName != target.nickname) &&
                        !target.displayName.asLowerCase.equal(target.nickname))
                    {
                        sink.put(" <");
                        colourUserTruecolour(sink, event.target);
                        .put!(Yes.colours)(sink, target.nickname, FG.default_, '>');
                    }
                }
            }

            if (!putDisplayName)
            {
                .put!(Yes.colours)(sink, target.nickname, FG.default_, ')');
            }

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    plugin.printerSettings.twitchBadges && target.badges.length)
                {
                    .put!(Yes.colours)(sink, bright ? Bright.badge : Dark.badge, " [");
                    if (plugin.printerSettings.abbreviatedBadges)
                    {
                        sink.abbreviateBadges(target.badges);
                    }
                    else
                    {
                        sink.put(target.badges);
                    }
                    sink.put(']');
                }
            }
        }

        void putContent()
        {
            immutable FG contentFgBase = bright ? Bright.content : Dark.content;
            immutable FG emoteFgBase = bright ? Bright.emote : Dark.emote;

            immutable fgBase = ((event.type == IRCEvent.Type.EMOTE) ||
                (event.type == IRCEvent.Type.SELFEMOTE)) ? emoteFgBase : contentFgBase;
            immutable isEmote = (fgBase == emoteFgBase);

            sink.colourWith(fgBase);  // Always grey colon and SASL +, prepare for emote

            if (sender.isServer || sender.nickname.length)
            {
                if (isEmote)
                {
                    sink.put(' ');
                }
                else
                {
                    sink.put(`: "`);
                }

                if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
                {
                    // Twitch chat has no colours or effects, only emotes
                    content = mapEffects(content, fgBase);
                }

                version(TwitchSupport)
                {
                    if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
                    {
                        highlightEmotes(event,
                            (plugin.printerSettings.colourfulEmotes ? Yes.colourful : No.colourful),
                            (plugin.state.settings.brightTerminal ? Yes.brightTerminal : No.brightTerminal));
                    }
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case CHAN:
                case EMOTE:
                case TWITCH_SUBGIFT:
                //case SELFCHAN:
                    import kameloso.terminal : invert;

                    /// Nick was mentioned (certain)
                    bool match;
                    string inverted = content;

                    if (content.containsNickname(plugin.state.client.nickname))
                    {
                        inverted = content.invert(plugin.state.client.nickname);
                        match = true;
                    }

                    version(TwitchSupport)
                    {
                        // On Twitch, also highlight the display name alias
                        if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                            plugin.state.client.displayName.length &&  // Should always be true but check
                            (plugin.state.client.nickname != plugin.state.client.displayName) &&
                            content.containsNickname(plugin.state.client.displayName))
                        {
                            inverted = inverted.invert(plugin.state.client.displayName);
                            match = true;
                        }
                    }

                    if (!match) goto default;

                    sink.put(inverted);
                    shouldBell = bellOnMention;
                    break;

                default:
                    // Normal non-highlighting channel message
                    sink.put(content);
                    break;
                }

                import kameloso.terminal : TerminalBackground;

                // Reset the background to ward off bad backgrounds bleeding out
                sink.colourWith(fgBase, TerminalBackground.default_);
                if (!isEmote) sink.put('"');
            }
            else
            {
                // PING or ERROR likely
                sink.put(content);  // No need for indenting space
            }
        }

        .put!(Yes.colours)(sink, bright ? Timestamp.bright : Timestamp.dark, '[');

        (cast(DateTime)SysTime
            .fromUnixTime(event.time))
            .timeOfDay
            .toString(sink);

        sink.put(']');

        import lu.string : beginsWith;

        if (rawTypestring.beginsWith("ERR_") || (event.type == IRCEvent.Type.ERROR) ||
            (event.type == IRCEvent.Type.TWITCH_ERROR))
        {
            sink.colourWith(bright ? Bright.error : Dark.error);
        }
        else
        {
            if (bright)
            {
                sink.colourWith((type == IRCEvent.Type.QUERY) ? Bright.query : Bright.type);
            }
            else
            {
                sink.colourWith((type == IRCEvent.Type.QUERY) ? Dark.query : Dark.type);
            }
        }

        import std.uni : asLowerCase;

        sink.put(" [");

        if (plugin.printerSettings.uppercaseTypes) sink.put(typestring);
        else sink.put(typestring.asLowerCase);

        sink.put("] ");

        if (channel.length)
        {
            .put!(Yes.colours)(sink, bright ? Bright.channel : Dark.channel,
                '[', channel, "] ");
        }

        putSender();

        if (target.nickname.length) putTarget();

        if (content.length) putContent();

        if (aux.length)
        {
            .put!(Yes.colours)(sink, bright ? Bright.aux : Dark.aux, " (", aux, ')');
        }

        if (count != 0)
        {
            sink.colourWith(bright ? Bright.count : Dark.count);
            sink.put(" {");
            .put(sink, count);
            sink.put('}');
        }

        if (altcount != 0)
        {
            sink.colourWith(bright ? Bright.altcount : Dark.altcount);
            sink.put(" {");
            .put(sink, altcount);
            sink.put('}');
        }

        if (num > 0)
        {
            import lu.conv : toAlphaInto;

            sink.colourWith(bright ? Bright.num : Dark.num);

            //sink.formattedWrite(" (#%03d)", num);
            sink.put(" (#");
            num.toAlphaInto!(3, 3)(sink);
            sink.put(')');
        }

        if (errors.length && !plugin.printerSettings.silentErrors)
        {
            .put!(Yes.colours)(sink, bright ? Bright.error : Dark.error,
                " ! ", errors, " !");
        }

        sink.colourWith(FG.default_);  // same for bright and dark

        shouldBell = shouldBell || ((target.nickname == plugin.state.client.nickname) &&
            ((event.type == IRCEvent.Type.QUERY) ||
            (event.type == IRCEvent.Type.TWITCH_SUBGIFT)));
        shouldBell = shouldBell || (errors.length && bellOnError &&
            !plugin.printerSettings.silentErrors);

        if (shouldBell)
        {
            import kameloso.terminal : TerminalToken;
            sink.put(TerminalToken.bell);
        }
    }
}


// withoutTypePrefix
/++
 +  Slices away any type prefixes from the string of a
 +  `dialect.defs.IRCEvent.Type`.
 +
 +  Only for shared use in `formatMessageMonochrome` and
 +  `formatMessageColoured`.
 +
 +  Example:
 +  ---
 +  immutable typestring1 = "PRIVMSG".withoutTypePrefix;
 +  assert((typestring1 == "PRIVMSG"), typestring1);  // passed through
 +
 +  immutable typestring2 = "ERR_NOSUCHNICK".withoutTypePrefix;
 +  assert((typestring2 == "NOSUCHNICK"), typestring2);
 +
 +  immutable typestring3 = "RPL_LIST".withoutTypePrefix;
 +  assert((typestring3 == "LIST"), typestring3);
 +  ---
 +
 +  Params:
 +      typestring = The string form of a `dialect.defs.IRCEvent.Type`.
 +
 +  Returns:
 +      A slice of the passed `typestring`, excluding any prefixes if present.
 +/
string withoutTypePrefix(const string typestring) @safe pure nothrow @nogc @property
{
    import lu.string : beginsWith;

    if (typestring.beginsWith("RPL_") || typestring.beginsWith("ERR_"))
    {
        return typestring[4..$];
    }
    else
    {
        version(TwitchSupport)
        {
            if (typestring.beginsWith("TWITCH_"))
            {
                return typestring[7..$];
            }
        }
    }

    return typestring;  // as is
}

///
unittest
{
    {
        immutable typestring = "RPL_ENDOFMOTD";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "ENDOFMOTD"), without);
    }
    {
        immutable typestring = "ERR_CHANOPRIVSNEEDED";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "CHANOPRIVSNEEDED"), without);
    }
    version(TwitchSupport)
    {{
        immutable typestring = "TWITCH_USERSTATE";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "USERSTATE"), without);
    }}
    {
        immutable typestring = "PRIVMSG";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "PRIVMSG"), without);
    }
}


// abbreviateBadges
/++
 +  Abbreviates a string of Twitch badges, to summarise all of them instead of
 +  picking the dominant one and just displaying that. Takes an output range.
 +
 +  Most are just summarised by the first letter in the badge (lowercase), but
 +  there would be collisions (subscriber vs sub-gifter, etc), so we make some
 +  exceptions by capitalising some common ones and rewriting others. Leave as
 +  many lowercase characters open as possible for unexpected badges.
 +
 +  It's a bit more confusing this way but it's a solid fact that users often
 +  have more than one badge, and we were singling out just one.
 +
 +  Using an associative array is an alternative approach. It's faster, but uses
 +  the heap. From the documentation:
 +
 +      The following constructs may allocate memory using the garbage collector:
 +          [...]
 +          * Any insertion, removal, or lookups in an associative array
 +
 +  It would look like the following:
 +  ---
 +  version(TwitchSupport)
 +  static immutable char[string] stringBadgeMap;
 +
 +  version(TwitchSupport)
 +  shared static this()
 +  {
 +      stringBadgeMap =
 +      [
 +          "subscriber"    : 'S',
 +          "bits"          : 'C',  // cheer
 +          "sub-gifter"    : 'G',
 +          "premium"       : 'P',  // prime
 +          "turbo"         : 'T',
 +          "moderator"     : 'M',
 +          "partner"       : 'V',  // verified
 +          "vip"           : '^',  // V taken
 +          "broadcaster"   : 'B',
 +          "twitchcon2017" : '7',
 +          "twitchcon2018" : '8',
 +          "twitchconEU2019" : '9',
 +          "twitchconNA2019" : '9',
 +          "staff"         : '*',
 +          "admin"         : '+',
 +      ];
 +  }
 + ---
 +
 +  Use the string switch for now. It's still plenty fast.
 +
 +  The result is a string with the passed badges abbreviated, one character per
 +  badge, separated into minor and major badges. Minor ones are ones that end
 +  with "`_1`", which seem to be contextual to a channel's game theme, like
 +  `overwatch_league_insider_1`, `firewatch_1`, `cuphead_1`, `H1Z1_1`, `eso_1`, ...
 +
 +  Params:
 +      sink = Output range to store the abbreviated values in.
 +      badgestring = Badges from a Twitch `badges=` IRCv3 tag.
 +/
version(TwitchSupport)
void abbreviateBadges(Sink)(auto ref Sink sink, const string badgestring)
if (isOutputRange!(Sink, char[]))
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;

    Appender!(ubyte[]) minor;

    static if (__traits(hasMember, Sink, "reserve"))
    {
        sink.reserve(8);  // reserve extra for minor badges
    }

    foreach (immutable badgeAndNum; badgestring.splitter(','))
    {
        import lu.string : nom;

        string slice = badgeAndNum;
        immutable badge = slice.nom('/');

        char badgechar;

        switch (badge)
        {
        case "subscriber":
            badgechar = 'S';
            break;

        case "bits":
        case "bits-leader":
            // rewrite to the cheer it is represented as in the normal chat
            badgechar = 'C';
            break;

        case "sub-gifter":
        case "sub-gift-leader":
            badgechar = 'G';
            break;

        case "premium":
            // prime
            badgechar = 'P';
            break;

        case "turbo":
            badgechar = 'T';
            break;

        case "moderator":
            badgechar = 'M';
            break;

        case "partner":
            // verified
            badgechar = 'V';
            break;

        case "vip":
            // V is taken, no obvious second choice
            badgechar = '^';
            break;

        case "broadcaster":
            badgechar = 'B';
            break;

        case "twitchcon2017":
            badgechar = '7';
            break;

        case "twitchcon2018":
            badgechar = '8';
            break;

        case "twitchconEU2019":
        case "twitchconNA2019":
            badgechar = '9';
            break;

        case "twitchconAmsterdam2020":
            badgechar = '0';
            break;

        case "staff":
            badgechar = '*';
            break;

        case "admin":
            badgechar = '+';
            break;

        default:
            import lu.string : beginsWith;
            import std.algorithm.searching : endsWith;

            if (badge.beginsWith("bits-"))
            {
                // bits-leader
                // bits-charity
                badgechar = badge[5];
                break;
            }
            else if (badge.endsWith("_1"))
            {
                minor.put(badge[0]);
                continue;
            }

            badgechar = badge[0];
            break;
        }

        sink.put(badgechar);
    }

    if (minor.data.length)
    {
        sink.put(':');
        sink.put(minor.data);
    }
}

///
version(TwitchSupport)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable badges = "subscriber/24,bits/1000";
        sink.abbreviateBadges(badges);
        assert((sink.data == "SC"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "moderator/1,subscriber/24";
        sink.abbreviateBadges(badges);
        assert((sink.data == "MS"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "subscriber/72,premium/1,twitchcon2017/1,bits/1000";
        sink.abbreviateBadges(badges);
        assert((sink.data == "SP7C"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "broadcaster/0";
        sink.abbreviateBadges(badges);
        assert((sink.data == "B"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "harbl/42,snarbl/99,subscriber/4,bits/10000";
        sink.abbreviateBadges(badges);
        assert((sink.data == "hsSC"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "subscriber/4,H1Z1_1/1,cuphead_1/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == "S:Hc"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "H1Z1_1/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == ":H"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "bits-charity/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == "c"), sink.data);
        sink.clear();
    }
    {
        immutable badges = "bits-leader/1";
        sink.abbreviateBadges(badges);
        assert((sink.data == "C"), sink.data);
        sink.clear();
    }
}


// highlightEmotes
/++
 +  Tints emote strings and highlights Twitch emotes in a ref
 +  `dialect.defs.IRCEvent`'s `content` member.
 +
 +  Wraps `highlightEmotesImpl`.
 +
 +  Params:
 +      event = `dialect.defs.IRCEvent` whose content text to highlight.
 +      colourful = Whether or not emotes should be highlit in colours.
 +      brightTerminal = Whether or not the terminal has a bright background
 +          and colours should be adapted to suit.
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotes(ref IRCEvent event,
    const Flag!"colourful" colourful,
    const Flag!"brightTerminal" brightTerminal)
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal : colourWith;
    import lu.string : contains;
    import std.array : Appender;

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;

    if (!event.emotes.length) return;

    Appender!string sink;
    sink.reserve(event.content.length + 60);  // mostly +10

    immutable TerminalForeground highlight = brightTerminal ?
        Bright.highlight : Dark.highlight;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case EMOTE:
    case SELFEMOTE:
        if (!colourful && event.tags.contains("emote-only=1"))
        {
            // Just highlight the whole line, don't worry about resetting to fgBase
            sink.colourWith(highlight);
            sink.put(event.content);
        }
        else
        {
            // Emote but mixed text and emotes OR we're doing colorful emotes
            immutable TerminalForeground emoteFgBase = brightTerminal ?
                Bright.emote : Dark.emote;
            event.content.highlightEmotesImpl(sink, event.emotes, highlight,
                emoteFgBase, colourful, brightTerminal);
        }
        break;

    case CHAN:
    case SELFCHAN:
    case TWITCH_RITUAL:
        if (!colourful && event.tags.contains("emote-only=1"))
        {
            // Emote only channel message, treat the same as an emote-only emote
            goto case EMOTE;
        }
        else
        {
            // Normal content, normal text, normal emotes
            immutable TerminalForeground contentFgBase = brightTerminal ?
                Bright.content : Dark.content;
            event.content.highlightEmotesImpl(sink, event.emotes, highlight,
                contentFgBase, colourful, brightTerminal);
        }
        break;

    default:
        return;
    }

    event.content = sink.data;
}


// highlightEmotesImpl
/++
 +  Highlights Twitch emotes in the chat by tinting them a different colour,
 +  saving the results into a passed output range sink.
 +
 +  Params:
 +      line = Content line whose containing emotes should be highlit.
 +      sink = Output range to put the results into.
 +      emotes = The list of emotes and their positions as divined from the
 +          IRCv3 tags of an event.
 +      pre = Terminal foreground tint to colour the emotes with.
 +      post = Terminal foreground tint to reset to after colouring an emote.
 +      colourful = Whether or not emotes should be highlit in colours.
 +      brightTerminal = Whether or not the terminal has a bright background
 +          and colours should be adapted to suit.
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotesImpl(Sink)(const string line, auto ref Sink sink,
    const string emotes, const TerminalForeground pre, const TerminalForeground post,
    const Flag!"colourful" colourful,
    const Flag!"brightTerminal" brightTerminal)
if (isOutputRange!(Sink, char[]))
{
    import std.algorithm.iteration : splitter;
    import std.conv : to;

    struct Highlight
    {
        string id;
        size_t start;
        size_t end;
    }

    // max encountered emotes so far: 46
    // Severely pathological let's-crash-the-bot case: max possible ~161 emotes
    // That is a standard PRIVMSG line with ":) " repeated until 512 chars.
    // Highlight[162].sizeof == 2592, manageable stack size.
    enum maxHighlights = 162;

    Highlight[maxHighlights] highlights;

    size_t numHighlights;
    size_t pos;

    foreach (emote; emotes.splitter('/'))
    {
        import lu.string : nom;

        immutable emoteID = emote.nom(':');

        foreach (immutable location; emote.splitter(','))
        {
            import std.string : indexOf;

            if (numHighlights == maxHighlights) break;  // too many, don't go out of bounds.

            immutable dashPos = location.indexOf('-');
            immutable start = location[0..dashPos].to!size_t;
            immutable end = location[dashPos+1..$].to!size_t + 1;  // inclusive

            highlights[numHighlights++] = Highlight(emoteID, start, end);
        }
    }

    import std.algorithm.sorting : sort;
    highlights[0..numHighlights].sort!((a,b) => a.start < b.start)();

    // We need a dstring since we're slicing something that isn't necessarily ASCII
    // Without this highlights become offset a few characters depending on the text
    immutable dline = line.to!dstring;

    foreach (immutable i; 0..numHighlights)
    {
        import kameloso.terminal : colourByHash, colourWith;

        immutable id = highlights[i].id;
        immutable start = highlights[i].start;
        immutable end = highlights[i].end;

        sink.put(dline[pos..start]);
        sink.colourWith(colourful ? colourByHash(id, brightTerminal) : pre);
        sink.put(dline[start..end]);
        sink.colourWith(post);

        pos = end;
    }

    // Add the remaining tail from after the last emote
    sink.put(dline[pos..$]);
}

///
version(Colours)
version(TwitchSupport)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "NOOOOOO \033[97mcamillsCry\033[39m " ~
            "\033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m " ~
            "\033[97mFortOne\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "@mugs123 \033[97mcohhWow\033[39m \033[97mcohhBoop\033[39m " ~
            "\033[97mcohhBoop\033[39m \033[97mcohhBoop\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "12345:81-91,93-103";
        immutable line = "Link Amazon Prime to your Twitch account and get a " ~
            "FREE SUBSCRIPTION every month courageHYPE courageHYPE " ~
            "twitch.amazon.com/prime | Click subscribe now to check if a " ~
            "free prime sub is available to use!";
        immutable highlitLine = "Link Amazon Prime to your Twitch account and get a " ~
            "FREE SUBSCRIPTION every month \033[97mcourageHYPE\033[39m \033[97mcourageHYPE\033[39m " ~
            "twitch.amazon.com/prime | Click subscribe now to check if a " ~
            "free prime sub is available to use!";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == highlitLine), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "高所恐怖症 \033[34mLUL\033[39m なにぬねの " ~
            "\033[34mLUL\033[39m \033[91m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "Moody the god \033[37mpownyFine\033[39m \033[96mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[93mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "NOOOOOO \033[95mcamillsCry\033[39m " ~
            "\033[95mcamillsCry\033[39m \033[95mcamillsCry\033[39m"), sink.data);
    }
}


// containsNickname
/++
 +  Searches a string for a substring that isn't surrounded by characters that
 +  can be part of a nickname. This can detect a nickname in a string without
 +  getting false positives from similar nicknames.
 +
 +  Uses `std.string.indexOf` internally with hopes of being more resilient to
 +  weird UTF-8.
 +
 +  Params:
 +      haystack = A string to search for the substring nickname.
 +      needle = The nickname substring to find in `haystack`.
 +
 +  Returns:
 +      True if `haystack` contains `needle` in such a way that it is guaranteed
 +      to not be a different nickname.
 +/
bool containsNickname(const string haystack, const string needle) pure nothrow @nogc
in (needle.length, "Tried to determine whether an empty nickname was in a string")
do
{
    import dialect.common : isValidNicknameCharacter;
    import std.string : indexOf;

    if ((haystack.length == needle.length) && (haystack == needle)) return true;

    immutable pos = haystack.indexOf(needle);
    if (pos == -1) return false;

    // Allow for a prepended @, since @mention is commonplace
    if ((pos > 0) && (haystack[pos-1].isValidNicknameCharacter ||
        (haystack[pos-1] == '.') ||  // URLs
        (haystack[pos-1] == '/')) &&  // likewise
        (haystack[pos-1] != '@')) return false;

    immutable end = pos + needle.length;

    if (end > haystack.length)
    {
        return false;
    }
    else if (end == haystack.length)
    {
        return true;
    }

    return !haystack[end].isValidNicknameCharacter;
}

///
unittest
{
    assert("kameloso".containsNickname("kameloso"));
    assert(" kameloso ".containsNickname("kameloso"));
    assert(!"kam".containsNickname("kameloso"));
    assert(!"kameloso^".containsNickname("kameloso"));
    assert(!string.init.containsNickname("kameloso"));
    //assert(!"kameloso".containsNickname(""));  // For now let this be false.
    assert("@kameloso".containsNickname("kameloso"));
    assert(!"www.kameloso.com".containsNickname("kameloso"));
    assert("kameloso.".containsNickname("kameloso"));
    assert("kameloso/".containsNickname("kameloso"));
    assert(!"/kameloso/".containsNickname("kameloso"));
}