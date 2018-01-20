/++
 +  The Notes plugin allows for storing notes to offline users, to be replayed
 +  when they next log in.
 +
 +  It has a few commands:
 +
 +  `note` | `addnote`<br>
 +  `fakejoin`<br>
 +  `fakechan`<br>
 +  `printnotes`<br>
 +  `reloadnotes`<br>
 +
 +  It is vey optional.
 +/
module kameloso.plugins.notes;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;
import kameloso.messaging;

import std.json : JSONValue;

private:


// NotesSettings
/++
 +  Notes plugin settings.
 +/
struct NotesSettings
{
    /// Filename of file to save the notes to.
    string notesFile = "notes.json";

    /// Whether or not to replay notes when the user joins.
    bool replayOnJoin = true;

    /// Whether or not to replay notes when the bot joins.
    bool replayOnSelfjoin = false;
}


// onReplayEvent
/++
 +  Sends notes queued for a user to a channel when they speak up, or when they
 +  join iff the `NotesSettings.replayOnJoin` setting is set.
 +
 +  Nothing is sent if no notes are stored.
 +/
@(Chainable)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.EMOTE)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onReplayEvent(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.string : timeSince;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.json : JSONException;

    if ((event.type == IRCEvent.Type.JOIN) && !plugin.notesSettings.replayOnJoin)
    {
        // It's a JOIN and we shouldn't replay on those
        return;
    }

    try
    {
        const noteArray = plugin.getNotes(event.sender.nickname);

        with (plugin.state)
        {
            if (!noteArray.length) return;
            else if (noteArray.length == 1)
            {
                const note = noteArray[0];
                immutable timestamp = (Clock.currTime - note.when).timeSince;

                plugin.chan(event.channel, "%s! %s left note %s ago: %s"
                    .format(event.sender.nickname, note.sender, timestamp, note.line));
            }
            else
            {
                plugin.chan(event.channel, "%s! You have %d notes."
                    .format(event.sender.nickname, noteArray.length));

                foreach (const note; noteArray)
                {
                    immutable timestamp = (Clock.currTime - note.when).timeSince;

                    plugin.chan(event.channel, "%s left note %s ago: %s"
                        .format(note.sender, timestamp, note.line));
                }
            }
        }

        plugin.clearNotes(event.sender.nickname);
    }
    catch (const JSONException e)
    {
        logger.errorf("Could not fetch and/or replay notes for '%s': %s",
            event.sender.nickname, e.msg);
    }
}


// onNames
/++
 +  Sends notes to a channel upon joining it.
 +
 +  Only reacting to others joining would mean someone never leaving would never
 +  get notes. This may be extended to trigger when they say something, too.
 +/
@(IRCEvent.Type.RPL_NAMREPLY)
void onNames(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.irc : stripModesign;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : Clock;

    if (!plugin.notesSettings.replayOnSelfjoin) return;

    if (!plugin.state.bot.homes.canFind(event.channel)) return;

    foreach (immutable prefixedNickname; event.content.splitter)
    {
        string nickname = prefixedNickname;
        plugin.state.bot.server.stripModesign(nickname);
        if (nickname == plugin.state.bot.nickname) continue;

        IRCEvent fakeEvent;

        with (fakeEvent)
        {
            type = IRCEvent.Type.CHAN;
            sender.nickname = nickname;
            channel = event.channel;
            time = Clock.currTime.toUnixTime;
        }

        plugin.onReplayEvent(fakeEvent);
    }
}


// onCommandAddNote
/++
 +  Adds a note to the in-memory storage, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("addnote")
@BotCommand("note")
@BotCommand(NickPolicy.required, "addnote")
@BotCommand(NickPolicy.required, "note")
@Description("Adds a note and saves it to disk.")
void onCommandAddNote(NotesPlugin plugin, const IRCEvent event)
{
    import std.format : format, formattedRead;
    import std.json : JSONException;

    string nickname, line;

    // formattedRead advances a slice so we need a mutable copy of event.content
    string content = event.content;
    immutable hits = content.formattedRead("%s %s", nickname, line);

    if (hits != 2) return;

    try
    {
        plugin.addNote(nickname, event.sender.nickname, line);
        plugin.chan(event.channel, "Note added.");

        plugin.saveNotes(plugin.notesSettings.notesFile);
    }
    catch (const JSONException e)
    {
        logger.error("Failed to add note: ", e.msg);
    }
}


// onCommandPrintNotes
/++
 +  Prints saved notes in JSON form to the local terminal.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printnotes")
@Description("[debug] Prints saved notes to the local terminal.")
void onCommandPrintNotes(NotesPlugin plugin)
{
    import std.stdio : stdout, writeln;

    writeln(plugin.notes.toPrettyString);
    version(Cygwin_) stdout.flush();
}


// onCommandReloadQuotes
/++
 +  Reloads quotes from disk, overwriting the in-memory storage.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "reloadnotes")
@Description("[debug] Reloads quotes from disk.")
void onCommandReloadQuotes(NotesPlugin plugin)
{
    logger.log("Reloading notes");
    plugin.notes = loadNotes(plugin.notesSettings.notesFile);
}


// onCommandFakeJoin
/++
 +  Fakes the supplied user joining a channel.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "fakechan")
