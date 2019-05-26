#! /bin/sh
set -eu
exec 1>&2

target="$1"
out="$3"

if ! test -d ./support
then
  echo "please build from the janetsh base directory."
  exit 1
fi

if ! test -f ./config.inc
then
  echo "please run configure first."
  exit 1
fi

. ./config.inc

shlib_csrcs="src/shlib/shlib.c"
shlib_chdrs=""

if test "$WITH_READNOISE" = "y"
then
  shlib_csrcs="$(echo $shlib_csrcs src/readnoise/*.c)"
  shlib_chdrs="$(echo $shlib_chdrs src/readnoise/*.h)"
fi

shlib_objs="$(echo "$shlib_csrcs" | sed 's/\.c/\.o/g')"

v () {
  echo $@
  $@
}

case $target in
  all)
    redo-ifchange src/shlib.so
    ;;
  install)
    redo-ifchange all
    mkdir -p "$PREFIX/bin/"
    mkdir -p "$PREFIX/lib/janetsh"
    install ./src/shlib.so "$PREFIX/lib/janetsh/"
    install ./src/*.janet "$PREFIX/lib/janetsh/"
    head -n 1 ./src/janetsh > "$PREFIX/bin/janetsh"
    echo "(array/concat module/paths [" >> "$PREFIX/bin/janetsh"
    echo "  [\"$PREFIX/lib/janetsh/:all:.janet\" :source]" >> "$PREFIX/bin/janetsh"
    echo "  [\"$PREFIX/lib/janetsh/:all:.:native:\" :native]])" >> "$PREFIX/bin/janetsh"
    tail -n +2 ./src/janetsh >> "$PREFIX/bin/janetsh"
    chmod +x "$PREFIX/bin/janetsh"
    ;;
  src/readnoise/*.o)
    cfile=src/readnoise/$(basename $target .o).c
    redo-ifchange $cfile $shlib_chdrs
    v $CC -fPIC $READLINE_CFLAGS $CFLAGS -c -o $out $cfile
    ;;
  src/shlib/*.o)
    cfile=src/shlib/$(basename $target .o).c
    redo-ifchange $cfile $shlib_chdrs
    v $CC -fPIC $JANET_HEADER_CFLAGS $READLINE_CFLAGS $CFLAGS -c -o $out $cfile
    ;;
  src/shlib.so)
    redo-ifchange $shlib_objs
    v $CC -shared $shlib_objs $LDFLAGS $READLINE_LDFLAGS -o $out
    ;;
  *)
    echo "don't know how to build $target"
    exit 1 ;;
esac
