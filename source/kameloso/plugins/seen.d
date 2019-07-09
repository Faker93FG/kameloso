/++
 +  The Seen plugin implements `seen` functionality; the ability for someone to
 +  query when a given nickname was last seen online.
 +
 +  We will implement this by keeping an internal `long[string]` associative
 +  array of timestamps keyed by nickname. Whenever we see a user do something,
 +  we will update his or her timestamp to the current time. We'll save this
 +  array to disk when closing the program and read it from file when starting
 +  it, as well as saving occasionally once every few (configurable) hours.
 +
 +  We will rely on the `ChanQueriesPlugin` (in `chanqueries.d`) to query
 +  channels for full lists of users upon joining new channels, including the
 +  ones we join upon connecting. Elsewise, a completely silent user will never
 +  be recorded as having been seen, as they would never be triggering any of
 +  the functions we define to listen to.
 +
 +  kameloso does primarily not use callbacks, but instead annotates functions
 +  with `UDA`s of IRC event *types*. When an event is incoming it will trigger
 +  the function(s) annotated with its type.
 +
 +  Callback `core.thread.Fiber`s *are* supported. They can be registered to
 +  process on incoming events, or timed with a worst-case precision of roughly
 +  `kameloso.constants.Timeout.receive` *
 +  `(kameloso.main.mainLoop).checkTimedFibersEveryN` + 1 seconds. Compared to
 +  using `kameloso.irc.defs.IRCEvent` triggers they are expensive, in a
 +  micro-optimising sense.
 +/
module kameloso.plugins.seen;

// We only want to compile this if we're compiling plugins at all.
version(WithPlugins):

// ...and also if compiling in specifically this plugin.
version(WithSeenPlugin):

// We need crucial things from `kameloso.plugins.common`.
import kameloso.plugins.common;

// Likewise `kameloso.irc.defs`, for the definitions of an IRC event.
import kameloso.irc.defs;

// `kameloso.irc.colours` for some IRC colouring and formatting.
import kameloso.irc.colours : ircBold, ircColourNick;

// `kameloso.common` for some globals.
import kameloso.common : logger, settings;

// `std.datetime` for the `Clock`, to update times with.
import std.datetime.systime : Clock;


/+
    Most of the module can (and ideally should) be kept private. Our surface
    area here will be restricted to only one `kameloso.plugins.common.IRCPlugin`
    class, and the usual pattern used is to have the private bits first and that
    public class last. We'll turn that around here to make it easier to visually parse.
 +/

public:


// SeenPlugin
/++
 +  This is your plugin to the outside world, the only thing visible in the
 +  entire module. It only serves as a way of proxying calls to our top-level
 +  private functions, as well as to house plugin-private variables that we want
 +  to keep out of top-level scope for the sake of modularity. If the only state
 +  is in the plugin, several plugins of the same kind can technically be run
 +  alongside each other, which would allow for several bots to be run in
 +  parallel. This is not yet supported but there's nothing stopping it.
 +
 +  As such it houses this plugin's *state*, notably its instance of
 +  `SeenSettings` and its `kameloso.plugins.common.IRCPluginState`.
 +
 +  The `kameloso.plugins.common.IRCPluginState` is a struct housing various
 +  variables that together make up the plugin's state. This is where
 +  information is kept about the bot, the server, and some metathings allowing
 +  us to send messages to the server. We don't define it here; we mix it in
 +  later with the `kameloso.plugins.common.IRCPluginImpl` mixin.
 +
 +  ---
 +  struct IRCPluginState
 +  {
 +      IRCClient client;
 +      Tid mainThread;
 +      IRCUser[string] users;
 +      IRCChannel[string] channels;
 +      WHOISRequest[string] triggerRequestQueue;
 +      Fiber[][IRCEvent.Type] awaitingFibers;
 +      Labeled!(Fiber, long)[] timedFibers;
 +      long nextPeriodical;
 +  }
 +  ---
 +
 +  * `client` houses information about the client itself, and the server you're
 +     connected to.
 +
 +  * `mainThread` is the *thread ID* of the thread running the main loop. We
 +     indirectly use it to send strings to the server by way of concurrency
 +     messages, but it is usually not something you will have to deal with directly.
 +
 +  * `users` is an associative array keyed with users' nicknames. The value to
 +     that key is an `kameloso.irc.defs.IRCUser` representing that user in terms
 +     of nickname, address, ident, and services account name. This is a way to
 +     keep track of users by more than merely their name. It is however not
 +     saved at the end of the program; it is merely state and transient.
 +
 +  * `channels` is another associative array, this one with all the known
 +     channels keyed by their names. This way we can access detailed
 +     information about any given channel, knowing only their name.
 +
 +  * `triggerRequestQueue` is also an associative array into which we place
 +    `kameloso.plugins.common.TriggerRequest`s. The main loop will pick up on
 +     these and call `WHOIS` on the nickname in the key. A
 +     `kameloso.plugins.common.TriggerRequest` is otherwise just an
 +     `kameloso.irc.defs.IRCEvent` to be played back when the `WHOIS` results
 +     return, as well as a function pointer to call with that event. This is
 +     all wrapped in a function `kameloso.plugins.common.doWhois`, with the
 +     queue management handled behind the scenes.
 +
 +  * `awaitingFibers` is an associative array of `core.thread.Fiber`s keyed by
 +     `kamelos.ircdefs.IRCEvent.Type`s. Fibers in the array of a particular
 +     event type will be executed the next time such an event is incoming.
 +     Think of it as Fiber callbacks.
 +
 +  * `timedFibers` is also an array of `core.thread.Fiber`s, but not an
 +     associative one keyed on event types. Instead they are wrapped in a
 +     `kameloso.typecons.Labeled` template and marked with a UNIX timestamp of
 +     when they should be run. Use `kameloso.plugins.common.delayFiber` to enqueue.
 +
 +  * `nextPeriodical` is a UNIX timestamp of when the `periodical(IRCPlugin)`
 +     function should be run next. It is a way of automating occasional tasks,
 +     in our case the saving of the seen users to disk.
 +/
