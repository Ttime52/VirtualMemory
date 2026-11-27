CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic -std=c11

PROGRAMS := test_vma test_minor test_major

.PHONY: all clean

all: $(PROGRAMS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(PROGRAMS)
