module example::echo(<Socket>);

import std::io;
import std::net::tcp;
import c3ws::ws;
import example::config;

fn void serve(Ws(<Socket>) ws) {
    usz temp_mark = allocator::temp().mark();
    defer {
        (void)ws.close();
        allocator::temp().reset(temp_mark);
    }

    String peer_who = ws.client ? "Server" : "Client";
    for ECHO: (usz i = 0; ; ++i) {
        Ws_Message! message = ws.read_message();
        if (catch error = message) {
            if (error == Ws_Error.CLOSE_FRAME_SENT) {
                io::printfn("INFO: %s closed connection", peer_who);
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
        io::printfn("INFO: %d: %s sent: %d bytes", i, peer_who, message.payload.len);
        (void)ws.send_message(message.kind, message.payload);
        allocator::temp().reset(temp_mark);
    }
}
