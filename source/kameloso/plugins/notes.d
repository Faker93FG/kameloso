/++
 +  The Notes plugin allows for storing notes to offline users, to be replayed
 +  when they next log in.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#notes
 +/
module kameloso.plugins.notes;

version(WithPlugins):
version(WithNotesPlugin):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.common;
import kameloso.irccolours : ircBold, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// NotesSettings
/++
 +  Notes plugin settings.
 +/
struct NotesSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
}


// onReplayEvent
/++
 +  Sends notes queued for a user to a channel when they join or show activity.
 +  Private notes are also sent, when some exist.
 +
 +  Nothing is sent if no notes are stored.
 +/
@(Chainable)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.EMOTE)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onReplayEvent(NotesPlugin plugin, const IRCEvent event)
{
    import kameloso.common : timeSince;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.json : JSONException;
    import std.range : only;
    import std.uni : toLower;

    foreach (immutable channel; only(event.channel, string.init))
    {
        try
        {
            immutable lowerNickname = event.sender.nickname.toLower;
            const noteArray = plugin.getNotes(channel, lowerNickname);

            if (!noteArray.length) continue;

            immutable senderName = nameOf(event.sender);
            immutable currTime = Clock.currTime;

            if (noteArray.length == 1)
            {
                const note = noteArray[0];
                immutable timestamp = (currTime - note.when).timeSince;

                enum pattern = "%s! %s left note %s ago: %s";

                immutable message = settings.colouredOutgoing ?
                    pattern.format(senderName.ircBold,
                        note.sender.ircColourByHash.ircBold, timestamp.ircBold, note.line) :
                    pattern.format(senderName, note.sender, timestamp, note.line);

                privmsg(plugin.state, channel, event.sender.nickname, message);
            }
            else
            {
                import std.conv : text;

                enum pattern = "%s! You have %s notes.";

                immutable message = settings.colouredOutgoing ?
                    pattern.format(senderName.ircBold, noteArray.length.text.ircBold) :
                    pattern.format(senderName, noteArray.length);

                privmsg(plugin.state, channel, event.sender.nickname, message);

                foreach (const note; noteArray)
                {
                    immutable timestamp = (currTime - note.when)
                        .timeSince!(Yes.abbreviate);

                    enum entryPattern = "%s %s ago: %s";

                    immutable report = settings.colouredOutgoing ?
                        entryPattern.format(note.sender.ircColourByHash.ircBold,
                            timestamp, note.line) :
                        entryPattern.format(note.sender, timestamp, note.line);

                    privmsg(plugin.state, channel, event.sender.nickname, report);
                }
            }

            plugin.clearNotes(lowerNickname, channel);
            plugin.notes.save(plugin.notesFile);
        }
        catch (JSONException e)
        {
            string logtint, errortint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;

                    logtint = (cast(KamelosoLogger)logger).logtint;
                    errortint = (cast(KamelosoLogger)logger).errortint;
                }
            }

            logger.errorf("Could not fetch and/or replay notes for %s%s%s on %1$s%4$s%3$s: %1$s%5$s",
                logtint, event.sender.nickname, errortint, event.channel, e.msg);

            if (e.msg == "JSONValue is not an object")
            {
                logger.warning("Notes file corrupt. Starting from scratch.");
                plugin.notes.reset();
                plugin.notes.save(plugin.notesFile);
            }
        }

        // Break early and save us a loop and a lookup
        if (!channel.length) break;
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
@(ChannelPolicy.home)
void onNames(NotesPlugin plugin, const IRCEvent event)
{
    import dialect.common : stripModesign;
    import std.algorithm.iteration : splitter;

    if (event.channel !in plugin.notes) return;

    foreach (immutable signed; event.content.splitter)
    {
        immutable nickname = signed.stripModesign(plugin.state.server);
        if (nickname == plugin.state.client.nickname) continue;

        IRCEvent fakeEvent;

        with (fakeEvent)
        {
            type = IRCEvent.Type.JOIN;
            sender.nickname = nickname;
            channel = event.channel;
        }

        plugin.onReplayEvent(fakeEvent);
    }
}


