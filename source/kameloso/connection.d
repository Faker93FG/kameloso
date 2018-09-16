/++
 +  Functions related to connecting to an IRC server, and reading from it.
 +/
module kameloso.connection;

import kameloso.common : interruptibleSleep, logger;
import kameloso.constants;


// Connection
/++
 +  Functions and state needed to maintain a connection.
 +
 +  This is simply to decrease the amount of globals and to create some
 +  convenience functions.
 +/
struct Connection
{
private:
    import core.time : seconds;
    import std.socket : Socket, Address;

    /// Real IPv4 and IPv6 sockets to connect through.
    Socket socket4, socket6;

    /++
     +  Pointer to the socket of the `std.socket.AddressFamily` we want to
     +  connect with.
     +/
    Socket* socket;

public:
    /// IPs already resolved using `.resolveFiber`.
    Address[] ips;

    /++
     +  Implicitly proxies calls to the current `socket`. This successfully
     +  proxies to `Socket.receive`.
     +/
    alias socket this;

    /// Whether we are connected or not.
    bool connected;

    /// (Re-)initialises the sockets and sets the IPv4 one as the active one.
    void reset()
    {
        import std.socket : TcpSocket, AddressFamily, SocketType;

        socket4 = new TcpSocket;
        socket6 = new Socket(AddressFamily.INET6, SocketType.STREAM);
        socket = &socket4;

        setOptions(socket4);
        setOptions(socket6);

        connected = false;
    }

    // setOptions
    /++
     +  Sets up sockets with the `std.socket.SocketOptions` needed. These
     +  include timeouts and buffer sizes.
     +
     +  Params:
     +      socketToSetup = Reference to the `socket` to modify.
     +/
    void setOptions(Socket socketToSetup)
    {
        import std.socket : SocketOption, SocketOptionLevel;

        with (socketToSetup)
        with (SocketOption)
        with (SocketOptionLevel)
        {
            setOption(SOCKET, RCVBUF, BufferSize.socketOptionReceive);
            setOption(SOCKET, SNDBUF, BufferSize.socketOptionSend);
            setOption(SOCKET, RCVTIMEO, Timeout.receive.seconds);
            setOption(SOCKET, SNDTIMEO, Timeout.send.seconds);
            blocking = true;
        }
    }

    // sendline
    /++
     +  Sends a line to the server.
     +
     +  Sadly the IRC server requires lines to end with a newline, so we need
     +  to chain one directly after the line itself. If several threads are
     +  allowed to write to the same socket in parallel, this would be a race
     +  condition.
     +
     +  Additionally lines are only allowed to be 512 bytes.
     +
     +  Example:
     +  ---
     +  conn.sendline("NICK kameloso");
     +  conn.sendline("PRIVMSG #channel :text");
     +  ---
     +
     +  Params:
     +      strings = Variadic list of strings to send.
     +
     +  Bugs:
     +      Limits lines to 512 but doesn't take into consideration whether a
     +      line included a newline, which would break.
     +/
    void sendline(Strings...)(const Strings strings)
    {
        int remainingMaxLength = 511;

        foreach (immutable string_; strings)
        {
            import std.algorithm.comparison : min;
            immutable thisLength = min(string_.length, remainingMaxLength);
            socket.send(string_[0..thisLength]);
            remainingMaxLength -= thisLength;
            if (remainingMaxLength <= 0) break;
        }

        socket.send("\n");
    }
}


// ListenAttempt
/++
 +  Embodies the state of a listening attempt.
 +/
import core.time : Duration;
struct ListenAttempt
{
    /// At what state the listening process this attemt is currently at.
    enum State
    {
        prelisten,  /// About to listen.
        isEmpty,    /// Empty result; nothing read or similar.
        hasString,  /// String read, ready for processing.
        warning,    /// Recoverable exception thrown; warn and continue.
        error,      /// Unrecoverable exception thrown; abort.
    }

    /// The current state of the attempt.
    State state;

    /// The last read line of text sent by the server.
    string line;

    /// The error text of the last exception thrown.
    string error;

    /// The `lastSocketError` at the last point of error.
    string lastSocketError_;

    /// The amount of bytes received this attempt.
    long bytesReceived;

    /// The duration since the last string was successfully read.
    Duration elapsed;
}


// listenFiber
/++
 +  A `std.socket.Socket`-reading `std.concurrency.Generator`
 +  `core.thread.Fiber`.
 +
 +  It maintains its own buffer into which it receives from the server, though
 +  not neccessarily full lines. It thus keeps filling the buffer until it
 +  finds a newline character, yields `ListenAttempt`s back to the caller of
 +  the fiber, checks for more lines to yield, and if none yields an attempt
 +  with a `ListenAttempt.State` denoting that nothing was read and that a new
 +  attempt should be made later. The buffer logic is complex.
 +
 +  Example:
 +  ---
 +  import std.concurrency : Generator;
 +
 +  auto listener = new Generator!ListenAttempt(() => listenFiber(conn, abort));
 +  generator.call();
 +
 +  foreach (const attempt; listener)
 +  {
 +      // attempt is a yielded `ListenAttempt`
 +  }
 +  ---
 +
 +  Params:
 +      conn = `Connection` whose `std.socket.Socket` it reads from the server
 +          with.
 +      abort = Reference flag which, if set, means we should abort and return.
 +
 +  Yields:
 +      `ListenAttempt`s with information about the line receieved in its
 +      member values.
 +/