final class SeenPlugin : IRCPlugin
{
private:  // Module-level private.

    // seenSettings
    /++
     +  An instance of *settings* for the Seen plugin. We will define this
     +  later. The members of it will be saved to and loaded from the
     +  configuration file, for use in our module. We need to annotate it
     +  `@Settings` to ensure it ends up there, and the wizardry will pick it up.
     +/
    @Settings SeenSettings seenSettings;


    // seenUsers
    /++
     +  Our associative array (AA) of seen users; the dictionary keyed with
     +  users' nicknames and with values that are UNIX timestamps, denoting when
     +  that user was last *seen* online.
     +
     +  Example:
     +  ---
     +  seenUsers["joe"] = Clock.currTime.toUnixTime;
     +  immutable now = Clock.currTime.toUnixTime;
     +  writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"]));
     +  ---
     +/
    long[string] seenUsers;


    // seenFile
    /++
     +  The filename to which to persistently store our list of seen users
     +  between executions of the program.
     +
     +  This is only the basename of the file. It will be completed with a path
     +  to the default (or specified) resource directory, which varies by
     +  platform. Expect this variable to have values like
     +  "/home/user/.local/share/kameloso/servers/irc.freenode.net/seen.json"
     +  after the plugin has been instantiated.
     +/
    @Resource string seenFile = "seen.json";


    // mixin IRCPluginImpl
    /++
     +  This mixes in functions that fully implement an
     +  `kameloso.plugins.common.IRCPlugin`. They don't do much by themselves
     +  other than call the module's functions.
     +
     +  As an exception, it mixes in the bits needed to automatically call
     +  functions based on their `kameloso.irc.defs.IRCEvent.Type` annotations.
     +  It is mandatory, if you want things to work.
     +
     +  Seen from any other module, this module is a big block of private things
     +  they can't see, plus this visible plugin class. By having this class
     +  pass on things to the private functions we limit the surface area of
     +  the plugin to be really small.
     +/
    mixin IRCPluginImpl;


    // mixin MessagingProxy
    /++
     +  This mixin adds shorthand functions to proxy calls to
     +  `kameloso.messaging` functions, *curried* with the main thread ID, so
     +  they can easily be called with knowledge only of the plugin symbol.
     +
     +  ---
     +  plugin.chan("#d", "Hello world!");
     +  plugin.query("kameloso", "Hello you!");
     +
     +  with (plugin)
     +  {
     +      chan("#d", "This is convenient");
     +      query("kameloso", "No need to specify plugin.state.mainThread");
     +  }
     +  ---
     +/
    mixin MessagingProxy;
}


