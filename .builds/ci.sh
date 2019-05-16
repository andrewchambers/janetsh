#! /bin/sh

set -uex

janetrel="0.5.0"
janeturl="https://github.com/janet-lang/janet/archive/v${janetrel}.tar.gz"
cd .builds
curl "$janeturl" -L -o ./janet.tar.gz
tar xzf ./janet.tar.gz
cd "janet-${janetrel}"
make clean
prefix=""
make
cd ../..
./configure --prefix="$(realpath ./.builds/janetsh)" --janet-header-cflags="-I$(realpath ./.builds/janet-${janetrel}/src/include)"
make clean
make install
export PATH="$PATH:$(realpath ./.builds/janet-${janetrel}/build):$(realpath ./.builds/janetsh/bin)"
./test/runner
