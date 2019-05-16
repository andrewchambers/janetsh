#! /bin/sh

set -uex

janetver="dd1a199ebdd200231aeec96906d4eddd24f0321e"
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
./configure --prefix="$prefix" --janet-header-cflags="-I$(readlink -f ./ci_builds/janet-${janetver}/src/include)"
make clean
make install
export PATH="$prefix/bin:$PATH"
./test/runner
