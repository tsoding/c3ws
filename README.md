# WebSocket library in C3

> [!WARNING]
> The library is not in production ready state yet

Initially translated from https://github.com/tsoding/cws

## Echo Server

```console
$ make
```

In one terminal:
```console
$ ./build/autobahn_echo_server
```

In another terminal
```console
$ ./build/example_send_client "Hello, World" localhost 6969
```

You can also connect to the server from a browser:
```console
$ firefox ./tools/example_send_client.html
```
