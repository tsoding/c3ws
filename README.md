# WebSocket library in C3

> [!WARNING]
> The library is not in production ready state yet

Initially translated from https://github.com/tsoding/cws

## Echo Server

```console
$ ./build.sh # We will use the official C3 build system eventually I swear
```

In one terminal:
```console
$ ./example_server
```

In another terminal
```console
$ ./example_client "Hello, World"
```

You can also connect to the server from a browser:
```console
$ firefox ./example_client.html
```