void listenFiber(Connection conn, ref bool abort)
{
    import core.time : seconds;
    import std.concurrency : yield;
    import std.datetime.systime : Clock;
    import std.socket : Socket, lastSocketError;
    import std.string : indexOf;

    ubyte[BufferSize.socketReceive*2] buffer;
    auto timeLastReceived = Clock.currTime;
    bool pingingToTestConnection;
    size_t start;

    alias State = ListenAttempt.State;
    ListenAttempt attempt;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. To work around our main loop popping too we
    // yield an initial empty value; else the first thing to happen will be a
    // double pop, and the first line is missed.
    yield(attempt);

    while (!abort)
    {
        immutable ptrdiff_t bytesReceived = conn.receive(buffer[start..$]);
        attempt.bytesReceived = bytesReceived;

        if (!bytesReceived)
        {
            attempt.state = State.error;
            attempt.lastSocketError_ = lastSocketError;
            yield(attempt);
            assert(0);  // Should never get here
        }
        else if (bytesReceived == Socket.ERROR)
        {
            immutable elapsed = (Clock.currTime - timeLastReceived);
            attempt.elapsed = elapsed;
            attempt.line = string.init;

            if (!pingingToTestConnection && (elapsed > Timeout.keepalive.seconds))
            {
                conn.send("PING :helloasdf");
                pingingToTestConnection = true;
                attempt.state = State.isEmpty;
                yield(attempt);
                continue;
            }

            if (elapsed > Timeout.connectionLost.seconds)
            {
                attempt.state = State.error;
                yield(attempt);
                assert(0);  // Should never get here
            }

            attempt.lastSocketError_ = lastSocketError;

            switch (attempt.lastSocketError_)
            {
            case "Resource temporarily unavailable":
                // Nothing received
            case "Interrupted system call":
                // Unlucky callgrind_control -d timing
            case "A connection attempt failed because the connected party did not " ~
                 "properly respond after a period of time, or established connection " ~
                 "failed because connected host has failed to respond.":
                // Timed out read in Windows
                attempt.state = State.isEmpty;
                yield(attempt);
                continue;

            // Others that may be benign?
            case "An established connection was aborted by the software in your host machine.":
            case "An existing connection was forcibly closed by the remote host.":
            case "Connection reset by peer":
            case "Transport endpoint is not connected":  // Failed IPv6 connection
                attempt.state = State.error;
                yield(attempt);
                assert(0);  // Should never get here

            default:
                attempt.state = State.warning;
                yield(attempt);
                continue;
            }
        }

        timeLastReceived = Clock.currTime;
        pingingToTestConnection = false;

        immutable ptrdiff_t end = (start + bytesReceived);
        auto newline = (cast(char[])buffer[0..end]).indexOf('\n');
        size_t pos;

        while (newline != -1)
        {
            //yield((cast(char[])buffer[pos..pos+newline-1]).idup);
            attempt.state = State.hasString;
            attempt.line = (cast(char[])buffer[pos..pos+newline-1]).idup;
            yield(attempt);
            pos += (newline + 1); // eat remaining newline
            newline = (cast(char[])buffer[pos..end]).indexOf('\n');
        }

        attempt.state = State.isEmpty;
        yield(attempt);

        if (pos >= end)
        {
            // can be end or end+1
            start = 0;
            continue;
        }

        start = (end - pos);

        // logger.logf("REMNANT:|%s|", cast(string)buffer[pos..end]);
        import core.stdc.string : memmove;
        memmove(buffer.ptr, (buffer.ptr + pos), (ubyte.sizeof * start));
    }
}


// ConnectionAttempt
/++
 +  Embodies the state of a connection attempt.
 +/
struct ConnectionAttempt
{
    import std.socket : Address;

    /// At what state in the connection process this attempt is currently at.
    enum State
    {
        preconnect,         /// About to connect.
        connected,          /// Successfully connected.
        delayThenReconnect, /// Failed to connect; should delay and retry.
        delayThenNextIP,    /// Failed to reconnect several times; next IP.
        noMoreIPs,          /// Exhausted all IPs anc could not connect.
        error,              /// Error connecting; should abort.
    }

    /// The current state of the attempt.
    State state;

    /// The IP that the attempt is trying to connect to.
    Address ip;

    /// The error message as thrown by an exception.
    string error;

    /// The number of retries so far towards this `ip`.
    uint numRetry;
}


