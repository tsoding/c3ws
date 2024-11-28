module example::echo::client;
import example::echo,
       example::config;
import c3ws;
import std::net::tcp;

fn int main() {
    TcpSocket client = tcp::connect(config::HOST, config::PORT)!!;
    echo::serve(<true>)(client);
    return 0;
}
