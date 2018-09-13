/++
 +  Basic command-line argument-handling.
 +/
module kameloso.getopt;

import kameloso.common : CoreSettings, Client, Next;
import kameloso.ircdefs : IRCBot;
import std.typecons : Flag, No, Yes;

@safe:

private:


// meldSettingsFromFile
/++
 +  Read `kameloso.common.CoreSettings` and `kameloso.ircdefs.IRCBot` from file
 +  into temporaries, then meld them into the real ones, into which the
 +  command-line arguments will have been applied.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +  CoreSettings settings;
 +
 +  meldSettingsFromFile(bot, settings);
 +  ---
 +
 +  Params:
 +      bot = Reference `kameloso.ircdefs.IRCBot` to apply changes to.
 +      setttings = Reference `kameloso.common.CoreSettings` to apply changes
 +          to.
 +/
void meldSettingsFromFile(ref IRCBot bot, ref CoreSettings settings)
{
    import kameloso.config : readConfigInto;
    import kameloso.meld : MeldingStrategy, meldInto;

    IRCBot tempBot;
    CoreSettings tempSettings;

    // These arguments are by reference.
    // 1. Read arguments into bot
    // 2. Read settings into temporary bot
    // 3. Meld arguments *into* temporary bot, overwriting
    // 4. Inherit temporary bot into bot
    settings.configFile.readConfigInto(tempBot, tempBot.server, tempSettings);

    bot.meldInto!(MeldingStrategy.aggressive)(tempBot);
    settings.meldInto!(MeldingStrategy.aggressive)(tempSettings);

    bot = tempBot;
    settings = tempSettings;
}


// ajustGetopt
/++
 +  Adjust values set by getopt, by looking for setting strings in the `args`
 +  `string[]` and manually overriding melded values with them.
 +
 +  The way we meld settings is weak against false settings when they are also
 +  the default values of a member. There's no way to tell apart an unset bool
 +  an unset bool from a false one. They will be overwritten by any true value
 +  from the configuration file.
 +
 +  As such, manually parse a backup `args` and look for some passed strings,
 +  then override the variable that was set thus accordingly.
 +
 +  Params:
 +      args = Arguments passed to the program upon invocation.
 +      option = String option in long `--long` or short `-s` form, including
 +          dashes, with an equals sign between option name and value if
 +          applicable (in all cases except bools).
 +      rest = Remaining `args` and `option` s to call recursively.
 +/
void adjustGetopt(T, Rest...)(const string[] args, const string option, T* ptr, Rest rest)
{
    import kameloso.string : beginsWith, contains, nom;
    import std.algorithm.iteration : filter;

    static assert((!Rest.length || (Rest.length % 2 == 0)),
        "adjustGetopt must be called with string option, value pointer pairs");

    foreach (immutable arg; args.filter!(word => word.beginsWith(option)))
    {
        string slice = arg;  // mutable

        if (arg.contains('='))
        {
            import std.conv : to;

            immutable realWord = slice.nom('=');
            if (realWord != option) continue;
            *ptr = slice.to!T;
        }
        else static if (is(T == bool))
        {
            if (arg != option) continue;
            *ptr = true;
        }
        else
        {
            import std.getopt : GetOptException;
            import std.format : format;
            throw new GetOptException("No %s value passed to %s".format(T.stringof, option));
        }
    }

    static if (rest.length)
    {
        return adjustGetopt(args, rest);
    }
}

///
unittest
{
    string[] args =
    [
        "./kameloso", "--monochrome",
        "--server=irc.freenode.net",
        //"--nickname", "kameloso"  // Not supported under the current design
    ];

    struct S
    {
        bool monochrome;
        string server;
        string nickname;
    }

    S s;

    args.adjustGetopt(
        //"--nickname", &s.nickname,
        "--server", &s.server,
        "--monochrome", &s.monochrome,
    );

    assert(s.monochrome);
    assert((s.server == "irc.freenode.net"), s.server);
    //assert((s.nickname == "kameloso"), s.nickname);
}


public:


// handleGetopt
/++
 +  Read command-line options and merge them with those in the configuration
 +  file.
 +
 +  The priority of options then becomes getopt over config file over hardcoded
 +  defaults.
 +
 +  Example:
 +  ---
 +  Client client;
 +  Next next = client.handleGetopt(args);
 +
 +  if (next == Next.returnSuccess) return 0;
 +  // ...
 +  ---
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      args = The `string[]` args the program was called with.
 +      customSettings = Refernce array of custom settings to apply on top of
 +          the settings read from the configuration file.
 +
 +  Returns:
 +      `Next.continue_` or `Next.returnSuccess` depending on whether the
 +      arguments chosen mean the program should proceed or not.
 +/