/+
 +  The rest will be private.
 +/
private:


// SeenSettings
/++
 +  We want our plugin to be *configurable* with a section for itself in the
 +  configuration file. For this purpose we create a "Settings" struct housing
 +  our configurable bits, which we already made an instance of in `SeenPlugin`.
 +
 +  If the name ends with "Settings", that will be stripped from its section
 +  header in the file. Hence, this plugin's `SeenSettings` will get the header
 +  `[Seen]`.
 +
 +  Each member of the struct will be given its own line in there. Note that not
 +  all types are supported, such as associative arrays or nested structs/classes.
 +/
struct SeenSettings
{
    /++
     +  Toggles whether or not the plugin should react to events at all.
     +  The `@Enabler` annotation makes it special and lets us easily enable or
     +  disable it without having checks everywhere.
     +/
    @Enabler bool enabled = true;
}


// onSomeAction
/++
 +  Whenever a user does something, record this user as having been seen at the
 +  current time.
 +
 +  This function will be called whenever an `kameloso.irc.defs.IRCEvent` is
 +  being processed of the `kameloso.irc.defs.IRCEvent.Type`s that we annotate
 +  the function with.
 +
 +  The `kameloso.plugins.common.Chainable` annotations mean that the plugin
 +  will also process other functions in this module with the same
 +  `kameloso.irc.defs.IRCEvent.Type` annotations, even if this one matched. The
 +  default is otherwise that it will end early after one match, but this
 +  doesn't ring well with catch-all functions like these. It's sensible to save
 +  `kameloso.plugins.common.Chainable` only for the modules and functions that
 +  actually need it.
 +
 +  The `kameloso.plugins.common.ChannelPolicy` annotation dictates whether or not this
 +  function should be called based on the *channel* the event took place in, if
 +  applicable. The two policies are `home`, in which only events in channels in
 +  the `homes` array will be allowed to trigger this; or `any`, in which case
 +  anywhere goes. For events that don't correspond to a channel (such as
 +  `kameloso.irc.defs.IRCEvent.Type.QUERY`) the setting is ignored.
 +
 +  The `kameloso.plugins.common.PrivilegeLevel` annotation dictates who is
 +  authorised to trigger the function. It has three policies; `anyone`,
 +  `whitelist` and `admin`.
 +
 +  * `ignored` will let precisely anyone trigger it, without looking them up.
 +     <br>
 +  * `anyone` will let precisely anyone trigger it, but only after having
 +     looked them up.<br>
 +  * `registered` will let anyone logged into a services account trigger it.<br>
 +  * `whitelist` will only allow users in the `whitelist` array in the
 +     configuration file.<br>
 +  * `admin` will allow only you and your other administrators, also as defined
 +     in the configuration file.
 +
 +  In the case of `whitelist` and `admin` it will look you up and
 +  compare your *services account name* to those configured before doing
 +  anything. In the case of `registered`, merely being logged in is enough.
 +  In the case of `anyone`, the WHOIS results won't matter and it will just
 +  let it pass. In the other cases, if you aren't logged into services or if
 +  your account name isn't included in the lists, the function will not trigger.
 +
 +  This particular function doesn't care at all, so it is `PrivilegeLevel.ignore`.
 +/
@(Chainable)
@(IRCEvent.Type.EMOTE)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.PART)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onSomeAction(SeenPlugin plugin, const IRCEvent event)
{
    /+
        Updates the user's timestamp to the current time.

        This will, as such, be automatically called on `EMOTE`, `QUERY`, `CHAN`,
        `JOIN`, and `PART` events. Furthermore, it will only trigger if it took
        place in a home channel.
     +/
    plugin.updateUser(event.sender.nickname, Clock.currTime.toUnixTime);
}


// onQuit
/++
 +  When someone quits, update their entry with the current timestamp iff they
 +  already have an entry.
 +
 +  `QUIT` events don't carry a channel. Users bleed into the seen users database
 +  by quitting unless we somehow limit it to only accept quits from those in
 +  home channels. Users in home channels should always have an entry, provided
 +  that `RPL_NAMREPLY` lists were given when joining one, which seems to (largely?)
 +  be the case.
 +
 +  Do nothing if an entry was not found.
 +/
