CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic -std=c11

PROGRAMS := test_vma test_minor test_major
BASH ?= bash

.PHONY: all clean check-cli

all: $(PROGRAMS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(PROGRAMS)

check-cli:
	$(BASH) test_cli.sh
