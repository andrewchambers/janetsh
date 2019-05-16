.POSIX:

.PHONY: all
all:
	./support/do -c

.PHONY: install
install:
	./support/do -cx install

.PHONY: clean
clean:
	./support/do -c clean
