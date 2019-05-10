#! /bin/sh

set -eux

CC=${CC:-clang}

buildmodule () {
  $CC -fPIC -Wall -Werror -shared $(pkg-config --cflags janet) $(pkg-config --cflags --libs linenoise) $1/*.c -o $1.so	
}

buildmodule shlib