@(IRCEvent.Type.QUIT)
@(PrivilegeLevel.ignore)
void onQuit(SeenPlugin plugin, const IRCEvent event)
{
    if (event.sender.nickname in plugin.seenUsers)
    {
        plugin.updateUser(event.sender.nickname, Clock.currTime.toUnixTime);
    }
}


// onNick
/++
 +  When someone changes nickname, add a new entry with the current timestamp for
 +  the new nickname, and remove the old one.
 +
 +  Bookkeeping; this is to avoid getting ghost entries in the seen array.
 +
 +  Like `QUIT`, `NICK` events don't carry a channel, so we can't annotate it
 +  `ChannelPolicy.home`; all we know is that the user is in one or more channels
 +  we're currently in. We can't tell whether it's in a home or not. As such,
 +  only update if the user has already been observed at least once, which should
 +  always be the case (provided `RPL_NAMREPLY` lists on join).
 +/
@(Chainable)
@(IRCEvent.Type.NICK)
@(PrivilegeLevel.ignore)
void onNick(SeenPlugin plugin, const IRCEvent event)
{
    if (event.sender.nickname in plugin.seenUsers)
    {
        plugin.seenUsers[event.target.nickname] = Clock.currTime.toUnixTime;
        plugin.seenUsers.remove(event.sender.nickname);
    }
}


// onWHOReply
/++
 +  Catches each user listed in a `WHO` reply and updates their entries in the
 +  seen users list, creating them if they don't exist.
 +
 +  A `WHO` request enumerates all members in a channel. It returns several
 +  replies, one event per each user in the channel. The
 +  `kameloso.plugins.chanqueries.ChanQueriesService` services instigates this
 +  shortly after having joined one, as a service to other plugins.
 +/
@(IRCEvent.Type.RPL_WHOREPLY)
@(ChannelPolicy.home)
void onWHOReply(SeenPlugin plugin, const IRCEvent event)
{
    // Update the user's entry
    plugin.updateUser(event.target.nickname, Clock.currTime.toUnixTime);
}


// onNamesReply
/++
 +  Catch a `NAMES` reply and record each person as having been seen.
 +
 +  When requesting `NAMES` on a channel, the server will send a big list of
 +  every participant in it, in a big string of nicknames separated by spaces.
 +  This is done automatically when you join a channel. Nicknames are prefixed
 +  with mode signs if they are operators, voiced or similar, so we'll need to
 +  strip that away.
 +/
@(IRCEvent.Type.RPL_NAMREPLY)
@(ChannelPolicy.home)
void onNamesReply(SeenPlugin plugin, const IRCEvent event)
{
    import std.algorithm.iteration : splitter;

    /+
        Use a `std.algorithm.iteration.splitter` to iterate each name and call
        `updateUser` to update (or create) their entry in the
        `SeenPlugin.seenUsers` associative array.
     +/

    immutable now = Clock.currTime.toUnixTime;

    foreach (const signed; event.content.splitter(" "))
    {
        import kameloso.irc.common : stripModesign;
        import kameloso.string : contains, nom;

        string nickname = signed;

        if (nickname.contains('!'))
        {
            // SpotChat-like, signed is in full nick!ident@address form
            nickname = nickname.nom('!');
        }

        plugin.updateUser(nickname, now);
    }
}


// onEndOfList
/++
 +  Optimises the lookups in the associative array of seen users.
 +
 +  At the end of a long listing of users in a channel, when we're reasonably
 +  sure we've added users to our associative array of seen users, *rehashes* it.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(IRCEvent.Type.RPL_ENDOFWHO)
@(ChannelPolicy.home)
void onEndOfList(SeenPlugin plugin)
{
    plugin.seenUsers.rehash();
}