// onCommandAddNote
/++
 +  Adds a note to the in-memory storage, and saves it to disk.
 +
 +  Messages sent in a channel will become messages for the target user in that
 +  channel. Those sent in a private query will be private notes, sent privately
 +  in the same fashion as channel notes are sent publicly.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "note")
@Description("Adds a note and saves it to disk.", "$command [account] [note text]")
void onCommandAddNote(NotesPlugin plugin, const IRCEvent event)
{
    import lu.string : contains, nom;
    import std.algorithm.comparison : equal;
    import std.json : JSONException;
    import std.typecons : No, Yes;
    import std.uni : asLowerCase, toLower;

    if (!event.content.contains!(Yes.decode)(" ")) return;

    string slice = event.content;
    immutable lowerNickname = slice.nom!(Yes.decode)(" ").toLower;

    if (lowerNickname.equal(plugin.state.client.nickname.asLowerCase))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "You cannot leave the bot a message; it would never be replayed.");
        return;
    }

    immutable senderName = nameOf(event.sender);
    immutable line = slice;

    try
    {
        plugin.addNote(lowerNickname, senderName, event.channel, line);
        privmsg(plugin.state, event.channel, event.sender.nickname, "Note added.");
        plugin.notes.save(plugin.notesFile);
    }
    catch (JSONException e)
    {
        string logtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;
                logtint = (cast(KamelosoLogger)logger).logtint;
            }
        }

        logger.error("Failed to add note: ", logtint, e.msg);
    }
}


// onCommandPrintNotes
/++
 +  Prints saved notes in JSON form to the local terminal.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printnotes")
@Description("[debug] Prints saved notes to the local terminal.")
void onCommandPrintNotes(NotesPlugin plugin)
{
    import std.stdio : stdout, writeln;

    writeln("Currently queued notes:");
    writeln(plugin.notes.toPrettyString);
    if (settings.flush) stdout.flush();
}


// onCommandReloadNotes
/++
 +  Reloads notes from disk, overwriting the in-memory storage.
 +
 +  This is both for debugging purposes and for live-editing notes on disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "reloadnotes")
@Description("Reloads notes from disk.")
void onCommandReloadNotes(NotesPlugin plugin)
{
    logger.log("Reloading notes.");
    plugin.notes.load(plugin.notesFile);
}


// getNotes
/++
 +  Fetches the notes for a specified user, from the in-memory JSON storage.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +      channel = Channel for which the notes were stored.
 +      nickname = Nickname of user whose notes to fetch.
 +
 +  Returns:
 +      A Voldemort `Note[]` array, where `Note` is a struct containing a note
 +      and metadata thereto.
 +/
