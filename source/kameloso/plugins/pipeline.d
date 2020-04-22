/++
 +  The Pipeline plugin opens a Posix named pipe in the current directory, to
 +  which you can pipe text and have it be sent verbatim to the server.
 +
 +  It has no commands; indeed, it doesn't listen to
 +  `dialect.defs.IRCEvent`s at all, only to what is sent to it via the
 +  named FIFO pipe.
 +
 +  This requires version `Posix`, which is true for UNIX-like systems (like
 +  Linux and OSX).
 +/
module kameloso.plugins.pipeline;

version(WithPlugins):
version(Posix):
version(WithPipelinePlugin):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import kameloso.common;
import kameloso.messaging;
import kameloso.thread : ThreadMessage;
import dialect.defs;
import std.concurrency;
import std.stdio : File;


/+
    For storage location of the FIFO it makes sense to default to /tmp;
    Posix however defines a variable $TMPDIR, which should take precedence.
    However, this supposedly makes the file really difficult to access on OSX
    where it translates to some really long, programmatically generated path.
    OSX naturally does support /tmp though. So shrug and version it to
    default-ignore $TMPDIR on OSX but obey it on other platforms.
 +/
//version = OSXTMPDIR;


// PipelineSettings
/++
 +  All settings for a `PipelinePlugin`, aggregated.
 +/
@Settings struct PipelineSettings
{
    /// Whether or not the Pipeline plugin should do anything at all.
    @Enabler bool enabled = true;

    /++
     +  Whether or not to place the FIFO in the working directory. If false, it
     +  will be saved in `/tmp` or wherever `$TMPDIR` points. If OSX, then there
     +  only if version `OSXTMPDIR`.
     +/
    bool fifoInWorkingDir = false;
}


// pipereader
/++
 +  Reads a FIFO (named pipe) and relays lines received there to the main
 +  thread, to send to the server.
 +
 +  It is to be run in a separate thread.
 +
 +  Params:
 +      newState = The `kameloso.plugins.common.IRCPluginState` of the original
 +          `PipelinePlugin`, to provide the main thread's `core.thread.Tid` for
 +          concurrency messages, made `shared` to allow being sent between threads.
 +      filename = String filename of the FIFO to read from.
 +      monochrome = Whether or not output should be in monochrome text.
 +      brightTerminal = Whether or not the terminal has a bright background
 +          and colours should be adjusted to suit.
 +/
void pipereader(shared IRCPluginState newState, const string filename,
    const bool monochrome, const bool brightTerminal)