// onCommandSeen
/++
 +  Whenever someone says "seen" in a `CHAN` or a `QUERY`, and if `CHAN` then
 +  only if in a *home*, processes this function.
 +
 +  The `kameloso.plugins.common.BotCommand` annotation defines a piece of text
 +  that the incoming message must start with for this function to be called.
 +  `kameloso.plugins.common.PrefixPolicy` deals with whether the message has to
 +  start with the name of the *bot* or not, and to what extent.
 +
 +  Prefix policies can be one of:
 +  * `direct`, where the raw command is expected without any bot prefix at all.
 +  * `prefixed`, where the message has to start with the command prefix (usually `!`)
 +  * `nickname`, where the message has to start with bot's nickname, except
 +     if it's in a `QUERY` message.<br>
 +
 +  The plugin system will have made certain we only get messages starting with
 +  "`seen`", since we annotated this function with such a
 +  `kameloso.plugins.common.BotCommand`. It will since have been sliced off,
 +  so we're left only with the "arguments" to "`seen`". `event.aux` contains
 +  the triggering word, if it's needed.
 +
 +  If this is a `CHAN` event, the original lines could (for example) have been
 +  "`kameloso: seen Joe`", or merely "`!seen Joe`" (assuming a `!` prefix).
 +  If it was a private `QUERY` message, the `kameloso:` prefix may have been
 +  omitted. In either case, we're left with only the parts we're interested in,
 +  and the rest sliced off.
 +
 +  As a result, the `kameloso.irc.defs.IRCEvent` `event` would look something
 +  like this:
 +
 +  ---
 +  event.type = IRCEvent.Type.CHAN;
 +  event.sender.nickname = "foo";
 +  event.sender.ident = "~bar";
 +  event.sender.address = "baz.foo.bar.org";
 +  event.channel = "#bar";
 +  event.content = "Joe";
 +  ---
 +
 +  Lastly, the `Description` annotation merely defines how this function will
 +  be listed in the "online help" list, shown by sending "`help`" to the bot in
 +  a private message.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "seen")
@Description("Queries the bot when it last saw a specified nickname online.", "$command [nickname]")
void onCommandSeen(SeenPlugin plugin, const IRCEvent event)
{
    import kameloso.common : timeSince;
    import kameloso.irc.common : isValidNickname;
    import kameloso.string : contains;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : SysTime;
    import std.format : format;

    /+
        The bot uses concurrency messages to queue strings to be sent to the
        server. This has benefits such as that even a multi-threaded program
        will have synchronous messages sent, and it's overall an easy and
        convenient way for plugin to send messages up the stack.

        There are shorthand versions for sending these messages in
        `kameloso.messaging`, and additionally this module has mixed in
        `MessagingProxy` in the `SeenPlugin`, creating even shorter shorthand
        versions.

        You can therefore use them as such:

        ---
        with (plugin)  // <-- necessary for the short-shorthand
        {
            chan("#d", "Hello world!");
            query("kameloso", "Hello you!");
            privmsg(event.channel, event.sender.nickname, "Query or chan!");
            join("#flerrp");
            part("#flerrp");
            topic("#flerrp", "This is a new topic");
        }
        ---

        `privmsg` will either send a channel message or a personal query message
        depending on the arguments passed to it. If the first `channel` argument
        is not empty, it will be a `chan` channel message, else a private
        `query` message.
     +/

    with (plugin)
    {
        if (!event.content.length)
        {
            // No nickname supplied...
            return;
        }
        else if (!event.content.isValidNickname(plugin.state.client.server))
        {
            // Nickname contained a space
            string message;

            if (settings.colouredOutgoing)
            {
                privmsg(event.channel, event.sender.nickname,
                    "Invalid user: " ~ event.content.ircBold);
            }
            else
            {
                privmsg(event.channel, event.sender.nickname,
                    "Invalid user: " ~ event.content);
            }

            privmsg(event.channel, event.sender.nickname, message);
            return;
        }
        else if (state.client.nickname == event.content)
        {
            // The requested nick is the bot's.
            privmsg(event.channel, event.sender.nickname, "T-that's me though...");
            return;
        }
        else if (event.sender.nickname == event.content)
        {
            // The person is asking for seen information about him-/herself.
            privmsg(event.channel, event.sender.nickname, "That's you!");
            return;
        }

        foreach (const channel; state.channels)
        {
            if (event.content in channel.users)
            {
                immutable line = event.channel.length && (channel.name == event.channel) ?
                    " is here right now!" : " is online right now.";
                string message;

                if (settings.colouredOutgoing)
                {
                    message = event.content.ircColourNick.ircBold ~ line;
                }
                else
                {
                    message = event.content ~ line;
                }

                privmsg(event.channel, event.sender.nickname, message);
                return;
            }
        }

        // No matches

        const userTimestamp = event.content in seenUsers;

        if (!userTimestamp)
        {
            // No matches for nickname `event.content` in `plugin.seenUsers`.
            string message;

            if (settings.colouredOutgoing)
            {
                message = "I have never seen %s.".format(event.content.ircColourNick.ircBold);
            }
            else
            {
                message = "I have never seen %s.".format(event.content);
            }

            privmsg(event.channel, event.sender.nickname, message);
            return;
        }

        const timestamp = SysTime.fromUnixTime(*userTimestamp);
        immutable elapsed = timeSince(Clock.currTime - timestamp);

        string message;

        if (settings.colouredOutgoing)
        {
            message = "I last saw %s %s ago.".format(event.content.ircColourNick.ircBold, elapsed);
        }
        else
        {
            message = "I last saw %s %s ago.".format(event.content, elapsed);
        }

        privmsg(event.channel, event.sender.nickname, message);
    }
}


