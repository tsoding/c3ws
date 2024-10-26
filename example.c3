module example;
import c3ws;
import std::io;
import std::net, std::os, std::time, libc;
import std::net::tcp;
import std::thread;

// https://www.websocket.org/echo.html
// #define HOST "echo.websocket.org"
// #define SERVICE "80"
const String HOST = "localhost";
const uint PORT = 6970;

fn void log_message(char[] message)
{
    io::printf("message: ");
    foreach (x: message) {
        io::printf("0x%02X ", x);
    }
    io::printf("\n");
    io::printf("------------------------------\n");
}

fn int main()
{
    // TODO: move establishing plain and SSL connection to c3ws

    Ws(<TcpSocket, 100>) ws = {
        .socket = tcp::connect(HOST, PORT)!!,
    };
    defer ws.socket.close()!!;

    usz temp_mark = allocator::temp().mark();

    ws.client_handshake(HOST)!!;

    char[] payload = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.";

    ws.send_binary(payload)!!;
    while (try message = ws.read()) {
        log_message(message);
        thread::sleep(1*time::SEC);
        ws.send_binary(payload)!!;
        allocator::temp().reset(temp_mark);
    }

    return 0;
}