Next handleGetopt(ref Client client, string[] args, ref string[] customSettings) @system
{
    import kameloso.bash : BashForeground;
    import kameloso.common : initLogger, printObjects, printVersionInfo, settings;
    import std.format : format;
    import std.getopt;
    import std.stdio : stdout, writeln;

    version(Cygwin_)
    scope(exit) stdout.flush();

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldGenerateAsserts;
    bool shouldAppendChannels;

    string[] inputChannels;
    string[] inputHomes;

    debug
    {
        enum genDescription = "[DEBUG] Parse an IRC event string and generate an assert block";
    }
    else
    {
        enum genDescription = "(Unavailable in non-debug builds)";
    }

    immutable argsBackup = args.idup;

    arraySep = ",";

    with (client)
    with (client.parser)
    {
        auto results = args.getopt(
            config.caseSensitive,
            config.bundling,
            "n|nickname",   "Bot nickname", &bot.nickname,
            "s|server",     "Server address", &bot.server.address,
            "P|port",       "Server port", &bot.server.port,
            "6|ipv6",       "Use IPv6 when available", &settings.ipv6,
            "A|account",    "Services account login name, if applicable", &bot.authLogin,
            "auth",         &bot.authLogin,
            "p|password",   "Services account password", &bot.authPassword,
            "authpassword", &bot.authPassword,
            "pass",         "Registration password (not auth or services)", &bot.pass,
            "admins",       "Services accounts of the bot's administrators", &bot.admins,
            "H|homes",      "Home channels to operate in, comma-separated " ~
                            "(remember to escape or enquote the octothorpe #s!)", &inputHomes,
            "C|channels",   "Non-home channels to idle in, comma-separated (ditto)", &inputChannels,
            "a",            "Append input homes and channels instead of overriding", &shouldAppendChannels,
            "hideOutgoing", "Hide outgoing messages", &settings.hideOutgoing,
            "hide",         &settings.hideOutgoing,
            "settings",     "Show all plugins' settings", &shouldShowSettings,
            "show",         &shouldShowSettings,
            "bright",       "Bright terminal colour setting", &settings.brightTerminal,
            "brightTerminal", &settings.brightTerminal,
            "monochrome",   "Use monochrome output", &settings.monochrome,
            "set",          "Manually change a setting (--set plugin.option=setting)", &customSettings,
            "asserts",      genDescription, &shouldGenerateAsserts,
            "gen",          &shouldGenerateAsserts,
            "c|config",     "Specify a different configuration file [%s]"
                                .format(settings.configFile), &settings.configFile,
            "r|resourceDir","Specify a different resource directory [%s]"
                                .format(settings.resourceDirectory),
                                &settings.resourceDirectory,
            "w|writeconfig","Write configuration to file", &shouldWriteConfig,
            "writeconf",    &shouldWriteConfig,
            "init",         &shouldWriteConfig,
            "version",      "Show version information", &shouldShowVersion,
        );

        // 1. Populate `bot` and `settings` with getopt (above)
        // 2. Manuallly adjust members `monochrome` and `brightTerminal`
        // 3. Reinitialise the logger with new settings
        meldSettingsFromFile(bot, settings);
        adjustGetopt(argsBackup,
            "--bright", &settings.brightTerminal,
            "--brightTerminal", &settings.brightTerminal,
            "--monochrome", &settings.monochrome,
        );
        initLogger(settings.monochrome, settings.brightTerminal);

        // 4. Give common.d a copy of `settings` for `printObject`
        static import kameloso.common;
        kameloso.common.settings = settings;

        // 5. Manually override or append channels, depending on `shouldAppendChannels`
        if (shouldAppendChannels)
        {
            if (inputHomes.length) bot.homes ~= inputHomes;
            if (inputChannels.length) bot.channels ~= inputChannels;
        }
        else
        {
            if (inputHomes.length) bot.homes = inputHomes;
            if (inputChannels.length) bot.channels = inputChannels;
        }

        // 6. Clear entries that are dashes
        import kameloso.objmanip : zeroMembers;
        zeroMembers!"-"(bot);

        // 7. `bot` finished; inherit into `client`
        client.parser.bot = bot;

        if (results.helpWanted)
        {
            // --help|-h was passed; show the help table and quit

            BashForeground headerTint = BashForeground.default_;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    headerTint = settings.brightTerminal ?
                        BashForeground.black : BashForeground.white;
                }
            }

            printVersionInfo(headerTint);
            writeln();

            string headline = "Command-line arguments available:\n";

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.bash : colour;

                    immutable headlineTint = settings.brightTerminal ?
                        BashForeground.green : BashForeground.lightgreen;
                    headline = headline.colour(headlineTint);
                }
            }

            defaultGetoptPrinter(headline, results.options);
            writeln();
            return Next.returnSuccess;
        }

        if (shouldShowVersion)
        {
            // --version was passed; show info and quit
            printVersionInfo();
            return Next.returnSuccess;
        }

        if (shouldWriteConfig)
        {
            import kameloso.common : logger, writeConfigurationFile;

            // --writeconfig was passed; write configuration to file and quit

            BashForeground bannertint;
            string infotint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.bash : colour;
                    import kameloso.logger : KamelosoLogger;
                    import std.experimental.logger : LogLevel;

                    bannertint = settings.brightTerminal ?
                        BashForeground.black : BashForeground.white;

                    infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                }
            }

            printVersionInfo(bannertint);
            writeln();

            // If we don't initialise the plugins there'll be no plugins array
            initPlugins(customSettings);

            client.writeConfigurationFile(settings.configFile);

            // Reload saved file
            meldSettingsFromFile(bot, settings);

            printObjects(bot, bot.server, settings);

            logger.logf("Configuration written to %s%s", infotint, settings.configFile);

            if (!bot.admins.length && !bot.homes.length)
            {
                import kameloso.common : complainAboutIncompleteConfiguration;
                logger.log("Edit it and make sure it has entries for at least one of the following:");
                complainAboutIncompleteConfiguration();
            }

            return Next.returnSuccess;
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            printVersionInfo(BashForeground.white);
            writeln();

            printObjects!(No.printAll)(bot, bot.server, settings);

            initPlugins(customSettings);

            foreach (plugin; plugins) plugin.printSettings();

            return Next.returnSuccess;
        }

        debug
        if (shouldGenerateAsserts)
        {
            import kameloso.common : logger, printObject;
            import kameloso.debugging : generateAsserts;
            import kameloso.irc : IRCParseException;

            // --gen|--generate was passed, enter assert generation
            try client.generateAsserts();
            catch (const IRCParseException e)
            {
                logger.error("IRC Parse Exception: ", e.msg);
                printObject(e.event);
            }

            return Next.returnSuccess;
        }

        return Next.continue_;
    }
}
