#!/bin/sh

set -xe

c3c compile -O5 -o example_send_client example_send_client.c3 example_config.c3 c3ws.c3
c3c compile -O5 -o example_echo_server example_echo_server.c3 example_config.c3 c3ws.c3
