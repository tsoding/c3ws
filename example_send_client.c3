module example::send::client;
import c3ws;
import std::io;
import std::net, std::os, std::time, libc;
import std::net::tcp;
import std::thread;
import example::config;

macro @shift(&xs) {
    var x = (*xs)[0];
    *xs = (*xs)[1..];
    return x;
}

fn int main(String[] args)
{
    // TODO: implement SSL connection example

    String program_name = @shift(args);
    if (args.len == 0) {
        io::printfn("Usage: %s <message>", program_name);
        io::printfn("ERROR: no message is provided");
        return 1;
    }

    String message = @shift(args);

    Ws(<TcpSocket>) ws = {
        .socket = tcp::connect(config::HOST, config::PORT)!!,
        .client = true,
    };
    defer {
        ws.send_frame(true, ws::OPCODE_CLOSE, {})!!;
        ws.socket.close()!!;
    }
    ws.client_handshake(string::tformat("%s:%d", config::HOST, config::PORT))!!;
    ws.send_text(message)!!;
    io::printfn("Message from server: %s", (String)ws.read_message()!!.payload);

    return 0;
}
