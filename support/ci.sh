#! /bin/sh

set -uex

janetver="6e8beff0a0eb829eb4f4f55df53d97c5a9815e29"
janeturl="https://github.com/janet-lang/janet/archive/${janetver}.tar.gz"
mkdir -p ci_builds
prefix="$(readlink -f ./ci_builds)/installed"
mkdir -p "$prefix"
cd ci_builds
curl "$janeturl" -L -o ./janet.tar.gz
tar xzf ./janet.tar.gz
cd "janet-${janetver}"
meson . meson --prefix="$prefix"
cd meson
ninja install
cd ../../../
./configure --prefix="$prefix" --janet-header-cflags="-I$(readlink -f ./ci_builds/janet-${janetver}/src/include)" --with-readnoise
make install
export PATH="$prefix/bin:$PATH"
./test/runner
