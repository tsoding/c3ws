module test::autobahn::echo::server;
import c3ws, c3ws::ws;
import std::io;
import std::net::tcp, std::net::os;
import std::thread;
import test::autobahn::echo;
import test::autobahn::config;
import libc;
import coroutine;

// TODO: consider submitting these definitions as a PR to c3c
const SignalFunction SIG_IGN = (SignalFunction)0x1;
const SignalFunction SIG_DFL = (SignalFunction)0x0;

fn int main() {
    coroutine::init();
    $if !env::WIN32:
        // TODO: C3 std uses send() under the hood. Send has cool flag MSG_NOSIGNAL that suppresses SIGPIPE.
        // Try to enable it and see if it makes this action redundant. If so, consider submitting PR to c3c.
        Sigaction act = {};
        act.sa_handler = SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &act, null);
    $endif

    TcpServerSocket server = tcp::listen(config::HOST, config::PORT, 10, REUSEADDR)!!;
    server.sock.set_non_blocking(true)!!;
    io::printfn("Listening to %s:%d", config::HOST, config::PORT);
    while ACCEPT: (true) {
        coroutine::sleep_read(server.sock);
        TcpSocket client = tcp::accept(&server)!!;
        client.sock.set_non_blocking(true)!!;

        // TODO: apply SO_LINGER to the client sockets
        coroutine::go(fn void(void *arg) {
            TcpSocket* client = (TcpSocket*)arg;
            defer free(client);

            io::printfn("[%d] INFO: Accepted connection", coroutine::id());
            Ws(<AsyncTcpSocket>)! ws = c3ws::accept(<AsyncTcpSocket>)(AsyncTcpSocket {
                .tcp_socket = client,
            });
            if (catch error = ws) {
                io::printfn("ERROR: could not accept WebSocket connection: %s", error);
                return;
            }
            ws.debug = true;
            echo::serve(<AsyncTcpSocket>)(ws);
        }, @clone(client));
    }
}