@BotCommand(NickPolicy.required, "fakejoin")
@Description("[debug] Fakes a user being active in a channel.")
void onCommandFakejoin(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.string : has, nom;
    import std.typecons : Yes;

    logger.info("Faking an event");

    IRCEvent newEvent = event;
    newEvent.type = IRCEvent.Type.CHAN;
    string nickname = event.content;

    if (nickname.has!(Yes.decode)(' '))
    {
        // contains more than one word
        newEvent.sender.nickname = nickname.nom!(Yes.decode)(' ');
    }
    else
    {
        newEvent.sender.nickname = event.content;
    }

    return plugin.onReplayEvent(newEvent);  // or onEvent?
}


// getNotes
/++
 +  Fetches the notes for a specified user, from the in-memory JSON storage.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +      nickname = The user whose notes to fetch.
 +
 +  Returns:
 +      a Voldemort `Note[]` array, where `Note` is a struct containing a note
 +      and metadata thereto.
 +/
auto getNotes(NotesPlugin plugin, const string nickname)
{
    import std.datetime.systime : SysTime;
    import std.json : JSON_TYPE;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    if (const arr = nickname in plugin.notes)
    {
        if (arr.type != JSON_TYPE.ARRAY)
        {
            logger.warningf("Invalid notes list for %s (type is %s)",
                        nickname, arr.type);

            plugin.clearNotes(nickname);

            return noteArray;
        }

        noteArray.length = arr.array.length;

        foreach (i, note; arr.array)
        {
            noteArray[i].sender = note["sender"].str;
            noteArray[i].line = note["line"].str;
            noteArray[i].when = SysTime.fromUnixTime(note["when"].integer);
        }
    }

    return noteArray;
}


// clearNotes
/++
 +  Clears the note storage of any notes pertaining to the specified user, then
 +  saves it to disk.
 +
 +  Params:
 +      plugins = Current `NotesPlugin`.
 +      nickname = Nickname whose notes to clear.
 +/
void clearNotes(NotesPlugin plugin, const string nickname)
{
    import std.file : FileException;
    import std.exception : ErrnoException;
    import std.json : JSONException;

    try
    {
        if (nickname in plugin.notes)
        {
            logger.log("Clearing stored notes for ", nickname);
            plugin.notes.object.remove(nickname);
            plugin.saveNotes(plugin.notesSettings.notesFile);
        }
    }
    catch (const JSONException e)
    {
        logger.error("Failed to clear notes: ", e.msg);
    }
    catch (const FileException e)
    {
        logger.error("Failed to save notes: ", e.msg);
    }
    catch (const ErrnoException e)
    {
        logger.error("Failed to open/close notes file: ", e.msg);
    }
}


// addNote
/++
 +  Creates a note and saves it in the in-memory JSON storage.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +      nickname = Nickname for whom the note is meant.
 +      sender = Originating user who places the note.
 +      line = Note text.
 +/
void addNote(NotesPlugin plugin, const string nickname, const string sender,
    const string line)
{
    import std.datetime.systime : Clock;
    import std.json : JSON_TYPE;

    if (!line.length)
    {
        logger.error("No message to create note from");
        return;
    }

    // "when" is long so can't construct a single AA and assign it in one go
    // (it wouldn't be string[string] then)
    auto senderAndLine =
    [
        "sender" : sender,
        "line"   : line,
        //"when" : Clock.currTime.toUnixTime,
    ];

    auto asJSON = JSONValue(senderAndLine);
    asJSON["when"] = Clock.currTime.toUnixTime;  // workaround to the above

    auto nicknote = nickname in plugin.notes;

    if (nicknote && (nicknote.type == JSON_TYPE.ARRAY))
    {
        plugin.notes[nickname].array ~= asJSON;
    }
    else
    {
        plugin.notes[nickname] = [ asJSON ];
    }
}


// saveNotes
/++
 +  Saves all notes to disk.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +      filename = Filename of file to save to.
 +/
void saveNotes(NotesPlugin plugin, const string filename)
{
    import std.file : exists, isFile;
    import std.stdio : File, write, writeln;

    auto file = File(filename, "w");

    file.write(plugin.notes.toPrettyString);
    file.writeln();
}


// loadNotes
/++
 +  Loads notes from disk into the in-memory storage.
 +
 +  Params:
 +      filename = Filename of file to read from.
 +
 +  Returns:
 +      A JSON array in the form of `Note[][string]`, where `Note[]` is an
 +      array of Voldemort `Note`s (from `getNotes`), keyed by nickname strings.
 +
 +/
JSONValue loadNotes(const string filename)
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


// onEndOfMotd
/++
 +  Initialises the Notes plugin. Loads the notes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(NotesPlugin plugin)
{
    plugin.notes = loadNotes(plugin.notesSettings.notesFile);
}


mixin UserAwareness;

public:


// NotesPlugin
/++
 +  The Notes plugin, which allows people to leave messages to eachother,
 +  for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
    /// All Notes plugin settings gathered
    @Settings NotesSettings notesSettings;

    // notes
    /++
    +  The in-memory JSON storage of all stored notes.
    +
    +  It is in the JSON form of `string[][string]`, where the first key is
    +  a nickname.
    +/
    JSONValue notes;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}
