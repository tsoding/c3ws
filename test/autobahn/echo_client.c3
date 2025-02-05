module test::autobahn::echo::client;
import test::autobahn::echo,
       test::autobahn::config;
import c3ws;
import c3ws::async;
import std::net::tcp;

fn int main() {
    TcpSocket client = tcp::connect(config::HOST, config::PORT)!!;
    Ws(<AsyncTcpSocket>) ws = c3ws::connect(<AsyncTcpSocket>)(AsyncTcpSocket { 
        .inner = &client 
    }, string::tformat("%s:%d", config::HOST, config::PORT))!!;
    echo::serve(<AsyncTcpSocket>)(ws);
    return 0;
}
