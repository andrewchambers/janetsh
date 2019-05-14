.POSIX:


-include config.mk

.PHONY: all
all: shlib.so

SHLIB_HEADERS=\
  ./shlib/shlib_linenoise.h

SHLIB_SRC=\
	./shlib/shlib.c \
	./shlib/shlib_linenoise.c

SHLIB_OBJ=$(SHLIB_SRC:%.c=%.o)

shlib.so: $(SHLIB_OBJ) $(SHLIB_HEADERS)
	$(CC) $(LDFLAGS) $(janetheadercflags) -I./shlib/ $(SHLIB_OBJ) -o $@	

.PHONY: clean
clean:
	rm -f $(SHLIB_OBJ) shlib.so