auto getNotes(NotesPlugin plugin, const string channel, const string nickname)
{
    import lu.string : decode64;
    import std.datetime.systime : SysTime;
    import std.format : format;
    import std.json : JSONType;

    struct Note
    {
        string sender, line;
        SysTime when;
    }

    Note[] noteArray;

    if (const channelNotes = channel in plugin.notes)
    {
        assert((channelNotes.type == JSONType.object),
            "Invalid channel notes list type for %s: `%s`"
            .format(channel, channelNotes.type));

        if (const nickNotes = nickname in channelNotes.object)
        {
            assert((nickNotes.type == JSONType.array),
                "Invalid notes list type for %s on %s: `%s`"
                .format(nickname, channel, nickNotes.type));

            noteArray.length = nickNotes.array.length;

            foreach (immutable i, note; nickNotes.array)
            {
                import std.base64 : Base64Exception;
                noteArray[i].sender = note["sender"].str;
                noteArray[i].when = SysTime.fromUnixTime(note["when"].integer);

                try
                {
                    noteArray[i].line = decode64(note["line"].str);
                }
                catch (Base64Exception e)
                {
                    noteArray[i].line = "(An error occurred and the note could not be read)";
                }
            }
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
 +      channel = Channel for which the notes were stored.
 +/
void clearNotes(NotesPlugin plugin, const string nickname, const string channel)
in (nickname.length, "Tried to clear notes for an empty nickname")
//in (channel.length, "Tried to clear notes with an empty channel string")
{
    import std.file : FileException;
    import std.format : format;
    import std.exception : ErrnoException;
    import std.json : JSONException, JSONType;

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

    try
    {
        if (nickname in plugin.notes[channel])
        {
            assert((plugin.notes[channel].type == JSONType.object),
                "Invalid channel notes list type for %s: `%s`"
                .format(channel, plugin.notes[channel].type));

            logger.logf("Clearing stored notes for %s%s%s in %1$s%4$s%3$s.",
                infotint, nickname, logtint, channel.length ? channel : "(private messages)");
            plugin.notes[channel].object.remove(nickname);
            plugin.pruneNotes();
        }
    }
    catch (JSONException e)
    {
        logger.error("Failed to clear notes: ", logtint, e.msg);
    }
    catch (FileException e)
    {
        logger.error("Failed to save notes: ", logtint, e.msg);
    }
    catch (ErrnoException e)
    {
        logger.error("Failed to open/close notes file: ", logtint, e.msg);
    }
}


// pruneNotes
/++
 +  Prunes the notes database of empty channel entries.
 +
 +  Individual nickname entries are not touched as they are assumed to be
 +  cleared and removed after replaying its notes.
 +
 +  Params:
 +      plugin = Current `NotesPlugin`.
 +/
void pruneNotes(NotesPlugin plugin)
{
    string[] garbageKeys;

    foreach (immutable channel, channelNotes; plugin.notes.object)
    {
        if (!channelNotes.object.length)
        {
            // Dead channel
            garbageKeys ~= channel;
        }
    }

    foreach (immutable key; garbageKeys)
    {
        plugin.notes.object.remove(key);
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
 +      content = Channel for which we should save the note.
 +      line = Note text.
 +/
void addNote(NotesPlugin plugin, const string nickname, const string sender,
    const string channel, const string line)
in (nickname.length, "Tried to add a note for an empty nickname")
in (sender.length, "Tried to add a note from an empty sender")
//in (channel.length, "Tried to add a note with an empty channel")
in (line.length, "Tried to add an empty note")
{
    import lu.string : encode64;
    import std.datetime.systime : Clock;
    import std.json : JSONValue;

    if (!line.length)
    {
        logger.warning("No message to create note from.");
        return;
    }

    // "when" is long so can't construct a single AA and assign it in one go
    // (it wouldn't be string[string] then)
    auto senderAndLine =
    [
        "sender" : sender,
        "line"   : encode64(line),
        //"when" : Clock.currTime.toUnixTime,
    ];

    auto asJSON = JSONValue(senderAndLine);
    asJSON["when"] = Clock.currTime.toUnixTime;  // workaround to the above

    // If there is no channel in the JSON, add it
    if (channel !in plugin.notes)
    {
        plugin.notes[channel] = null;
        plugin.notes[channel].object = null;
    }

    if (nickname !in plugin.notes[channel])
    {
        plugin.notes[channel][nickname] = null;
        plugin.notes[channel][nickname].array = null;
    }

    plugin.notes[channel][nickname].array ~= asJSON;
}


// onEndOfMotd
/++
 +  Initialises the Notes plugin. Loads the notes from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(NotesPlugin plugin)
{
    plugin.notes.load(plugin.notesFile);
}


// initResources
/++
 +  Ensures that there is a notes file, creating one if there isn't.
 +/
void initResources(NotesPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.notesFile);
    }
    catch (JSONException e)
    {
        import std.path : baseName;
        throw new IRCPluginInitialisationException(plugin.notesFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    json.save(plugin.notesFile);
}


mixin MinimalAuthentication;

public:


// NotesPlugin
/++
 +  The Notes plugin, which allows people to leave messages to each other,
 +  for offline communication and such.
 +/
final class NotesPlugin : IRCPlugin
{
private:
    import lu.json : JSONStorage;

    /// All Notes plugin settings gathered.
    @Settings NotesSettings notesSettings;

    // notes
    /++
     +  The in-memory JSON storage of all stored notes.
     +
     +  It is in the JSON form of `Note[][string][string]`, where the first
     +  string key is a channel and the second a nickname.
     +/
    JSONStorage notes;

    /// Filename of file to save the notes to.
    @Resource string notesFile = "notes.json";

    mixin IRCPluginImpl;
}
