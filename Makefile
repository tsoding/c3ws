all: build/autobahn_echo_client build/autobahn_echo_server build/example_send_client

build/example_send_client: build examples/send_client.c3 c3ws.c3 coroutine.c3
	c3c compile -l build/coroutine.a -O5 -o build/example_send_client examples/send_client.c3 c3ws.c3 coroutine.c3

build/autobahn_echo_client: build/coroutine.a test/autobahn/echo_client.c3 test/autobahn/echo.c3 test/autobahn/config.c3 c3ws.c3
	c3c compile -l build/coroutine.a -O5 -o build/autobahn_echo_client test/autobahn/echo_client.c3 test/autobahn/echo.c3 test/autobahn/config.c3 c3ws.c3 coroutine.c3

build/autobahn_echo_server: build/coroutine.a test/autobahn/echo_server.c3 test/autobahn/echo.c3 test/autobahn/config.c3 c3ws.c3
	c3c compile -l build/coroutine.a -O5 -o build/autobahn_echo_server test/autobahn/echo_server.c3 test/autobahn/echo.c3 test/autobahn/config.c3 c3ws.c3 coroutine.c3

build/coroutine.a: build/coroutine.o
	ar -rcs build/coroutine.a build/coroutine.o

build/coroutine.o: build coroutine.c
	gcc -Wall -Wextra -ggdb -o build/coroutine.o -c coroutine.c

build:
	mkdir -p build