in (filename.length, "Tried to set up a pipereader with an empty filename")
{
    import std.file : FileException, exists, remove;

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("pipeline");
    }

    auto state = cast()newState;

    string infotint, logtint;

    version(Colours)
    {
        if (!monochrome)
        {
            import kameloso.constants : DefaultColours;
            import kameloso.terminal : colour;
            import std.experimental.logger : LogLevel;

            // We don't have a logger instance so we have to access the
            // DefaultColours.logcolours{Bright,Dark} tables manually

            if (brightTerminal)
            {
                enum infotintColourBright = DefaultColours.logcoloursBright[LogLevel.info].colour.idup;
                enum logtintColourBright = DefaultColours.logcoloursBright[LogLevel.all].colour.idup;
                infotint = infotintColourBright;
                logtint = logtintColourBright;
            }
            else
            {
                enum infotintColourDark = DefaultColours.logcoloursDark[LogLevel.info].colour.idup;
                enum logtintColourDark = DefaultColours.logcoloursDark[LogLevel.all].colour.idup;
                infotint = infotintColourDark;
                logtint = logtintColourDark;
            }
        }
    }

    import std.format : format;
    state.askToLog("Pipe text to the %s%s%s file to send raw commands to the server."
        .format(infotint, filename, logtint));

    // Creating the File struct blocks, so do it after reporting.
    File fifo = File(filename, "r");
    scope(exit) if (filename.exists) remove(filename);

    toploop:
    while (true)
    {
        // foreach but always break after processing one line, to be responsive
        // and retaining the ability to break out of it.
        foreach (immutable line; fifo.byLineCopy)
        {
            import kameloso.messaging : raw, quit;
            import std.algorithm.searching : startsWith;
            import std.uni : asLowerCase;

            if (!line.length) break;

            if (line[0] == ':')
            {
                import kameloso.thread : ThreadMessage, busMessage;
                import lu.string : contains, nom;

                if (line.contains(' '))
                {
                    string slice = line[1..$];
                    immutable header = slice.nom(' ');
                    state.mainThread.send(ThreadMessage.BusMessage(),
                        header, busMessage(slice));
                }
                else
                {
                    state.mainThread.send(ThreadMessage.BusMessage(), line[1..$]);
                }

                break;
            }

            if (line.asLowerCase.startsWith("quit"))
            {
                if ((line.length > 6) && (line[4..6] == " :"))
                {
                    quit(state, line[6..$]);
                }
                else
                {
                    quit(state);
                }

                break toploop;
            }
            else
            {
                raw(state, line);
            }

            break;
        }

        import kameloso.thread : busMessage;
        import core.time : seconds;

        static immutable instant = (-1).seconds;
        bool halt;

        receiveTimeout(instant,
            (ThreadMessage.Teardown)
            {
                halt = true;
            },
            (OwnerTerminated e)
            {
                halt = true;
            },
            (Variant v)
            {
                state.askToError("Pipeline plugin received Variant: " ~ logtint ~ v.toString());
                state.mainThread.send(ThreadMessage.BusMessage(), "pipeline", busMessage("halted"));
                halt = true;
            }
        );

        if (halt) break toploop;

        import std.exception : ErrnoException;

        try
        {
            fifo.reopen(filename);
        }
        catch (ErrnoException e)
        {
            state.askToError("Pipeline plugin failed to reopen FIFO: " ~ logtint ~ e.msg);
            version(PrintStacktraces) state.askToTrace(e.info.toString);
            state.mainThread.send(ThreadMessage.BusMessage(), "pipeline", busMessage("halted"));
            break toploop;
        }
        catch (Exception e)
        {
            state.askToError("Pipeline plugin saw unexpected exception");
            version(PrintStacktraces) state.askToTrace(e.toString);
            break toploop;
        }
    }
}


// createFIFO
/++
 +  Creates a FIFO (named pipe) in the filesystem.
 +
 +  It will be named a passed filename.
 +
 +  Params:
 +      state = String filename of FIFO to create.
 +
 +  Throws:
 +      `kameloso.common.ReturnValueException` if the FIFO could not be created.
 +      `kameloso.common.FileExistsException` if a FIFO with the same filename
 +      already exists, suggesting concurrent conflicting instances of the program
 +      (or merely a stale FIFO).
 +      `kameloso.common.FileTypeMismatchException` if a file or directory
 +      exists with the same name as the FIFO we want to create.
 +/
void createFIFO(const string filename)
in (filename.length, "Tried to create a FIFO with an empty filename")
{
    import lu.common : FileExistsException, FileTypeMismatchException, ReturnValueException;
    import std.file : exists;

    if (!filename.exists)
    {
        import std.process : execute;

        immutable mkfifo = execute([ "mkfifo", filename ]);

        if (mkfifo.status != 0)
        {
            throw new ReturnValueException("Could not create FIFO", "mkfifo", mkfifo.status);
        }
    }
    else
    {
        import core.sys.posix.sys.stat : S_ISFIFO;
        import std.file : getAttributes, isDir;

        immutable attrs = cast(ushort)getAttributes(filename);

        if (S_ISFIFO(attrs))
        {
            throw new FileExistsException("A FIFO with that name already exists",
                filename, __FILE__, __LINE__);
        }
        else
        {
            throw new FileTypeMismatchException("Wanted to create a FIFO but a file or "
                ~ "directory with the desired name already exists",
                filename, attrs, __FILE__, __LINE__);
        }
    }
}