// onCommandPrintSeen
/++
 +  As a tool to help debug, prints the current `SeenPlugin.seenUsers`
 +  associative array to the local terminal.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printseen")
@Description("[debug] Prints all seen users (and timestamps) to the local terminal.")
void onCommandPrintSeen(SeenPlugin plugin)
{
    import std.json : JSONValue;
    import std.stdio : stdout, writeln;

    writeln(JSONValue(plugin.seenUsers).toPrettyString);
    if (settings.flush) stdout.flush();
}


// updateUser
/++
 +  Updates a given nickname's entry in the seen array with the passed time,
 +  expressed in UNIX time.
 +
 +  This is not annotated with an IRC event type and will merely be invoked from
 +  elsewhere, like any normal function.
 +
 +  Example:
 +  ---
 +  string potentiallySignedNickname = "@kameloso";
 +  const now = Clock.currTime;
 +  plugin.updateUser(potentiallySignedNickname, now);
 +  ---
 +
 +  Params:
 +      plugin = Current `SeenPlugin`.
 +      signed = Nickname to update, potentially prefixed with a modesign
 +          (@, +, %, ...).
 +      time = UNIX timestamp of when the user was seen.
 +/
void updateUser(SeenPlugin plugin, const string signed, const long time)
{
    import kameloso.irc.common : stripModesign;

    // Make sure to strip the modesign, so `@foo` is the same person as `foo`.
    immutable nickname = plugin.state.client.server.stripModesign(signed);
    if (nickname == plugin.state.client.nickname) return;
    plugin.seenUsers[nickname] = time;
}


// updateAllObservedUsers
/++
 +  Updates all currently observed users.
 +
 +  This allows us to update users that don't otherwise trigger events that
 +  would register activity, such as silent participants.
 +
 +  Params:
 +      plugin = Current `SeenPlugin`.
 +/
void updateAllObservedUsers(SeenPlugin plugin)
{
    bool[string] uniqueUsers;

    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        foreach (const nickname; channel.users.byKey)
        {
            uniqueUsers[nickname] = true;
        }
    }

    immutable now = Clock.currTime.toUnixTime;

    foreach (immutable nickname, immutable nil; uniqueUsers)
    {
        plugin.updateUser(nickname, now);
    }
}


// loadSeen
/++
 +  Given a filename, reads the contents and load it into a `long[string]`
 +  associative array, then returns it. If there was no file there to read,
 +  returns an empty array for a fresh start.
 +
 +  Params:
 +      filename = Filename of the file to read from.
 +
 +  Returns:
 +      `long[string]` associative array; UNIX timestamp longs keyed by nickname strings.
 +/
long[string] loadSeen(const string filename)
{
    import std.file : exists, isFile, readText;
    import std.json : JSONException, parseJSON;

    string infotint, logtint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    long[string] aa;

    scope(exit)
    {
        import kameloso.string : plurality;
        logger.logf("Currently %s%d%s %s seen.",
            infotint, aa.length, logtint, aa.length.plurality("user", "users"));
    }

    if (!filename.exists || !filename.isFile)
    {
        logger.warningf("%s%s%s does not exist or is not a file", logtint, filename, warningtint);
        return aa;
    }

    try
    {
        const asJSON = parseJSON(filename.readText).object;

        // Manually insert each entry from the JSON file into the long[string] AA.
        foreach (immutable user, const time; asJSON)
        {
            aa[user] = time.integer;
        }
    }
    catch (JSONException e)
    {
        logger.error("Could not load seen JSON from file: ", logtint, e.msg);
    }

    // Rehash the AA, since we potentially added a *lot* of users.
    return aa.rehash();
}


