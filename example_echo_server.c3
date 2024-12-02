module example::echo::server;
import c3ws, c3ws::ws;
import std::io;
import std::net::tcp, std::net::os;
import std::thread;
import example::echo;
import example::config;
import libc;

// TODO: consider submitting these definitions as a PR to c3c
const SignalFunction SIG_IGN = (SignalFunction)0x1;
const SignalFunction SIG_DFL = (SignalFunction)0x0;

fn void main() {
    $if !env::WIN32:
        // TODO: C3 std uses send() under the hood. Send has cool flag MSG_NOSIGNAL that suppresses SIGPIPE.
        // Try to enable it and see if it makes this action redundant. If so, consider submitting PR to c3c.
        Sigaction act = {};
        act.sa_handler = SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &act, null);
    $endif

    // TODO: Turn example_server into an asynchronous echo server that just continuosly echos all the client messages
    // until the client closes the connection. I think some of the Autobahn Test Cases depends on this exact behavior.
    // This may require implementing proper periodic pinging of the clients and closing those who fell off.
    // (Which I believe is also part of some of the Autobahn Test Cases).
    TcpServerSocket server = tcp::listen(config::HOST, config::PORT, 10, REUSEADDR)!!;
    io::printfn("Listening to %s:%d", config::HOST, config::PORT);
    while ACCEPT: (try client = tcp::accept(&server)) {
        // TODO: apply SO_LINGER to the client sockets
        io::printfn("INFO: Accepted connection");
        Thread client_thread;
        client_thread.create(fn int(void *arg) {
            Ws(<TcpSocket>)! ws = c3ws::accept(<TcpSocket>)(*(TcpSocket*)arg);
            mem::free(arg);
            if (catch error = ws) {
                io::printfn("ERROR: could not accept WebSocket connection: %s", error);
                return 1;
            }
            ws.debug = true;
            echo::serve(<TcpSocket>)(ws);
            return 0;
        }, mem::new($typeof(client), client))!!;
    }
}
