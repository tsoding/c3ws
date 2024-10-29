module example::server;
import c3ws;
import std::io;
import std::net::tcp;
import example::config;

fn void main() {
    TcpServerSocket server = tcp::listen(config::HOST, config::PORT, 10)!!;
    io::printfn("Listening to %s:%d", config::HOST, config::PORT);
    usz temp_mark = allocator::temp().mark();
    while (try client = tcp::accept(&server)) {
        defer allocator::temp().reset(temp_mark);

        io::printfn("Accepted connection");
        Ws(<TcpSocket, 100>) ws = { .socket = client };
        defer ws.socket.close()!!;

        if (catch error = ws.server_handshake()) {
            io::printfn("ERROR: handshake failed: %s", error);
            continue;
        }
        char[]! message = ws.read();
        if (catch error = message) {
            io::printfn("ERROR: could not read message from client: %s", error);
            continue;
        }
        io::printfn("INFO: Client sent: %s", (String)message);
        if (catch error = ws.send_text((String)message)) {
            io::printfn("ERROR: send text failed: %s", error);
            continue;
        }
    }
}
