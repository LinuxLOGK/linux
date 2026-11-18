CFLAGS ?= -O2 -Wall -Wextra -D_GNU_SOURCE
LDLIBS += -pthread
all: mc6test
mc6test: mc6test.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)
# 공유 라이브러리를 읽을 수 없는 최소 게스트·failslab 시험용. 같은 이름(mc6test)으로 정적 빌드 (항상 다시 빌드)
static: mc6test.c
	$(CC) $(CFLAGS) -static -o mc6test $< $(LDLIBS)
clean:
	rm -f mc6test
.PHONY: all static clean
