// This is a simple echo loop that reads messages from the WebSocket and sends them back.
// It can be used for both Servers and Clients for testing.
module test::autobahn::echo(<Socket>);

import std::io;
import std::net::tcp;
import c3ws::ws;
import test::autobahn::config;
import coroutine;

fn void serve(Ws(<Socket>) ws) {
    usz temp_mark = ws.temp.mark();
    defer (void)ws.close();

    String peer_who = ws.client ? "Server" : "Client";
    for ECHO: (usz i = 0; ; ++i) {
        Ws_Message! message = ws.read_message();
        if (catch error = message) {
            if (error == Ws_Error.CLOSE_FRAME_SENT) {
                io::printfn("[%d] INFO: %s closed connection", coroutine::id(), peer_who);
            } else {
                io::printfn("ERROR: %s connection failed: %s", peer_who, error);
            }
            // TODO: Tuck sending the CLOSE frame under some abstraction of "Closing the WebSocket".
            // Maybe some sort of ws.close() method.
            // TODO: The sender may give a reason of the close via the status code
            // See RFC6466, Section 7.4
            (void)ws.send_frame(true, ws::OPCODE_CLOSE, {});
            break ECHO;
        }
        io::printfn("[%d] INFO: %d: %s sent: %d bytes", coroutine::id(), i, peer_who, message.payload.len);
        (void)ws.send_message(message.kind, message.payload);
        ws.temp.reset(temp_mark);
    }
}
