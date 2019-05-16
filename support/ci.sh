#! /bin/sh

set -uex

janetver="dd1a199ebdd200231aeec96906d4eddd24f0321e"
janeturl="https://github.com/janet-lang/janet/archive/${janetver}.tar.gz"
cd .builds
curl "$janeturl" -L -o ./janet.tar.gz
tar xzf ./janet.tar.gz
cd "janet-${janetver}"
make clean
prefix=""
make
cd ../..
./configure --prefix="$(realpath ./.builds/janetsh)" --janet-header-cflags="-I$(realpath ./.builds/janet-${janetver}/src/include)"
make clean
make install
export PATH="$PATH:$(realpath ./.builds/janet-${janetver}/build)"
export PATH="$PATH:$(realpath ./.builds/janetsh/bin)"
./test/runner