// saveSeen
/++
 +  Saves the passed seen users associative array to disk, but in `JSON` format.
 +
 +  This is a convenient way to serialise the array.
 +
 +  Params:
 +      seenUsers = The associative array of seen users to save.
 +      filename = Filename of the file to write to.
 +/
void saveSeen(const long[string] seenUsers, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    auto file = File(filename, "w");

    file.writeln(JSONValue(seenUsers).toPrettyString);
}


// onEndOfMotd
/++
 +  After we have registered on the server and seen the "message of the day"
 +  spam, loads our seen users from file.`
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(SeenPlugin plugin)
{
    plugin.seenUsers = loadSeen(plugin.seenFile);
}


// periodically
/++
 +  Saves seen users to disk once every `hoursBetweenSaves` hours.
 +
 +  This is to make sure that as little data as possible is lost in the event
 +  of an unexpected shutdown.
 +
 +  `periodically` is a function that is run whenever the UNIX timestamp
 +  exceeds the value of `plugin.state.nextPeriodical`.
 +/
void periodically(SeenPlugin plugin)
{
    enum hoursBetweenSaves = 3;

    immutable now = Clock.currTime.toUnixTime;
    plugin.state.nextPeriodical = now + (hoursBetweenSaves * 3600);

    if (plugin.isEnabled)
    {
        plugin.updateAllObservedUsers();
        plugin.seenUsers.rehash().saveSeen(plugin.seenFile);
    }
}


// teardown
/++
 +  When closing the program or when crashing with grace, saves the seen users
 +  array to disk for later reloading.
 +/
void teardown(SeenPlugin plugin)
{
    plugin.updateAllObservedUsers();
    plugin.seenUsers.saveSeen(plugin.seenFile);
}


// initResources
/++
 +  Reads and writes the file of seen people to disk, ensuring that it's there.
 +/
void initResources(SeenPlugin plugin)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.seenFile);
    }
    catch (JSONException e)
    {
        import kameloso.terminal : TerminalToken;
        import std.path : baseName;

        logger.warning(plugin.seenFile.baseName, " is corrupt. Starting afresh.",
            cast(char)TerminalToken.bell);
    }

    // Let other Exceptions pass.

    json.save(plugin.seenFile);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`seen`" header,
 +  and calls functions based on the payload message.
 +
 +  This is used in the Pipeline plugin, to allow us to trigger seen verbs via
 +  the command-line pipe.
 +
 +  Params:
 +      plugin = The current `SeenPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
debug
version(Posix)
void onBusMessage(SeenPlugin plugin, const string header, shared Sendable content)
{
    if (!plugin.isEnabled) return;
    if (header != "seen") return;

    import kameloso.string : strippedRight;
    import kameloso.thread : BusMessage;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    immutable verb = message.payload.strippedRight;

    switch (verb)
    {
    case "print":
        logger.info("Currently seen users:");
        plugin.onCommandPrintSeen();
        break;

    case "reload":
        plugin.seenUsers = loadSeen(plugin.seenFile);
        logger.info("Seen users reloaded from disk.");
        break;

    case "save":
        plugin.updateAllObservedUsers();
        plugin.seenUsers.saveSeen(plugin.seenFile);
        logger.info("Seen users saved to disk.");
        break;

    default:
        logger.error("Unimplemented piped verb: ", verb);
        break;
    }
}


/++
 +  `kameloso.plugins.common.UserAwareness` is a mixin template; a few functions
 +  defined in `kameloso.plugins.common` to deal with common bookkeeping that
 +  every plugin *that wants to keep track of users* need. If you don't want to
 +  track which users you have seen (and are visible to you now), you don't need this.
 +/
mixin UserAwareness;


/++
 +  Complementary to `kameloso.plugins.common.UserAwareness` is
 +  `kameloso.plugins.common.ChannelAwareness`, which will add in bookkeeping
 +  about the channels the bot is in, their topics, modes and list of
 +  participants. Channel awareness requires user awareness, but not the other way around.
 +
 +  We will want it to limit the amount of tracked users to people in our home channels.
 +/
mixin ChannelAwareness;


/++
 +  This full plugin is <200 source lines of code. (`dscanner --sloc seen.d`)
 +  Even at those numbers it is fairly feature-rich.
 +/
