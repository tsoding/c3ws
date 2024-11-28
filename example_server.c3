module example::server;
import c3ws, c3ws::ws;
import std::io;
import std::net::tcp, std::net::os;
import example::config;
import libc;

// TODO: consider submitting these definitions as a PR to c3c
const SignalFunction SIG_IGN = (SignalFunction)0x1;
const SignalFunction SIG_DFL = (SignalFunction)0x0;
const CInt SHUT_RD = 0;
const CInt SHUT_WR = 1;
const CInt SHUT_RDWR = 2;
extern fn CInt shutdown(CInt sockfd, CInt how);

const int CHUNK_SIZE = 1024;

fn void ws_echo_server(TcpSocket client) {
    usz temp_mark = allocator::temp().mark();
    defer {
        // Base on the ideas from https://blog.netherlabs.nl/articles/2009/01/18/the-ultimate-so_linger-page-or-why-is-my-tcp-not-reliable
        // Informing the OS that we are not planning to send anything anymore
        shutdown(client.sock, SHUT_WR);
        // Depleting input before closing socket, so the OS does not send RST just because we have some input pending on close
        char[1024] buffer;
        while (try n = client.read(buffer[0..])) {
            if (n == 0) break;
        }

        // TODO: consider depleting the send buffer on Linux with ioctl(fd, SIOCOUTQ, &outstanding)

        // Actually destroying the socket
        (void)client.close();
        allocator::temp().reset(temp_mark);
    }

    Ws(<TcpSocket, false, CHUNK_SIZE>) ws = {
        .socket = client,
        .debug = true,
    };

    if (catch error = ws.server_handshake()) {
        io::printfn("ERROR: handshake failed: %s", error);
        return;
    }

    // TODO: Turn example_server into an asynchronous echo server that just continuosly echos all the client messages
    // until the client closes the connection. I think some of the Autobahn Test Cases depends on this exact behavior.
    // This may require implementing proper periodic pinging of the clients and closing those who fell off.
    // (Which I believe is also part of some of the Autobahn Test Cases).
    for ECHO: (usz i = 0; ; ++i) {
        Ws_Message! message = ws.read_message();
        if (catch error = message) {
            if (error == Ws_Error.CLOSE_FRAME_SENT) {
                io::printfn("INFO: Client closed connection");
            } else {
                io::printfn("ERROR: Client connection failed: %s", error);
            }
            // TODO: Tuck sending the CLOSE frame under some abstraction of "Closing the WebSocket".
            // Maybe some sort of ws.close() method.
            // TODO: The server may give a reason of the close via the status code
            // See RFC6466, Section 7.4
            defer (void)ws.send_frame(true, ws::OPCODE_CLOSE, {});
            break ECHO;
        }
        io::printfn("INFO: %d: Client sent: %d bytes", i, message.payload.len);
        (void)ws.send_message(message.kind, message.payload);
        allocator::temp().reset(temp_mark);
    }
}

fn void main() {
    $if !env::WIN32:
        // TODO: C3 std uses send() under the hood. Send has cool flag MSG_NOSIGNAL that suppresses SIGPIPE.
        // Try to enable it and see if it makes this action redundant. If so, consider submitting PR to c3c.
        Sigaction act = {};
        act.sa_handler = SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &act, null);
    $endif

    TcpServerSocket server = tcp::listen(config::HOST, config::PORT, 10, REUSEADDR)!!;
    io::printfn("Listening to %s:%d", config::HOST, config::PORT);
    while ACCEPT: (try client = tcp::accept(&server)) {
        // TODO: apply SO_LINGER to the client sockets
        io::printfn("INFO: Accepted connection");
        ws_echo_server(client);
    }
}
