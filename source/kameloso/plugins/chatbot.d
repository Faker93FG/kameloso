module kameloso.plugins.chatbot;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : ThreadMessage, logger;

import std.concurrency : send;
import std.json : JSONValue;

import std.stdio;

private:


// ChatbotSettings
/++
 +  Settings for a chatbot.
 +
 +  ------------
 +  struct ChatbotSettings
 +  {
 +      string quotesFile = "quotes.json";
 +      bool eightball = true;
 +      bool quotes = true;
 +      bool say = true;
 +  }
 +  ------------
 +/
struct ChatbotSettings
{
    string quotesFile = "quotes.json";
    bool eightball = true;
    bool quotes = true;
    bool say = true;
}

/// All Chatbot plugin settings gathered
@Settings ChatbotSettings chatbotSettings;


// quotes
/++
 +  The in-memory JSON storage of all user quotes.
 +
 +  It is in the JSON form of `string[][string]`, where the first key is the
 +  nickname of a user.
 +/
JSONValue quotes;


// getQuote
/++
 +  Fetches a quote for the specified nickname from the in-memory JSON storage.
 +
 +  Params:
 +      nickname = nickname of the user to fetch quotes for.
 +
 +  Returns:
 +      a random quote string. If no quote is available it returns an empty
 +      string instead.
 +/
string getQuote(const string nickname)
{
    if (const arr = nickname in quotes)
    {
        import std.random : uniform;

        return arr.array[uniform(0, (*arr).array.length)].str;
    }
    else
    {
        return string.init;
    }
}


// addQuote
/++
 +  Adds a quote to the in-memory JSON storage.
 +
 +  It does not save it to disk; this has to be done separately.
 +
 +  Params:
 +      nickname = nickname of the quoted user.
 +      line = the quote itself.
 +/
void addQuote(const string nickname, const string line)
{
    if (nickname in quotes)
    {
        quotes[nickname].array ~= JSONValue(line);
    }
    else
    {
        // No quotes for nickname
        quotes.object[nickname] = JSONValue([ line ]);
    }
}


// saveQuotes
/++
 +  Saves the JSON quote list to disk.
 +
 +  This should be done whenever a new quote is added to the database.
 +
 +  Params:
 +      filename = filename of the JSON storage.
 +/
void saveQuotes(const string filename)
{
    import std.ascii : newline;
    import std.file  : exists, isFile, remove;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto file = File(filename, "a");

    file.write(quotes.toPrettyString);
    file.write(newline);
}


// loadQuotes
/++
 +  Loads JSON quote list from disk.
 +
 +  This only needs to be done at plugin (re-)initialisation.
 +
 +  Params:
 +      filename = filename of the JSON storage.
 +/
JSONValue loadQuotes(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.json   : parseJSON;

    if (!filename.exists || !filename.isFile)
    {
        //logger.info(filename, " does not exist or is not a file!");
        JSONValue newJSON;
        newJSON.object = null;
        return newJSON;
    }

    immutable wholeFile = readText(filename);
    return parseJSON(wholeFile);
}


// onCommandSay
/++
 +  Repeats text to the channel the event was sent to.
 +
 +  If it was sent in a query, respond in a private message in kind.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix("say")
@Prefix(NickPolicy.required, "say")
@Prefix(NickPolicy.required, "säg")
void onCommandSay(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!chatbotSettings.say) return;

    import std.format : format;

    if (!event.content.length)
    {
        logger.error("No text to send...");
        return;
    }

    immutable target = (event.channel.length) ? event.channel : event.sender.nickname;

    plugin.state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :%s".format(target, event.content));
}


// onCommand8ball
/++
 +  Implements 8ball.
 +
 +  Randomises a response from the table kameloso.constants.eightballAnswers
 +  and sends it back to the channel in which the triggering event happened,
 +  or in a query if it was a private message.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix("8ball")
