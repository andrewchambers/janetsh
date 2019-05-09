#! /bin/sh

set -eux

CC=${CC:-clang}

buildmodule () {
  $CC -fPIC -Wall -Werror -shared -I ~/src/janet/src/include $1/*.c -o $1.so	
}

buildmodule unixy
