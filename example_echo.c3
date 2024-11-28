module example::echo(<CLIENT>);

import std::io;
import std::net::tcp;
import c3ws::ws;
import example::config;

// TODO: consider submitting these definitions as a PR to c3c
const CInt SHUT_RD = 0;
const CInt SHUT_WR = 1;
const CInt SHUT_RDWR = 2;
extern fn CInt shutdown(CInt sockfd, CInt how);

const int CHUNK_SIZE = 1024;

fn void serve(TcpSocket socket) {
    usz temp_mark = allocator::temp().mark();
    defer {
        // Base on the ideas from https://blog.netherlabs.nl/articles/2009/01/18/the-ultimate-so_linger-page-or-why-is-my-tcp-not-reliable
        // Informing the OS that we are not planning to send anything anymore
        shutdown(socket.sock, SHUT_WR);
        // Depleting input before closing socket, so the OS does not send RST just because we have some input pending on close
        char[1024] buffer;
        while (try n = socket.read(buffer[0..])) {
            if (n == 0) break;
        }

        // TODO: consider depleting the send buffer on Linux with ioctl(fd, SIOCOUTQ, &outstanding)

        // Actually destroying the socket
        (void)socket.close();
        allocator::temp().reset(temp_mark);
    }

    Ws(<TcpSocket, CLIENT, CHUNK_SIZE>) ws = {
        .socket = socket,
        .debug = true,
    };

    $if CLIENT:
        const String PEER_WHO = "Server";
        if (catch error = ws.client_handshake(string::tformat("%s:%d", config::HOST, config::PORT))) {
            io::printfn("ERROR: handshake failed: %s", error);
            return;
        }
    $else
        const String PEER_WHO = "Client";
        if (catch error = ws.server_handshake()) {
            io::printfn("ERROR: handshake failed: %s", error);
            return;
        }
    $endif

    // TODO: Turn example_server into an asynchronous echo server that just continuosly echos all the client messages
    // until the client closes the connection. I think some of the Autobahn Test Cases depends on this exact behavior.
    // This may require implementing proper periodic pinging of the clients and closing those who fell off.
    // (Which I believe is also part of some of the Autobahn Test Cases).
    for ECHO: (usz i = 0; ; ++i) {
        Ws_Message! message = ws.read_message();
        if (catch error = message) {
            if (error == Ws_Error.CLOSE_FRAME_SENT) {
                io::printfn("INFO: %s closed connection", PEER_WHO);
            } else {
                io::printfn("ERROR: %s connection failed: %s", PEER_WHO, error);
            }
            // TODO: Tuck sending the CLOSE frame under some abstraction of "Closing the WebSocket".
            // Maybe some sort of ws.close() method.
            // TODO: The server may give a reason of the close via the status code
            // See RFC6466, Section 7.4
            defer (void)ws.send_frame(true, ws::OPCODE_CLOSE, {});
            break ECHO;
        }
        io::printfn("INFO: %d: %s sent: %d bytes", i, PEER_WHO, message.payload.len);
        (void)ws.send_message(message.kind, message.payload);
        allocator::temp().reset(temp_mark);
    }
}