@Prefix(NickPolicy.required, "8ball")
void onCommand8ball(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!chatbotSettings.eightball) return;

    import std.format : format;
    import std.random : uniform;

    // Fetched from wikipedia
    static immutable string[20] eightballAnswers =
    [
        "It is certain",
        "It is decidedly so",
        "Without a doubt",
        "Yes, definitely",
        "You may rely on it",
        "As I see it, yes",
        "Most likely",
        "Outlook good",
        "Yes",
        "Signs point to yes",
        "Reply hazy try again",
        "Ask again later",
        "Better not tell you now",
        "Cannot predict now",
        "Concentrate and ask again",
        "Don't count on it",
        "My reply is no",
        "My sources say no",
        "Outlook not so good",
        "Very doubtful",
    ];

    immutable reply = eightballAnswers[uniform(0, eightballAnswers.length)];
    immutable target = (event.channel.length) ? event.channel : event.sender.nickname;

    plugin.state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :%s".format(target, reply));
}


// onCommandQuote
/++
 +  Fetches and repeats a random quote of a supplied nickname.
 +
 +  The quote is read from in-memory JSON storage, and it is sent to the
 +  channel the triggering event occured in.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix("quote")
@Prefix(NickPolicy.required, "quote")
void onCommandQuote(ChatbotPlugin plugin, const IRCEvent event)
{
    import std.json : JSONException;

    if (!chatbotSettings.quotes) return;

    import kameloso.irc : isValidNickname, stripModeSign;
    import std.format : format;
    import std.string : strip;

    // stripModeSign to allow for quotes from @nickname and +dudebro
    immutable nickname = event.content.strip.stripModeSign();

    if (!nickname.isValidNickname(plugin.state.bot.server))
    {
        logger.errorf("Invalid nickname: '%s'", nickname);
        return;
    }

    try
    {
        immutable quote = nickname.getQuote();
        immutable target = event.channel.length ?
            event.channel : event.sender.nickname;

        if (quote.length)
        {
            plugin.state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :%s | %s".format(target, nickname, quote));
        }
        else
        {
            plugin.state.mainThread.send(ThreadMessage.Sendline(),
                "PRIVMSG %s :No quote on record for %s"
                .format(target, nickname));
        }
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not quote '%s': %s", nickname, e.msg);
    }
}


// onCommandAddQuote
/++
 +  Creates a new quote.
 +
 +  It is added to the in-memory JSON storage which then gets immediately
 +  written to disk.
 +
 +  Params:
 +      event = The triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@Prefix("addquote")
@Prefix(NickPolicy.required, "addquote")
void onCommanAddQuote(ChatbotPlugin plugin, const IRCEvent event)
{
    if (!chatbotSettings.quotes) return;

    import kameloso.irc : stripModeSign;
    import kameloso.string : nom;
    import std.format : format;
    import std.json : JSONException;

    string slice = event.content;  // need mutable
    immutable nickname = slice.nom!(Yes.decode)(' ').stripModeSign();

    if (!nickname.length || !slice.length) return;

    try
    {
        nickname.addQuote(slice);
        saveQuotes(chatbotSettings.quotesFile);

        immutable target = (event.channel.length) ?
            event.channel : event.sender.nickname;

        plugin.state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :Quote for %s saved (%d on record)"
            .format(target, nickname, quotes[nickname].array.length));
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not add quote for '%s': %s", nickname, e.msg);
    }
}


// onCommandPrintQuotes
/++
 +  Prints the in-memory quotes JSON storage to the local terminal.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printquotes")
void onCommandPrintQuotes()
{
    if (!chatbotSettings.quotes) return;

    writeln(quotes.toPrettyString);
}


// onCommandReloadQuotes
/++
 +  Reloads the JSON quotes from disk.
 +
 +  This is both for debugging purposes and to simply allow for live manual
 +  editing of quotes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "reloadquotes")
void onCommandReloadQuotes()
{
    if (!chatbotSettings.quotes) return;

    logger.log("Reloading quotes");
    quotes = loadQuotes(chatbotSettings.quotesFile);
}


// onEndOfMotd
/++
 +  Initialises the Chatbot plugin. Loads the quotes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd()
{
    logger.log("Initialising quotes ...");
    quotes = loadQuotes(chatbotSettings.quotesFile);
}


mixin BasicEventHandlers;

public:


// Chatbot
/++
 +  Chatbot plugin to provide common chat functionality.
 +
 +  Administrative actions have been broken out into a plugin of its own.
 +/
final class ChatbotPlugin : IRCPlugin
{
    mixin IRCPluginImpl;
}
