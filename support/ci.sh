#! /bin/sh

set -uex

janetver="98c46fcfb1bd9b456a728f83a71b954d6c6cfc4b"
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