// onMotd
/++
 +  Spawns the pipereader thread.
 +
 +  Snapshots the filename to use, as we base it on the bot's nickname, which
 +  may change during the connection's lifetime.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onMotd(PipelinePlugin plugin)
{
    with (plugin)
    {
        // Save the filename *once* so it persists across nick changes.
        // If !fifoInWorkingDir then in /tmp or $TMPDIR
        fifoFilename = state.client.nickname ~ "@" ~ state.server.address;

        if (!pipelineSettings.fifoInWorkingDir)
        {
            // See notes at the top of module.
            version(OSX)
            {
                version(OSXTMPDIR)
                {
                    enum useTMPDIR = true;
                }
                else
                {
                    enum useTMPDIR = false;
                }
            }
            else // Implicitly not Windows since Posix-only plugin
            {
                enum useTMPDIR = true;
            }

            static if (useTMPDIR)
            {
                import std.process : environment;
                immutable tempdir = environment.get("TMPDIR", "/tmp");
            }
            else
            {
                enum tempdir = "/tmp";
            }

            import std.path : buildNormalizedPath;
            fifoFilename = buildNormalizedPath(tempdir, fifoFilename);
        }

        import lu.common : FileExistsException, FileTypeMismatchException, ReturnValueException;

        try
        {
            createFIFO(fifoFilename);
            fifoThread = spawn(&pipereader, cast(shared)state, fifoFilename,
                plugin.state.settings.monochrome, plugin.state.settings.brightTerminal);
            workerRunning = true;
        }
        catch (ReturnValueException e)
        {
            logger.warningf("Failed to initialise Pipeline plugin: %s (%s%s%s returned %2$s%5$d%4$s)",
                e.msg, Tint.log, e.command, Tint.warning, e.retval);
            //version(PrintStacktraces) logger.trace(e.info);
        }
        catch (FileExistsException e)
        {
            logger.warningf("Failed to initialise Pipeline plugin: %s [%s%s%s]",
                e.msg, Tint.log, e.filename, Tint.warning);
            //version(PrintStacktraces) logger.trace(e.info);
        }
        catch (FileTypeMismatchException e)
        {
            logger.warningf("Failed to initialise Pipeline plugin: %s [%s%s%s]",
                e.msg, Tint.log, e.filename, Tint.warning);
            //version(PrintStacktraces) logger.trace(e.info);
        }

        // Let other Exceptions pass
    }
}


// teardown
/++
 +  De-initialises the Pipeline plugin. Shuts down the pipereader thread.
 +/
void teardown(PipelinePlugin plugin)
{
    import std.file : exists, isDir;
    import std.concurrency : Tid;

    if (!plugin.workerRunning) return;

    plugin.fifoThread.send(ThreadMessage.Teardown());

    if (plugin.fifoFilename.exists && !plugin.fifoFilename.isDir)
    {
        // Tell the reader of the pipe to exit
        auto fifo = File(plugin.fifoFilename, "w");
        fifo.writeln();
    }
}


import kameloso.thread : Sendable;

// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`pipeline`" header,
 +  and performs actions based on the payload message.
 +
 +  This is used to let the worker thread signal the main context that it halted.
 +
 +  Params:
 +      plugin = The current `PipelinePlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
void onBusMessage(PipelinePlugin plugin, const string header, shared Sendable content)
{
    if (!plugin.isEnabled) return;
    if (header != "pipeline") return;

    import kameloso.thread : BusMessage;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    if (message.payload == "halted")
    {
        plugin.workerRunning = false;
    }
    else
    {
        logger.error("[pipeline] Unimplemented bus message verb: ", message.payload);
    }
}


public:


// PipelinePlugin
/++
 +  The Pipeline plugin reads from a local named pipe (FIFO) for messages to
 +  send to the server, as well as to live-control the bot to a certain degree.
 +/
final class PipelinePlugin : IRCPlugin
{
private:
    /// All Pipeline settings gathered.
    PipelineSettings pipelineSettings;

    /// Thread ID of the thread reading the named pipe.
    Tid fifoThread;

    /// Filename of the created FIFO.
    string fifoFilename;

    /// Whether or not the worker is running in the background.
    bool workerRunning;

    mixin IRCPluginImpl;
}
