module example::send::client;
import c3ws;
import std::io;
import std::net, std::os, std::time, libc;
import std::net::tcp;
import std::thread;

macro @shift(&xs) {
    var x = (*xs)[0];
    *xs = (*xs)[1..];
    return x;
}

fn void usage(String program_name)
{
    io::printfn("Usage: %s <host> <port> <message>", program_name);
}

fn int main(String[] args)
{
    // TODO: implement SSL connection example

    String program_name = @shift(args);

    if (args.len == 0) {
        usage(program_name);
        io::printfn("ERROR: no host is provided");
        return 1;
    }
    String host = @shift(args);

    if (args.len == 0) {
        usage(program_name);
        io::printfn("ERROR: no port is provided");
        return 1;
    }
    uint! port = @shift(args).to_integer(uint);
    if (catch error = port) {
        io::printfn("ERROR: port is not a valid integer: %s", error);
        return 1;
    }

    if (args.len == 0) {
        usage(program_name);
        io::printfn("ERROR: no message is provided");
        return 1;
    }
    String message = @shift(args);

    Ws(<TcpSocket>) ws = {
        .socket = tcp::connect(host, port)!!,
        .client = true,
    };
    defer {
        ws.send_frame(true, ws::OPCODE_CLOSE, {})!!;
        ws.socket.close()!!;
    }
    ws.client_handshake(string::tformat("%s:%d", host, port))!!;
    ws.send_text(message)!!;
    io::printfn("Message from server: %s", (String)ws.read_message()!!.payload);

    return 0;
}