// connectFiber
/++
 +  Fiber function that tries to connect to IPs in the `conn.ips` array,
 +  yielding at certain points throghout the process to let the calling function
 +  (here `kameloso.common.main`) output progress text to the local terminal.
 +
 +  It would make sense to just make this a single normal function, but then it
 +  would need knowledge of internals such as `kameloso.common.settings` that it
 +  really has no business with, separation of concerns-wise.
 +
 +  Params:
 +      conn = Reference to the currenct, unconnected `Connection`.
 +      abort = Reference to the current `abort` flag, which -- if set -- should
 +          make the function return.
 +/
void connectFiber(ref Connection conn, ref bool abort)
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, Socket, SocketException;

    assert((conn.ips.length > 0), "Tried to connect to an unresolved connection");
    assert(!conn.connected, "Tried to connect to a connected connection!");

    alias State = ConnectionAttempt.State;
    ConnectionAttempt attempt;

    yield(attempt);

    foreach (immutable i, ip; conn.ips)
    {
        attempt.ip = ip;

        Socket* socket = (ip.addressFamily == AddressFamily.INET6) ? &conn.socket6 : &conn.socket4;

        enum connectionRetries = 3;

        foreach (immutable retry; 0..connectionRetries)
        {
            if (abort) return;

            if ((i > 0) || (retry > 0))
            {
                import std.socket : SocketShutdown;
                socket.shutdown(SocketShutdown.BOTH);
                socket.close();
                conn.reset();
            }

            try
            {
                attempt.numRetry = retry;
                attempt.state = State.preconnect;
                yield(attempt);

                socket.connect(ip);

                // If we're here no exception was thrown, so we're connected
                attempt.state = State.connected;
                yield(attempt);
                assert(0);  // Should never get here
            }
            catch (const SocketException e)
            {
                switch (e.msg)
                {
                //case "Unable to connect socket: Connection refused":
                case "Unable to connect socket: Address family not supported by protocol":
                    attempt.state = State.error;
                    attempt.error = e.msg;
                    yield(attempt);
                    assert(0);  // Should never get here

                //case "Unable to connect socket: Network is unreachable":
                default:
                    // Don't delay for retrying on the last retry, drop down below
                    if (retry < (connectionRetries - 1))
                    {
                        attempt.state = State.delayThenReconnect;
                        yield(attempt);
                    }
                    break;
                }

            }
        }

        if (i+1 < conn.ips.length)
        {
            // Not last IP
            attempt.state = State.delayThenNextIP;
            yield(attempt);
        }
    }

    // All IPs exhausted
    attempt.state = State.noMoreIPs;
    yield(attempt);
}


// ResolveAttempt
/++
 +  Embodies the state of an address resolution attempt.
 +/
struct ResolveAttempt
{
    /// At what state the resolution process this attempt is currently at.
    enum State
    {
        preresolve,     /// About to resolve.
        success,        /// Successfully resolved.
        exception,      /// Failure, recoverable exception thrown.
        error,          /// Failure, unrecoverable exception thrown.
        failure,        /// Resolution failure; should abort.
    }

    /// The current state of the attempt.
    State state;

    /// The error message as thrown by an exception.
    string error;

    /// The number of retries so far towards his `address`.
    uint numRetry;
}


// resolveFiber
/++
 +  Given an address and a port, resolves these and builds an array of unique
 +  `Address` IPs.
 +
 +  Params:
 +      conn = Reference to the current `Connection`.
 +      address = String address to look up.
 +      port = Remote port build into the `Address`.
 +      useIPv6 = Whether to include resolved IPv6 addresses or not.
 +      abort = Reference bool which, if set, should make us abort and return.
 +/
void resolveFiber(ref Connection conn, const string address, const ushort port,
    const bool useIPv6, ref bool abort)
{
    import std.concurrency : yield;
    import std.socket : AddressFamily, SocketException, getAddress;

    enum resolveAttempts = 15;

    alias State = ResolveAttempt.State;
    ResolveAttempt attempt;

    yield(attempt);

    foreach (immutable i; 0..resolveAttempts)
    {
        if (abort) return;

        attempt.numRetry = i;

        with (AddressFamily)
        try
        {
            import std.algorithm.iteration : filter, uniq;
            import std.array : array;

            conn.ips = getAddress(address, port)
                .filter!(ip => (ip.addressFamily == INET) || ((ip.addressFamily == INET6) && useIPv6))
                .uniq!((a,b) => a.toString == b.toString)
                .array;

            attempt.state = State.success;
            yield(attempt);
            return;  // Should never get here
        }
        catch (const SocketException e)
        {
            switch (e.msg)
            {
            case "getaddrinfo error: Name or service not known":
            case "getaddrinfo error: Temporary failure in name resolution":
                // Assume net down, wait and try again
                attempt.state = State.exception;
                attempt.error = e.msg;
                yield(attempt);
                continue;

            default:
                attempt.state = State.error;
                attempt.error = e.msg;
                yield(attempt);
                assert(0);  // Should never get here
            }
        }
    }

    attempt.state = State.failure;
    yield(attempt);
}
