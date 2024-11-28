#!/bin/sh

set -xe

c3c compile -O5 -o example_client example_client.c3 example_config.c3 c3ws.c3
c3c compile -o example_server example_server.c3 example_config.c3 c3ws.c3
