.POSIX:

.PHONY: all
all:
	./support/do -c

.PHONY: install
install:
	./support/do -c install

.PHONY: uninstall
uninstall:
	./support/do -c uninstall

.PHONY: clean
clean:
	./support/do -c clean
