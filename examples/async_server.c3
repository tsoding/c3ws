import test::autobahn::config;
import c3ws;
import libc;
import std::net::tcp;
import std::net::os;
import std::io;

// TODO: consider submitting these definitions as a PR to c3c
const SignalFunction SIG_IGN = (SignalFunction)0x1;
const SignalFunction SIG_DFL = (SignalFunction)0x0;

fn int main() {
    $if !env::WIN32:
        // TODO: C3 std uses send() under the hood. Send has cool flag MSG_NOSIGNAL that suppresses SIGPIPE.
        // Try to enable it and see if it makes this action redundant. If so, consider submitting PR to c3c.
        Sigaction act = {};
        act.sa_handler = SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &act, null);
    $endif

    TcpServerSocket server = tcp::listen(config::HOST, config::PORT, 10, REUSEADDR)!!;
    io::printfn("Listening to %s:%d", config::HOST, config::PORT);
    while ACCEPT: (true) {
        // TODO: the unwrap optimized out bug
        // TODO: non-blocking TcpServerSocket must return Would_Block on tcp::accept()
        TcpSocket client = tcp::accept(&server)!!;
        Ws(<TcpSocket>)! ws = c3ws::accept(<TcpSocket>)(client);
        if (catch error = ws) {
            io::printfn("ERROR: could not accept WebSocket connection: %s", error);
            return 1;
        }
        ws.socket.sock.set_non_blocking(true)!!;
        Read_Frame_Header_Task(<TcpSocket>) task;
        task.reset();
        while (true) {
            if (catch error = task.update(&ws)) {
                case IoError.WOULD_BLOCK:
                    io::printfn("INFO: Read_Frame_Header_Task in progress: %s", task.state);
                default:
                    io::printfn("ERROR: Read_Frame_Header_Task has failed: %s", error);
                    return 1;
            } else {
                io::printfn("INFO: Read_Frame_Header_Task finished: FIN(%d), OPCODE(%s), RSV(%d%d%d), PAYLOAD_LEN: %d",
                    task.frame_header.fin,
                    task.frame_header.opcode.name(),
                    task.frame_header.rsv1, task.frame_header.rsv2, task.frame_header.rsv3,
                    task.frame_header.payload_len);
                return 0;
            }
        }
    }
}
