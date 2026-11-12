CFLAGS ?= -O2 -Wall -Wextra -D_GNU_SOURCE
LDLIBS += -pthread
all: mc6test
mc6test: mc6test.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)
clean:
	rm -f mc6test
