module example::server;
import c3ws, c3ws::ws;
import std::io;
import std::net::tcp, std::net::os;
import example::config;
import libc;

// TODO: consider submitting this definitions as a PR to c3c
const SignalFunction SIG_IGN = (SignalFunction)0x1;
const SignalFunction SIG_DFL = (SignalFunction)0x0;

const int CHUNK_SIZE = 1024;

fn void main() {
    $if !env::WIN32:
        Sigaction act = {};
        act.sa_handler = SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &act, null);
    $endif

    TcpServerSocket server = tcp::listen(config::HOST, config::PORT, 10, REUSEADDR)!!;

    io::printfn("Listening to %s:%d", config::HOST, config::PORT);
    usz temp_mark = allocator::temp().mark();
    while (try client = tcp::accept(&server)) {
        defer allocator::temp().reset(temp_mark);

        io::printfn("INFO: Accepted connection");
        Ws(<TcpSocket, false, CHUNK_SIZE>) ws = {
            .socket = client,
            .debug = true,
        };
        defer (void)ws.socket.close();

        if (catch error = ws.server_handshake()) {
            io::printfn("ERROR: handshake failed: %s", error);
            continue;
        }
        // TODO: Tuck sending the CLOSE frame under some abstraction of "Closing the WebSocket".
        // Maybe some sort of ws.close() method.
        defer (void)ws.send_frame(true, ws::OPCODE_CLOSE, {});

        // TODO: Turn example_server into an asynchronous echo server that just continuosly echos all the client messages
        // until the client closes the connection. I think some of the Autobahn Test Cases depends on this exact behavior.
        // This may require implementing proper periodic pinging of the clients and closing those who fell off.
        // (Which I believe is also part of some of the Autobahn Test Cases).
        Ws_Message! message = ws.read_message();
        if (catch error = message) {
            io::printfn("ERROR: could not read message from client: %s", error);
            continue;
        }
        io::printfn("INFO: Client sent: %d bytes", message.payload.len);
        (void)ws.send_message(message.kind, message.payload);
    }
}
