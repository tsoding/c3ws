#!/bin/sh

set -xe

mkdir -p build/

c3c compile -O5 -o build/example_send_client examples/send_client.c3 c3ws.c3
c3c compile -O5 -o build/autobahn_echo_server test/autobahn/echo_server.c3 test/autobahn/echo.c3 test/autobahn/config.c3 c3ws.c3
c3c compile -O5 -o build/autobahn_echo_client test/autobahn/echo_client.c3 test/autobahn/echo.c3 test/autobahn/config.c3 c3ws.c3
