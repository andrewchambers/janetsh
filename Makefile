.POSIX:

include config.mk

.PHONY: all
all: shlib.so

SHLIB_HEADERS=\
  ./shlib/shlib_linenoise.h

SHLIB_SRC=\
	./shlib/shlib.c \
	./shlib/shlib_linenoise.c

SHLIB_OBJ=$(SHLIB_SRC:%.c=%.o)

shlib.so: $(SHLIB_OBJ)
	$(CC) -shared $(LDFLAGS) $(janetheadercflags) -I./shlib/ $(SHLIB_OBJ) -o $@

.PHONY: install
install:
	mkdir -p $(PREFIX)/bin/
	mkdir -p $(PREFIX)/lib/janetsh
	install ./shlib.so $(PREFIX)/lib/janetsh/
	install ./sh.janet $(PREFIX)/lib/janetsh/
	install ./janetsh $(PREFIX)/bin/
	sed -i '2i (array/concat module/paths ['  $(PREFIX)/bin/janetsh
	sed -i '3i ["$(PREFIX)/lib/janetsh/:all:.janet" :source]' $(PREFIX)/bin/janetsh
	sed -i '4i ["$(PREFIX)/lib/janetsh/:all:.:native:" :native]])' $(PREFIX)/bin/janetsh

.PHONY: clean
clean:
	rm -f $(SHLIB_OBJ) shlib.so