module example::echo::client;
import example::echo,
       example::config;
import c3ws;
import std::net::tcp;

fn int main() {
    TcpSocket client = tcp::connect(config::HOST, config::PORT)!!;
    Ws(<TcpSocket>) ws = c3ws::connect(<TcpSocket>)(client, string::tformat("%s:%d", config::HOST, config::PORT))!!;
    echo::serve(<TcpSocket>)(ws);
    return 0;
}
