#! /bin/sh
set -eu
exec 1>&2

target="$1"
out="$3"

. ./config.inc

# check we are in the right place.
test -d ./support/

shlib_csrcs="shlib/shlib.c"
shlib_chdrs=""

if test "$WITH_READNOISE" = "y"
then
  shlib_csrcs="$(echo $shlib_csrcs readnoise/*.c)"
  shlib_chdrs="$(echo $shlib_chdrs readnoise/*.h)"
fi

shlib_objs="$(echo "$shlib_csrcs" | sed 's/\.c/\.o/g')"

v () {
  echo $@
  $@
}

case $target in
  all)
    redo-ifchange shlib.so
    ;;
  clean)
    v rm -f shlib.so $shlib_objs ./shlib/*.deps
    ;;
  install)
    redo-ifchange all
    mkdir -p "$PREFIX/bin/"
    mkdir -p "$PREFIX/lib/janetsh"
    install ./shlib.so "$PREFIX/lib/janetsh/"
    install ./sh.janet "$PREFIX/lib/janetsh/"
    install ./posixsh.janet "$PREFIX/lib/janetsh/"
    head -n 1 ./janetsh > "$PREFIX/bin/janetsh"
    echo "(array/concat module/paths [" >> "$PREFIX/bin/janetsh"
    echo "  [\"$PREFIX/lib/janetsh/:all:.janet\" :source]" >> "$PREFIX/bin/janetsh"
    echo "  [\"$PREFIX/lib/janetsh/:all:.:native:\" :native]])" >> "$PREFIX/bin/janetsh"
    tail -n +2 ./janetsh >> "$PREFIX/bin/janetsh"
    chmod +x "$PREFIX/bin/janetsh"
    ;;
  readnoise/*.o)
    cfile=readnoise/$(basename $target .o).c
    redo-ifchange $cfile $shlib_chdrs
    v $CC -fPIC $READLINE_CFLAGS $CFLAGS -c -o $out $cfile
    ;;
  shlib/*.o)
    cfile=shlib/$(basename $target .o).c
    redo-ifchange $cfile $shlib_chdrs
    v $CC -fPIC $JANET_HEADER_CFLAGS $READLINE_CFLAGS $CFLAGS -c -o $out $cfile
    ;;
  shlib.so)
    redo-ifchange $shlib_objs
    v $CC -shared $shlib_objs $LDFLAGS $READLINE_LDFLAGS -o $out
    ;;
  *)
    echo "don't know how to build $target"
    exit 1 ;;
esac
