module example;
import c3ws;
import std::io;
import std::net, std::os, std::time, libc;
import std::thread;

// https://www.websocket.org/echo.html
// #define HOST "echo.websocket.org"
// #define SERVICE "80"
const ZString HOST = "localhost";
const ZString SERVICE = "6970";

def Socket = Fd;

fn uint! Socket.read(self, char[] buf) {
    return (uint)libc::read(self, &buf[0], buf.len);
}

fn uint! Socket.write(self, char[] buf) {
    return (uint)libc::write(self, &buf[0], buf.len);
}

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
    // Resources to destroy at the end of the function
    Socket sd = -1;
    AddrInfo *addrs = null;

    // TODO: move establishing plain and SSL connection to cwt

    // Establish plain connection
    {
        AddrInfo hints = {};
        hints.ai_family = os::AF_INET;
        hints.ai_socktype = os::SOCK_STREAM;
        hints.ai_protocol = 6;//os::IPPROTO_TCP;

        if (os::getaddrinfo(HOST, SERVICE, &hints, &addrs) < 0) {
            io::printf("ERROR: Could not resolved address of `%s`\n", HOST);
            return 1;
        }

        for (AddrInfo *addr = addrs; addr != null; addr = addr.ai_next) {
            sd = os::socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);

            if (sd == -1) {
                break;
            }

            if (os::connect((NativeSocket) sd, addr.ai_addr, addr.ai_addrlen) == 0) {
                break;
            }

            libc::close(sd);
            sd = -1;
        }

        if (sd == -1) {
            io::printf("Could not connect to %s:%s\n", HOST, SERVICE);
            return 1;
        }
    }

    Ws(<Socket, 100>) ws = {
        .socket = sd,
    };

    usz temp_mark = allocator::temp().mark();
    // WebSocket handshake with the server
    ws.client_handshake(HOST)!!;

    // Receiving frames
    {
        char[] payload = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.";

        ws.send_binary(payload)!!;
        while (try message = ws.read()) {
            log_message(message);
            thread::sleep(1*time::SEC);
            ws.send_binary(payload)!!;
            allocator::temp().reset(temp_mark);
        }
    }

    // TODO: use defer everywhere it’s needed
    libc::close(sd);

    return 0;
}
