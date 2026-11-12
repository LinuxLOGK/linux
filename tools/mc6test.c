/*
 * mc6test - IPv6 멀티캐스트 가입/탈퇴/필터/송수신 정확성 fixture 도구 (S 담당 개발용)
 *
 * 수신(rx netns 안에서):
 *   mc6test rx --port 7000 [--mcall 0|1] --join GROUP[@IFNAME] ... [--join-src GROUP@IFNAME=SRC]
 *              [--drop GROUP[@IFNAME]] [--count N] [--timeout SEC] [--close]
 *   가입 호출마다 "join <group> <if> rc=<0|-1> errno=<n>" 를 출력하고,
 *   N 개 수신하거나 timeout 까지 "recv seq=<n> group=<g> src=<s>" 를 출력한다.
 *   --drop 은 모든 --join 뒤에 실행된다 (사례 4, 6).
 *   --many N GROUPBASE : GROUPBASE 의 하위 16비트를 0..N-1 로 바꾼 N 개 그룹에 가입 (사례 10~14, 19)
 *
 *   추가 옵션 (fixture 사례 01~20):
 *   --block GROUP@IF=SRC : 가입 후 MCAST_BLOCK_SOURCE (ASM/EXCLUDE 가입에 출발지 차단)
 *   --drop-many K        : --many 로 가입한 것 중 앞에서 K 개(k=0..K-1) 탈퇴
 *   --addrform           : 가입 후 ::ffff:127.0.0.1 포트 9 로 connect, IPV6_ADDRFORM=AF_INET
 *   --hold SEC           : 가입/탈퇴/addrform 후, 수신 전에 "# ready pid=<pid>" 출력하고 SEC 초 대기
 *                          (--hold 0 은 대기 없이 ready 만 출력 → 스크립트 동기화용)
 *   --churn N GROUP@IF   : 수신 중 별도 스레드가 같은 소켓으로 GROUP 가입/탈퇴를 N 회 반복.
 *                          그 그룹의 recv 줄은 "#" 접두사(수신 수가 비결정적), total/--count 에서 제외
 *   --wa N BASE@IF       : 소켓 N 개, i 번째는 BASE 하위 16비트=i 그룹 가입, 포트 (--port)+i 에 bind.
 *                          epoll 로 수신하고 소켓별 수신 수를 출력 (W_A 형태)
 *   --sorted             : recv 줄을 즉시 출력하지 않고 마지막에 (group, seq) 순으로 정렬해 출력
 *   --rejoin             : drop-many 뒤에 --many 의 N 개 그룹에 다시 가입 (사례 21)
 *   --omem               : 단계마다 getsockopt(SO_MEMINFO) 의 SK_MEMINFO_OPTMEM(sk_omem_alloc) 을
 *                          "omem=<n> stage=<단계>" 로 출력. 단계: joined(join/many 뒤) dropped(drop/drop-many 뒤)
 *                          rejoined(rejoin 뒤) addrform_before/addrform_after hold(--hold 의 ready 직전)
 *   처리 순서: mcall → bind → join/join-src(인자 순) → many → [joined] → block → drop → drop-many
 *             → [dropped] → rejoin → [rejoined] → addrform → close → [hold] hold → churn 시작 → 수신
 *
 *   추가 옵션 (fixture 사례 23~37, 소켓 해시 테이블이 있는 상태):
 *   --fill N BASE@IF     : BASE 의 하위 16비트부터 N 개 그룹에 MCAST_JOIN_GROUP. --join/--join-src 와 인자 순서대로
 *                          수행되므로 시험 가입 앞(pre)/뒤(post) 어디든 둘 수 있다.
 *                          "fill <BASE> n=<N> if=<n> ok=<k> failed=<f>[ first_fail_k=<k> errno=<e>]" 출력
 *   --unfill N BASE@IF   : 같은 범위를 MCAST_LEAVE_GROUP. 역시 인자 순서대로 수행. 출력은 "unfill ..."
 *   --mark STAGE         : 인자 순서 위치에서 "omem=<n> stage=<STAGE>" 출력 (--omem 일 때만)
 *   --msfilter GROUP@IF=include|exclude:SRC[,SRC...] : MCAST_MSFILTER setsockopt (struct group_filter).
 *                          @IF 를 빼면 gf_interface=0. block 뒤, drop 앞에 수행하고 [msfilter] 단계 omem
 *   --msfget GROUP@IF    : MCAST_MSFILTER getsockopt, 모드와 소스 목록 출력 (msfilter 뒤)
 *   --churn-rejoin N GROUP@IF : 수신 중 별도 스레드가 이미 가입한 GROUP 을 탈퇴/재가입 N 회 (끝나면 가입 상태).
 *                          GROUP 의 recv 줄은 --churn 처럼 "#" 접두사, 끝나면 [churned] 단계 omem
 *   --churn-fill N K BASE@IF  : 수신 중 별도 스레드가 "BASE 부터 K 개 가입 → K 개 전부 탈퇴" 를 N 회 반복,
 *                          끝나면 [churned] 단계 omem
 *   --phase2 ...         : 이 뒤의 인자는 2단계. 1단계 수신이 끝나면(정렬 출력·total= 까지) "phase2" 를 출력하고
 *                          2단계 인자 중 --join --join-src --drop --leave-src --block --fill --unfill --mark
 *                          --msfilter --msfget 을 인자 순서대로 수행한 뒤 "# ready2 pid=<pid>" 출력 후
 *                          2단계 --count/--timeout(기본 -1/3)/--sorted 로 다시 수신하고 total= 출력.
 *                          2단계 --min-seq S: seq < S 인 패킷(1단계 송신이 늦게 도착한 것)은 "# stale recv ..." 로만
 *                          출력하고 세지 않는다.
 *                          churn 은 1단계에서 끝나므로 2단계 recv 줄에는 "#" 를 붙이지 않는다.
 *   --leave-src GROUP@IF=SRC : MCAST_LEAVE_SOURCE_GROUP (2단계에서만)
 *   --post ...           : (--phase2 안에서만) 이 뒤의 인자는 2단계 수신·total= 출력 뒤에 인자 순서대로 수행
 *                          (--phase2 와 같은 동작 인자). 앞에 "post" 줄 출력
 *
 *   추가 옵션 (fixture 사례 20, 할당 실패 주입):
 *   --make-it-fail 0|1   : /proc/self/make-it-fail 에 기록 (failslab task-filter=Y 일 때 이 프로세스의 할당만
 *                          실패 대상). --join/--fill/--mark 와 같이 인자 순서대로 수행, --phase2/--post 에서도 가능.
 *                          "make_it_fail=<v> rc=<0|-1> errno=<n>" 출력
 *   (위 옵션이 없으면 기존 사례 01~22 의 동작과 출력은 그대로)
 *
 *   추가 옵션 (송신 완료와 수신 종료 동기화):
 *   --sync-grace MS      : 수신 종료를 스크립트 신호에 맞춘다. 1단계 수신은 SIGUSR1, 2단계(--phase2) 수신은
 *                          SIGUSR2 를 받기 전까지 --timeout 이 지나도 끝나지 않고(상한 --timeout+60초),
 *                          신호를 받으면 max(--timeout 끝, 신호 + MS) 에 끝난다 (--count 도달 시에는 바로 끝).
 *                          스크립트는 그 단계의 송신이 모두 끝난 뒤 신호를 보낸다. 다른 단계의 신호는 무시.
 *                          이 옵션이 없으면 SIGUSR1/2 는 기본 동작(종료)이고 수신 시간은 기존과 같다.
 *   수신 단계마다 "# rx_start phase=<k> t=<epoch>" 와 "# rx_end phase=<k> reason=<count|timeout|sync|cap|error>
 *   got=<n> t=<epoch>" 를 출력한다 (# 줄이므로 판정·diff 에 영향 없음).
 *
 * TCP 리스닝 소켓 복제(사례 22, rx netns 안에서):
 *   mc6test tcp --port 7100 --join GROUP@IF ... --conn v6|v4
 *     [::]:port 에 listen(V6ONLY=0) → 가입 → [listen] → 같은 프로세스에서 접속
 *     (v6: [::1]:port, v4: AF_INET 소켓으로 127.0.0.1:port → 서버 쪽은 v4-mapped) → accept
 *     → [accepted: 부모, 자식] → 자식 close → [child_closed: 부모] → 부모 close → 클라이언트 close
 *     [..] 마다 "omem=<n> stage=<단계> sock=parent|child" 출력 (항상)
 *     listen / child_closed / parent_closed 에서 각 --join 그룹의 장치 가입 여부를 이 프로세스의 netns 의
 *     /proc/net/igmp6 로 읽어 "maddr <veth1|dummy0> <group>=yes|no stage=<단계>" 출력 (스크립트와 동기화 불필요)
 *     전체가 10초 안에 끝나지 않으면 SIGALRM 으로 종료 (종료 코드 142)
 *   TCP 는 IPV6_ADD_MEMBERSHIP 이 -EPROTO 라서 MCAST_JOIN_GROUP 으로 가입한다 (do_join 과 같음).
 *
 * 송신(tx netns 안에서):
 *   mc6test tx --port 7000 --dev veth0 --group GROUP --count N [--src SRCADDR] [--seq-start S]
 *   mc6test tx --port 7000 --dev veth0 --many N BASEGROUP [--port-step 1] [--count C]
 *     → 하위 16비트를 0..N-1 로 바꾼 그룹 각각에 C(기본 1)개, 포트는 port + i*port-step
 *   payload: "seq=<n>" 텍스트. 응답을 기다리지 않는다.
 *
 * 출력 규칙: 시각·pid 등 비결정적 값은 "#" 로 시작하는 줄에만 쓴다 (diff 에서 제외).
 *
 * 예) 사례 1
 *   sudo ip netns exec rx ./mc6test rx --port 7000 --mcall 0 --join ff15::1@veth1 --count 5 --timeout 3 &
 *   sudo ip netns exec tx ./mc6test tx --port 7000 --dev veth0 --group ff15::1 --count 5
 *   sudo ip netns exec tx ./mc6test tx --port 7000 --dev veth0 --group ff15::2 --count 5   # 미가입, 0개 수신이어야 함
 *
 * 사례 5 (source filter, 두 인터페이스):
 *   rx: --join-src ff15::5@veth1=fd00::1 --join-src ff15::5@dummy0=fd00::9
 *   tx: --group ff15::5 --src fd00::1 ... 그리고 --src fd00::9 (tx 에 fd00::9 주소를 먼저 추가)
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef MCAST_JOIN_GROUP
#define MCAST_JOIN_GROUP 42
#define MCAST_JOIN_SOURCE_GROUP 46
#define MCAST_LEAVE_GROUP 45
#endif
#ifndef MCAST_BLOCK_SOURCE
#define MCAST_BLOCK_SOURCE 43
#endif
#ifndef IPV6_MULTICAST_ALL
#define IPV6_MULTICAST_ALL 29
#endif
#ifndef IPV6_ADDRFORM
#define IPV6_ADDRFORM 1
#endif
#ifndef SO_MEMINFO
#define SO_MEMINFO 55
#endif
#ifndef MCAST_LEAVE_SOURCE_GROUP
#define MCAST_LEAVE_SOURCE_GROUP 47
#endif
#ifndef MCAST_MSFILTER
#define MCAST_MSFILTER 48
#endif
#ifndef MCAST_INCLUDE
#define MCAST_EXCLUDE 0
#define MCAST_INCLUDE 1
#endif
#if __has_include(<linux/sock_diag.h>)
#include <linux/sock_diag.h>
#else
#include <linux/types.h>
enum { SK_MEMINFO_OPTMEM = 6, SK_MEMINFO_VARS = 9 };
#endif

static void die(const char *m) { perror(m); exit(2); }

/* SO_MEMINFO 의 SK_MEMINFO_OPTMEM = sk->sk_omem_alloc (가입 항목·sflist 등 sock_kmalloc 계상분) */
static int g_omem;
static void print_omem(int fd, const char *stage, const char *sock)
{
	__u32 mi[SK_MEMINFO_VARS];
	socklen_t len = sizeof(mi);
	memset(mi, 0, sizeof(mi));
	if (getsockopt(fd, SOL_SOCKET, SO_MEMINFO, mi, &len) || len <= SK_MEMINFO_OPTMEM * sizeof(__u32))
		printf("omem=NA stage=%s%s%s errno=%d\n", stage, sock ? " sock=" : "", sock ? sock : "", errno);
	else
		printf("omem=%u stage=%s%s%s\n", mi[SK_MEMINFO_OPTMEM], stage, sock ? " sock=" : "", sock ? sock : "");
	fflush(stdout);
}
static void rx_omem(int fd, const char *stage) { if (g_omem) print_omem(fd, stage, NULL); }

static int parse_group(const char *s, struct in6_addr *a, unsigned *ifidx)
{
	char buf[128];
	strncpy(buf, s, sizeof(buf) - 1); buf[sizeof(buf) - 1] = 0;
	char *at = strchr(buf, '@');
	*ifidx = 0;
	if (at) { *at = 0; *ifidx = if_nametoindex(at + 1); if (!*ifidx) { fprintf(stderr, "no iface %s\n", at + 1); return -1; } }
	if (inet_pton(AF_INET6, buf, a) != 1) { fprintf(stderr, "bad addr %s\n", buf); return -1; }
	return 0;
}

static void fill_ss(struct sockaddr_storage *ss, const struct in6_addr *a)
{
	struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)ss;
	memset(ss, 0, sizeof(*ss));
	s6->sin6_family = AF_INET6;
	s6->sin6_addr = *a;
}

/* BASE 의 하위 16비트를 k 로 바꾼 그룹 */
static struct in6_addr nth_group(const struct in6_addr *base, int k)
{
	struct in6_addr g = *base;
	g.s6_addr[14] = (k >> 8) & 0xff; g.s6_addr[15] = k & 0xff;
	return g;
}

static int group_req_op(int fd, int op, const struct in6_addr *g, unsigned ifidx)
{
	struct group_req gr; memset(&gr, 0, sizeof(gr));
	gr.gr_interface = ifidx; fill_ss(&gr.gr_group, g);
	return setsockopt(fd, IPPROTO_IPV6, op, &gr, sizeof(gr));
}

static int do_join(int fd, const char *spec, const char *src)
{
	struct in6_addr g, s; unsigned ifidx; int rc;
	if (parse_group(spec, &g, &ifidx)) return -1;
	char gs[64]; inet_ntop(AF_INET6, &g, gs, sizeof(gs));
	if (!src) {
		struct group_req gr; memset(&gr, 0, sizeof(gr));
		gr.gr_interface = ifidx; fill_ss(&gr.gr_group, &g);
		rc = setsockopt(fd, IPPROTO_IPV6, MCAST_JOIN_GROUP, &gr, sizeof(gr));
	} else {
		if (inet_pton(AF_INET6, src, &s) != 1) { fprintf(stderr, "bad src %s\n", src); return -1; }
		struct group_source_req gsr; memset(&gsr, 0, sizeof(gsr));
		gsr.gsr_interface = ifidx; fill_ss(&gsr.gsr_group, &g); fill_ss(&gsr.gsr_source, &s);
		rc = setsockopt(fd, IPPROTO_IPV6, MCAST_JOIN_SOURCE_GROUP, &gsr, sizeof(gsr));
	}
	printf("join %s if=%u src=%s rc=%d errno=%d\n", gs, ifidx, src ? src : "-", rc, rc ? errno : 0);
	fflush(stdout);
	return rc;
}

static int do_block(int fd, const char *arg)
{
	char *spec = strdup(arg); char *eq = strchr(spec, '=');
	struct in6_addr g, s; unsigned ifidx;
	if (!eq) { fprintf(stderr, "--block GROUP@IF=SRC\n"); free(spec); return -1; }
	*eq = 0;
	if (parse_group(spec, &g, &ifidx) || inet_pton(AF_INET6, eq + 1, &s) != 1) {
		fprintf(stderr, "bad --block %s\n", arg); free(spec); return -1;
	}
	struct group_source_req gsr; memset(&gsr, 0, sizeof(gsr));
	gsr.gsr_interface = ifidx; fill_ss(&gsr.gsr_group, &g); fill_ss(&gsr.gsr_source, &s);
	int rc = setsockopt(fd, IPPROTO_IPV6, MCAST_BLOCK_SOURCE, &gsr, sizeof(gsr));
	char gs[64]; inet_ntop(AF_INET6, &g, gs, sizeof(gs));
	printf("block %s if=%u src=%s rc=%d errno=%d\n", gs, ifidx, eq + 1, rc, rc ? errno : 0);
	fflush(stdout);
	free(spec);
	return rc;
}

static int do_drop(int fd, const char *spec)
{
	struct in6_addr g; unsigned ifidx;
	if (parse_group(spec, &g, &ifidx)) return -1;
	struct group_req gr; memset(&gr, 0, sizeof(gr));
	gr.gr_interface = ifidx; fill_ss(&gr.gr_group, &g);
	int rc = setsockopt(fd, IPPROTO_IPV6, MCAST_LEAVE_GROUP, &gr, sizeof(gr));
	char gs[64]; inet_ntop(AF_INET6, &g, gs, sizeof(gs));
	printf("drop %s if=%u rc=%d errno=%d\n", gs, ifidx, rc, rc ? errno : 0);
	fflush(stdout);
	return rc;
}

/* ---- 사례 23~37 용 ---- */

/* --fill / --unfill: BASE 의 하위 16비트부터 N 개 그룹에 op. 반환: 실패 수 (인자 오류는 -1) */
static int do_range(int fd, int op, int n, const char *spec, const char *label)
{
	struct in6_addr base; unsigned ifidx;
	if (parse_group(spec, &base, &ifidx)) return -1;
	int start = (base.s6_addr[14] << 8) | base.s6_addr[15];
	int ok = 0, fail = 0, fk = -1, ferr = 0;
	for (int k = 0; k < n; k++) {
		struct in6_addr g = nth_group(&base, start + k);
		if (group_req_op(fd, op, &g, ifidx) == 0) ok++;
		else if (!fail++) { fk = k; ferr = errno; }
	}
	char gs[64]; inet_ntop(AF_INET6, &base, gs, sizeof(gs));
	printf("%s %s n=%d if=%u ok=%d failed=%d", label, gs, n, ifidx, ok, fail);
	if (fail) printf(" first_fail_k=%d errno=%d", fk, ferr);
	printf("\n"); fflush(stdout);
	return fail;
}

/* GROUP@IF=SRC 로 group_source_req 옵션 (--leave-src 등) */
static int do_gsr(int fd, int op, const char *label, const char *arg)
{
	char *spec = strdup(arg); char *eq = strchr(spec, '=');
	struct in6_addr g, s; unsigned ifidx;
	if (!eq) { fprintf(stderr, "--%s GROUP@IF=SRC\n", label); free(spec); return -1; }
	*eq = 0;
	if (parse_group(spec, &g, &ifidx) || inet_pton(AF_INET6, eq + 1, &s) != 1) {
		fprintf(stderr, "bad --%s %s\n", label, arg); free(spec); return -1;
	}
	struct group_source_req gsr; memset(&gsr, 0, sizeof(gsr));
	gsr.gsr_interface = ifidx; fill_ss(&gsr.gsr_group, &g); fill_ss(&gsr.gsr_source, &s);
	int rc = setsockopt(fd, IPPROTO_IPV6, op, &gsr, sizeof(gsr));
	char gs[64]; inet_ntop(AF_INET6, &g, gs, sizeof(gs));
	printf("%s %s if=%u src=%s rc=%d errno=%d\n", label, gs, ifidx, eq + 1, rc, rc ? errno : 0);
	fflush(stdout);
	free(spec);
	return rc;
}

#define MSF_MAX 16
/* --msfilter GROUP@IF=include|exclude:SRC[,SRC...] */
static int do_msfilter(int fd, const char *arg)
{
	char *spec = strdup(arg); char *eq = strchr(spec, '=');
	struct in6_addr g; unsigned ifidx; int mode, n = 0, rc = -1;
	if (!eq) goto bad;
	*eq = 0;
	char *srcs = strchr(eq + 1, ':');
	if (!srcs) goto bad;
	*srcs++ = 0;
	if (!strcmp(eq + 1, "include")) mode = MCAST_INCLUDE;
	else if (!strcmp(eq + 1, "exclude")) mode = MCAST_EXCLUDE;
	else goto bad;
	if (parse_group(spec, &g, &ifidx)) goto bad;
	struct group_filter *gf = calloc(1, GROUP_FILTER_SIZE(MSF_MAX));
	if (!gf) die("calloc");
	gf->gf_interface = ifidx; fill_ss(&gf->gf_group, &g); gf->gf_fmode = mode;
	for (char *t = strtok(srcs, ","); t; t = strtok(NULL, ",")) {
		struct in6_addr s;
		if (n >= MSF_MAX || inet_pton(AF_INET6, t, &s) != 1) { free(gf); goto bad; }
		fill_ss(&gf->gf_slist[n++], &s);
	}
	gf->gf_numsrc = n;
	rc = setsockopt(fd, IPPROTO_IPV6, MCAST_MSFILTER, gf, GROUP_FILTER_SIZE(n));
	char gs[64]; inet_ntop(AF_INET6, &g, gs, sizeof(gs));
	printf("msfilter %s if=%u mode=%s nsrc=%d rc=%d errno=%d\n", gs, ifidx,
	       mode == MCAST_INCLUDE ? "include" : "exclude", n, rc, rc ? errno : 0);
	fflush(stdout);
	free(gf); free(spec);
	return rc;
bad:
	fprintf(stderr, "bad --msfilter %s (GROUP@IF=include|exclude:SRC[,SRC])\n", arg);
	free(spec);
	return -1;
}

/* --msfget GROUP@IF : 모드와 소스 목록 */
static int do_msfget(int fd, const char *spec)
{
	struct in6_addr g; unsigned ifidx;
	if (parse_group(spec, &g, &ifidx)) return -1;
	struct group_filter *gf = calloc(1, GROUP_FILTER_SIZE(MSF_MAX));
	if (!gf) die("calloc");
	gf->gf_interface = ifidx; fill_ss(&gf->gf_group, &g); gf->gf_numsrc = MSF_MAX;
	socklen_t len = GROUP_FILTER_SIZE(MSF_MAX);
	int rc = getsockopt(fd, IPPROTO_IPV6, MCAST_MSFILTER, gf, &len);
	char gs[64]; inet_ntop(AF_INET6, &g, gs, sizeof(gs));
	printf("msfget %s if=%u rc=%d errno=%d", gs, ifidx, rc, rc ? errno : 0);
	if (rc == 0) {
		printf(" mode=%s nsrc=%u src=", gf->gf_fmode == MCAST_INCLUDE ? "include" :
		       gf->gf_fmode == MCAST_EXCLUDE ? "exclude" : "?", gf->gf_numsrc);
		unsigned shown = gf->gf_numsrc < MSF_MAX ? gf->gf_numsrc : MSF_MAX;
		if (!shown) printf("-");
		for (unsigned i = 0; i < shown; i++) {
			char ss[64];
			inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&gf->gf_slist[i])->sin6_addr, ss, sizeof(ss));
			printf("%s%s", i ? "," : "", ss);
		}
	}
	printf("\n"); fflush(stdout);
	free(gf);
	return rc;
}

/* --make-it-fail 0|1 : /proc/self/make-it-fail (CONFIG_FAULT_INJECTION) */
static int do_make_it_fail(const char *v)
{
	int rc = -1, err = 0;
	int f = open("/proc/self/make-it-fail", O_WRONLY);
	if (f < 0) err = errno;
	else {
		size_t n = strlen(v);
		if (write(f, v, n) == (ssize_t)n) rc = 0;
		else err = errno ? errno : EIO;
		close(f);
	}
	printf("make_it_fail=%s rc=%d errno=%d\n", v, rc, rc ? err : 0);
	fflush(stdout);
	return rc;
}

static void do_hold(int hold, int fd)
{
	if (hold < 0) return;
	if (fd >= 0) rx_omem(fd, "hold");
	printf("# ready pid=%d\n", (int)getpid());
	fflush(stdout);
	/* 동기화 신호가 hold 중에 와도 hold 는 끝까지 */
	if (hold > 0) {
		struct timespec r = { .tv_sec = hold };
		while (nanosleep(&r, &r) && errno == EINTR) ;
	}
}

static long ms_left(const struct timespec *t0, int timeout)
{
	struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
	return timeout * 1000L - ((now.tv_sec - t0->tv_sec) * 1000L + (now.tv_nsec - t0->tv_nsec) / 1000000);
}

static long ms_since(const struct timespec *t0) { return -ms_left(t0, 0); }

/* ---- --sync-grace: 송신 완료 신호(1단계 SIGUSR1, 2단계 SIGUSR2) ---- */
#define SYNC_CAP_S 60
static int g_sync_grace = -1;			/* ms. < 0 이면 동기화 안 함 (기존 동작) */
static volatile sig_atomic_t g_sync_got[3];	/* [단계] */
static struct timespec g_sync_ts[3];		/* 단계별 첫 신호 시각 (MONOTONIC) */

static void sync_handler(int sig)
{
	int k = sig == SIGUSR1 ? 1 : 2;
	if (__atomic_load_n(&g_sync_got[k], __ATOMIC_ACQUIRE)) return;
	clock_gettime(CLOCK_MONOTONIC, &g_sync_ts[k]);
	__atomic_store_n(&g_sync_got[k], 1, __ATOMIC_RELEASE);
}

static void sync_install(void)
{
	struct sigaction sa; memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sync_handler;	/* SA_RESTART 없음: poll/sleep 이 EINTR 로 돌아온다 */
	sigemptyset(&sa.sa_mask);
	sigaction(SIGUSR1, &sa, NULL);
	sigaction(SIGUSR2, &sa, NULL);
}

/* 이 단계 수신의 남은 시간(ms)과, 지금 끝난다면 그 이유 */
static long rx_left(const struct timespec *t0, int timeout, int phase, const char **why)
{
	long left = ms_left(t0, timeout);
	if (g_sync_grace < 0) { *why = "timeout"; return left; }
	if (!__atomic_load_n(&g_sync_got[phase], __ATOMIC_ACQUIRE)) { *why = "cap"; return ms_left(t0, timeout + SYNC_CAP_S); }
	long g = g_sync_grace - ms_since(&g_sync_ts[phase]);
	if (g > left) { *why = "sync"; return g; }
	*why = "timeout"; return left;
}

static void print_rt(const char *pfx)
{
	struct timespec r; clock_gettime(CLOCK_REALTIME, &r);
	printf("%s t=%ld.%06ld\n", pfx, (long)r.tv_sec, r.tv_nsec / 1000);
	fflush(stdout);
}
static void rx_mark_start(int phase)
{
	char b[64]; snprintf(b, sizeof(b), "# rx_start phase=%d", phase); print_rt(b);
}
static void rx_mark_end(int phase, const char *why, int got)
{
	char b[128]; snprintf(b, sizeof(b), "# rx_end phase=%d reason=%s got=%d", phase, why, got); print_rt(b);
}

/* recvmsg + IPV6_PKTINFO 로 목적지 그룹을 얻는다. 반환: 길이(<0 이면 errno) */
static ssize_t recv_one(int fd, char *buf, size_t bl, struct in6_addr *grp, struct sockaddr_in6 *from)
{
	char ctl[256]; struct iovec iov = { buf, bl - 1 };
	struct msghdr mh = { .msg_name = from, .msg_namelen = sizeof(*from), .msg_iov = &iov, .msg_iovlen = 1,
			     .msg_control = ctl, .msg_controllen = sizeof(ctl) };
	memset(grp, 0, sizeof(*grp));
	ssize_t n = recvmsg(fd, &mh, MSG_DONTWAIT);
	if (n < 0) return n;
	buf[n] = 0;
	for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c))
		if (c->cmsg_level == IPPROTO_IPV6 && c->cmsg_type == IPV6_PKTINFO)
			*grp = ((struct in6_pktinfo *)CMSG_DATA(c))->ipi6_addr;
	return n;
}

/* ---- --sorted 용 기록 ---- */
struct rec { struct in6_addr g; int seq; char *line; };
static struct rec *recs; static size_t nrecs, caprecs;

static void rec_add(const struct in6_addr *g, const char *payload, const char *line)
{
	if (nrecs == caprecs) {
		caprecs = caprecs ? caprecs * 2 : 256;
		recs = realloc(recs, caprecs * sizeof(*recs));
		if (!recs) die("realloc");
	}
	int seq = -1; sscanf(payload, "seq=%d", &seq);
	recs[nrecs].g = *g; recs[nrecs].seq = seq; recs[nrecs].line = strdup(line);
	nrecs++;
}

static int rec_cmp(const void *a, const void *b)
{
	const struct rec *x = a, *y = b;
	int c = memcmp(&x->g, &y->g, sizeof(x->g));
	if (c) return c;
	if (x->seq != y->seq) return x->seq < y->seq ? -1 : 1;
	return strcmp(x->line, y->line);
}

/* ---- --churn ---- */
struct churn { int fd, n; struct in6_addr g; unsigned ifidx;
	       int jfail, dfail, jerr, derr;
	       int mode, k; long elapsed_ms; };	/* mode: 0 --churn, 1 --churn-rejoin, 2 --churn-fill */

/* --churn-rejoin: 가입된 그룹을 탈퇴 → 재가입 (끝나면 가입 상태) */
static void *churn_rejoin_thread(void *arg)
{
	struct churn *c = arg;
	struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int i = 0; i < c->n; i++) {
		if (group_req_op(c->fd, MCAST_LEAVE_GROUP, &c->g, c->ifidx)) { if (!c->dfail++) c->derr = errno; }
		usleep(2000);
		if (group_req_op(c->fd, MCAST_JOIN_GROUP, &c->g, c->ifidx)) { if (!c->jfail++) c->jerr = errno; }
		usleep(2000);
	}
	c->elapsed_ms = ms_since(&t0);
	return NULL;
}

/* --churn-fill: BASE 부터 K 개 가입 → K 개 탈퇴 를 N 회 (S 해시 테이블 생성·해제 반복) */
static void *churn_fill_thread(void *arg)
{
	struct churn *c = arg;
	int start = (c->g.s6_addr[14] << 8) | c->g.s6_addr[15];
	struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int i = 0; i < c->n; i++) {
		for (int k = 0; k < c->k; k++) {
			struct in6_addr g = nth_group(&c->g, start + k);
			if (group_req_op(c->fd, MCAST_JOIN_GROUP, &g, c->ifidx)) { if (!c->jfail++) c->jerr = errno; }
		}
		usleep(1000);
		for (int k = 0; k < c->k; k++) {
			struct in6_addr g = nth_group(&c->g, start + k);
			if (group_req_op(c->fd, MCAST_LEAVE_GROUP, &g, c->ifidx)) { if (!c->dfail++) c->derr = errno; }
		}
		usleep(1000);
	}
	c->elapsed_ms = ms_since(&t0);
	return NULL;
}

static void *churn_thread(void *arg)
{
	struct churn *c = arg;
	for (int i = 0; i < c->n; i++) {
		if (group_req_op(c->fd, MCAST_JOIN_GROUP, &c->g, c->ifidx)) { if (!c->jfail++) c->jerr = errno; }
		usleep(500);
		if (group_req_op(c->fd, MCAST_LEAVE_GROUP, &c->g, c->ifidx)) { if (!c->dfail++) c->derr = errno; }
		usleep(500);
	}
	return NULL;
}

/* ---- --wa N BASE@IF ---- */
static int wa_main(int n, const char *base_spec, int port, int count, int timeout, int hold)
{
	struct in6_addr base; unsigned ifidx;
	if (parse_group(base_spec, &base, &ifidx)) return 2;
	struct rlimit rl;
	if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < (rlim_t)n + 64) {
		rl.rlim_cur = rl.rlim_max; setrlimit(RLIMIT_NOFILE, &rl);
	}
	int *fds = calloc(n, sizeof(int)), *cnt = calloc(n, sizeof(int)), *wrong = calloc(n, sizeof(int));
	if (!fds || !cnt || !wrong) die("calloc");
	int ep = epoll_create1(0);
	if (ep < 0) die("epoll_create1");
	int one = 1, ok = 0, fail = 0;
	for (int i = 0; i < n; i++) {
		int fd = socket(AF_INET6, SOCK_DGRAM, 0);
		if (fd < 0) { printf("wa: socket fail i=%d errno=%d\n", i, errno); n = i; break; }
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, sizeof(one));
		struct sockaddr_in6 sa; memset(&sa, 0, sizeof(sa));
		sa.sin6_family = AF_INET6; sa.sin6_port = htons(port + i); sa.sin6_addr = in6addr_any;
		if (bind(fd, (struct sockaddr *)&sa, sizeof(sa))) { printf("wa: bind fail i=%d errno=%d\n", i, errno); }
		struct in6_addr g = nth_group(&base, i);
		if (group_req_op(fd, MCAST_JOIN_GROUP, &g, ifidx) == 0) ok++;
		else if (!fail++) printf("wa: first join fail at i=%d errno=%d\n", i, errno);
		struct epoll_event ev = { .events = EPOLLIN, .data.u32 = i };
		if (epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev)) die("epoll_ctl");
		fds[i] = fd;
	}
	printf("wa: sockets=%d joined=%d failed=%d\n", n, ok, fail); fflush(stdout);
	do_hold(hold, -1);

	rx_mark_start(1);
	struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
	int total = 0;
	const char *why = "count";
	struct epoll_event evs[64];
	while (count < 0 || total < count) {
		const char *w;
		long left = rx_left(&t0, timeout, 1, &w);
		if (left <= 0) { why = w; break; }
		int r = epoll_wait(ep, evs, 64, (int)(g_sync_grace >= 0 && left > 100 ? 100 : left));
		if (r < 0 && errno == EINTR) continue;
		if (r < 0) { why = "error"; break; }
		if (r == 0) { if (g_sync_grace >= 0) continue; why = "timeout"; break; }
		for (int e = 0; e < r; e++) {
			int i = evs[e].data.u32;
			struct in6_addr exp = nth_group(&base, i);
			for (;;) {
				char buf[256]; struct sockaddr_in6 from; struct in6_addr grp;
				ssize_t m = recv_one(fds[i], buf, sizeof(buf), &grp, &from);
				if (m < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) break; if (errno == EINTR) continue; die("recvmsg"); }
				if (memcmp(&grp, &exp, sizeof(grp))) wrong[i]++; else cnt[i]++;
				total++;
			}
		}
	}
	rx_mark_end(1, why, total);
	int zero = 0, single = 0, multi = 0, nwrong = 0;
	for (int i = 0; i < n; i++) {
		char gs[64]; struct in6_addr g = nth_group(&base, i);
		inet_ntop(AF_INET6, &g, gs, sizeof(gs));
		printf("wa i=%d group=%s port=%d n=%d wrong=%d\n", i, gs, port + i, cnt[i], wrong[i]);
		if (cnt[i] == 0) zero++; else if (cnt[i] == 1) single++; else multi++;
		nwrong += wrong[i];
	}
	printf("wa: total=%d one=%d zero=%d multi=%d wrong=%d\n", total, single, zero, multi, nwrong);
	fflush(stdout);
	return 0;
}

/* 수신 루프. ch 가 있으면 ch->g 의 recv 줄은 "#" 접두사이고 *churn_got 에 센다.
 * min_seq >= 0 이면 seq < min_seq 인 패킷(앞 단계에서 늦게 도착한 것)은 "# stale recv ..." 로만 출력하고 세지 않는다.
 * 반환: 그 밖의 수신 수 */
static int recv_loop(int fd, int count, int timeout, int sorted, const struct churn *ch, int *churn_got, int min_seq, int phase)
{
	rx_mark_start(phase);
	struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
	int got = 0;
	const char *why = "count";
	while (count < 0 || got < count) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		const char *w;
		long left_ms = rx_left(&t0, timeout, phase, &w);
		if (left_ms <= 0) { why = w; break; }
		/* 동기화 중에는 100ms 마다 신호 여부를 다시 본다 (신호가 다른 스레드로 가도 놓치지 않게) */
		int r = poll(&p, 1, (int)(g_sync_grace >= 0 && left_ms > 100 ? 100 : left_ms));
		if (r < 0 && errno == EINTR) continue;
		if (r < 0) { why = "error"; break; }
		if (r == 0) { if (g_sync_grace >= 0) continue; why = "timeout"; break; }
		char buf[256]; struct sockaddr_in6 from; struct in6_addr grp;
		ssize_t n = recv_one(fd, buf, sizeof(buf), &grp, &from);
		if (n < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue; die("recvmsg"); }
		char ss[64], gs[64] = "?", line[512];
		inet_ntop(AF_INET6, &from.sin6_addr, ss, sizeof(ss));
		static const struct in6_addr zero6;
		if (memcmp(&grp, &zero6, sizeof(grp))) inet_ntop(AF_INET6, &grp, gs, sizeof(gs));
		int is_churn = ch && !memcmp(&grp, &ch->g, sizeof(grp));
		if (min_seq >= 0) {
			int seq = -1; sscanf(buf, "seq=%d", &seq);
			if (seq < min_seq) { printf("# stale recv %s group=%s src=%s\n", buf, gs, ss); continue; }
		}
		snprintf(line, sizeof(line), "%srecv %s group=%s src=%s", is_churn ? "# " : "", buf, gs, ss);
		if (sorted) rec_add(&grp, buf, line);
		else printf("%s\n", line);
		if (is_churn) (*churn_got)++; else got++;
	}
	rx_mark_end(phase, why, got);
	return got;
}

static void flush_sorted(void)
{
	qsort(recs, nrecs, sizeof(*recs), rec_cmp);
	for (size_t i = 0; i < nrecs; i++) { printf("%s\n", recs[i].line); free(recs[i].line); }
	nrecs = 0;
}

/* --phase2 뒤 인자: 인자 순서대로 수행 */
static void do_actions(int fd, int argc, char **argv)
{
	for (int i = 0; i < argc; i++) {
		const char *o = argv[i];
		if (!strcmp(o, "--join") && i + 1 < argc) do_join(fd, argv[++i], NULL);
		else if (!strcmp(o, "--join-src") && i + 1 < argc) {
			char *spec = strdup(argv[++i]); char *eq = strchr(spec, '=');
			if (!eq) fprintf(stderr, "--join-src GROUP@IF=SRC\n");
			else { *eq = 0; do_join(fd, spec, eq + 1); }
			free(spec);
		}
		else if (!strcmp(o, "--drop") && i + 1 < argc) do_drop(fd, argv[++i]);
		else if (!strcmp(o, "--leave-src") && i + 1 < argc) do_gsr(fd, MCAST_LEAVE_SOURCE_GROUP, "leave-src", argv[++i]);
		else if (!strcmp(o, "--block") && i + 1 < argc) do_block(fd, argv[++i]);
		else if (!strcmp(o, "--fill") && i + 2 < argc) { do_range(fd, MCAST_JOIN_GROUP, atoi(argv[i + 1]), argv[i + 2], "fill"); i += 2; }
		else if (!strcmp(o, "--unfill") && i + 2 < argc) { do_range(fd, MCAST_LEAVE_GROUP, atoi(argv[i + 1]), argv[i + 2], "unfill"); i += 2; }
		else if (!strcmp(o, "--mark") && i + 1 < argc) rx_omem(fd, argv[++i]);
		else if (!strcmp(o, "--msfilter") && i + 1 < argc) do_msfilter(fd, argv[++i]);
		else if (!strcmp(o, "--msfget") && i + 1 < argc) do_msfget(fd, argv[++i]);
		else if (!strcmp(o, "--make-it-fail") && i + 1 < argc) do_make_it_fail(argv[++i]);
		else if ((!strcmp(o, "--count") || !strcmp(o, "--timeout") || !strcmp(o, "--min-seq") || !strcmp(o, "--sync-grace")) && i + 1 < argc) i++;
		else if (!strcmp(o, "--sorted")) ;
		else fprintf(stderr, "phase2: 모르는 인자 %s\n", o);
	}
}

static int rx_main(int argc, char **argv)
{
	int port = 7000, mcall = -1, count = -1, timeout = 3, do_close = 0;
	const char *many_base = NULL; int many_n = 0;
	int drop_many = 0, hold = -1, addrform = 0, sorted = 0, rejoin = 0;
	int churn_n = 0; const char *churn_spec = NULL;
	int churn_mode = 0, churn_k = 0;
	int wa_n = 0; const char *wa_base = NULL;

	/* --phase2 뒤의 인자는 2단계용. 1단계 처리(아래 기존 코드)는 그 앞까지만 본다 */
	int argc2 = -1; char **argv2 = NULL;
	for (int i = 0; i < argc; i++)
		if (!strcmp(argv[i], "--phase2")) { argv2 = argv + i + 1; argc2 = argc - i - 1; argc = i; break; }
	/* 2단계 인자 중 --post 뒤는 2단계 수신 뒤에 수행 */
	int argc3 = -1; char **argv3 = NULL;
	for (int i = 0; i < argc2; i++)
		if (!strcmp(argv2[i], "--post")) { argv3 = argv2 + i + 1; argc3 = argc2 - i - 1; argc2 = i; break; }

	/* 1차: 옵션 중 bind 전에 필요한 것 */
	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--mcall") && i + 1 < argc) mcall = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--close")) do_close = 1;
		else if (!strcmp(argv[i], "--many") && i + 2 < argc) { many_n = atoi(argv[++i]); many_base = argv[++i]; }
		else if (!strcmp(argv[i], "--drop-many") && i + 1 < argc) drop_many = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--hold") && i + 1 < argc) hold = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--addrform")) addrform = 1;
		else if (!strcmp(argv[i], "--sorted")) sorted = 1;
		else if (!strcmp(argv[i], "--rejoin")) rejoin = 1;
		else if (!strcmp(argv[i], "--omem")) g_omem = 1;
		else if (!strcmp(argv[i], "--churn") && i + 2 < argc) { churn_n = atoi(argv[++i]); churn_spec = argv[++i]; }
		else if (!strcmp(argv[i], "--churn-rejoin") && i + 2 < argc) {
			churn_mode = 1; churn_n = atoi(argv[++i]); churn_spec = argv[++i];
		}
		else if (!strcmp(argv[i], "--churn-fill") && i + 3 < argc) {
			churn_mode = 2; churn_n = atoi(argv[++i]); churn_k = atoi(argv[++i]); churn_spec = argv[++i];
		}
		else if (!strcmp(argv[i], "--fill") || !strcmp(argv[i], "--unfill")) i += 2;	/* 2차에서 처리 */
		else if (!strcmp(argv[i], "--mark") || !strcmp(argv[i], "--make-it-fail")) i += 1;	/* 2차에서 처리 */
		else if (!strcmp(argv[i], "--wa") && i + 2 < argc) { wa_n = atoi(argv[++i]); wa_base = argv[++i]; }
		else if (!strcmp(argv[i], "--sync-grace") && i + 1 < argc) g_sync_grace = atoi(argv[++i]);
	}
	if (g_sync_grace >= 0) sync_install();
	if (wa_n > 0) return wa_main(wa_n, wa_base, port, count, timeout, hold);

	int fd = socket(AF_INET6, SOCK_DGRAM, 0);
	if (fd < 0) die("socket");
	int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, sizeof(one)); /* 수신 그룹 주소 확인용 */

	if (mcall >= 0) {
		int rc = setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_ALL, &mcall, sizeof(mcall));
		printf("mcall=%d rc=%d errno=%d\n", mcall, rc, rc ? errno : 0);
	}
	struct sockaddr_in6 sa; memset(&sa, 0, sizeof(sa));
	sa.sin6_family = AF_INET6; sa.sin6_port = htons(port); sa.sin6_addr = in6addr_any;
	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa))) die("bind");

	/* 2차: 가입 (순서 보존) */
	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--join") && i + 1 < argc) do_join(fd, argv[++i], NULL);
		else if (!strcmp(argv[i], "--join-src") && i + 1 < argc) {
			char *spec = strdup(argv[++i]); char *eq = strchr(spec, '=');
			if (!eq) { fprintf(stderr, "--join-src GROUP@IF=SRC\n"); return 2; }
			*eq = 0; do_join(fd, spec, eq + 1); free(spec);
		}
		else if (!strcmp(argv[i], "--fill") && i + 2 < argc) { do_range(fd, MCAST_JOIN_GROUP, atoi(argv[i + 1]), argv[i + 2], "fill"); i += 2; }
		else if (!strcmp(argv[i], "--unfill") && i + 2 < argc) { do_range(fd, MCAST_LEAVE_GROUP, atoi(argv[i + 1]), argv[i + 2], "unfill"); i += 2; }
		else if (!strcmp(argv[i], "--mark") && i + 1 < argc) rx_omem(fd, argv[++i]);
		else if (!strcmp(argv[i], "--make-it-fail") && i + 1 < argc) do_make_it_fail(argv[++i]);
	}
	struct in6_addr many_g; unsigned many_if = 0;
	if (many_n > 0) {
		int ok = 0, fail = 0, first_fail = -1;
		if (parse_group(many_base, &many_g, &many_if)) return 2;
		for (int k = 0; k < many_n; k++) {
			struct in6_addr g = nth_group(&many_g, k);
			if (group_req_op(fd, MCAST_JOIN_GROUP, &g, many_if) == 0) ok++;
			else { fail++; if (first_fail < 0) { first_fail = k; printf("many: first fail at k=%d errno=%d\n", k, errno); } }
		}
		printf("many: joined=%d failed=%d\n", ok, fail); fflush(stdout);
	}
	rx_omem(fd, "joined");
	/* 가입 후 출발지 차단 */
	for (int i = 0; i < argc; i++)
		if (!strcmp(argv[i], "--block") && i + 1 < argc) do_block(fd, argv[++i]);
	/* MCAST_MSFILTER 설정·조회 (사례 33) */
	int had_msf = 0;
	for (int i = 0; i < argc; i++)
		if (!strcmp(argv[i], "--msfilter") && i + 1 < argc) { do_msfilter(fd, argv[++i]); had_msf = 1; }
	if (had_msf) rx_omem(fd, "msfilter");
	for (int i = 0; i < argc; i++)
		if (!strcmp(argv[i], "--msfget") && i + 1 < argc) do_msfget(fd, argv[++i]);
	/* 3차: 탈퇴 */
	int had_drop = 0;
	for (int i = 0; i < argc; i++)
		if (!strcmp(argv[i], "--drop") && i + 1 < argc) { do_drop(fd, argv[++i]); had_drop = 1; }
	if (drop_many > 0) {
		if (many_n <= 0) { fprintf(stderr, "--drop-many 는 --many 와 함께\n"); return 2; }
		int ok = 0, fail = 0;
		for (int k = 0; k < drop_many; k++) {
			struct in6_addr g = nth_group(&many_g, k);
			if (group_req_op(fd, MCAST_LEAVE_GROUP, &g, many_if) == 0) ok++;
			else if (!fail++) printf("drop-many: first fail at k=%d errno=%d\n", k, errno);
		}
		printf("drop-many: dropped=%d failed=%d\n", ok, fail); fflush(stdout);
	}
	if (had_drop || drop_many > 0) rx_omem(fd, "dropped");
	if (rejoin) {
		if (many_n <= 0) { fprintf(stderr, "--rejoin 은 --many 와 함께\n"); return 2; }
		int ok = 0, fail = 0;
		for (int k = 0; k < many_n; k++) {
			struct in6_addr g = nth_group(&many_g, k);
			if (group_req_op(fd, MCAST_JOIN_GROUP, &g, many_if) == 0) ok++;
			else if (!fail++) printf("rejoin: first fail at k=%d errno=%d\n", k, errno);
		}
		printf("rejoin: joined=%d failed=%d\n", ok, fail); fflush(stdout);
		rx_omem(fd, "rejoined");
	}
	if (addrform) {
		rx_omem(fd, "addrform_before");
		struct sockaddr_in6 d; memset(&d, 0, sizeof(d));
		d.sin6_family = AF_INET6; d.sin6_port = htons(9);
		inet_pton(AF_INET6, "::ffff:127.0.0.1", &d.sin6_addr);
		int rc = connect(fd, (struct sockaddr *)&d, sizeof(d));
		printf("addrform connect ::ffff:127.0.0.1:9 rc=%d errno=%d\n", rc, rc ? errno : 0);
		int af = AF_INET;
		rc = setsockopt(fd, IPPROTO_IPV6, IPV6_ADDRFORM, &af, sizeof(af));
		printf("addrform AF_INET rc=%d errno=%d\n", rc, rc ? errno : 0);
		fflush(stdout);
		rx_omem(fd, "addrform_after");
	}

	if (do_close) { close(fd); printf("closed\n"); return 0; }

	do_hold(hold, fd);

	pthread_t th; struct churn ch; int churn_on = 0;
	if (churn_n > 0) {
		memset(&ch, 0, sizeof(ch));
		ch.fd = fd; ch.n = churn_n; ch.mode = churn_mode; ch.k = churn_k;
		if (parse_group(churn_spec, &ch.g, &ch.ifidx)) return 2;
		void *(*fn)(void *) = churn_mode == 1 ? churn_rejoin_thread :
				      churn_mode == 2 ? churn_fill_thread : churn_thread;
		if (pthread_create(&th, NULL, fn, &ch)) die("pthread_create");
		churn_on = 1;
	}

	/* 수신 */
	int churn_got = 0;
	int got = recv_loop(fd, count, timeout, sorted, churn_on ? &ch : NULL, &churn_got, -1, 1);
	if (churn_on) {
		pthread_join(th, NULL);
		char gs[64]; inet_ntop(AF_INET6, &ch.g, gs, sizeof(gs));
		if (ch.mode == 0)
			printf("churn %s if=%u n=%d join_fail=%d(errno=%d) drop_fail=%d(errno=%d)\n",
			       gs, ch.ifidx, ch.n, ch.jfail, ch.jerr, ch.dfail, ch.derr);
		else if (ch.mode == 1)
			printf("churn_rejoin %s if=%u n=%d drop_fail=%d(errno=%d) join_fail=%d(errno=%d)\n",
			       gs, ch.ifidx, ch.n, ch.dfail, ch.derr, ch.jfail, ch.jerr);
		else
			printf("churn_fill %s k=%d if=%u n=%d join_fail=%d(errno=%d) drop_fail=%d(errno=%d)\n",
			       gs, ch.k, ch.ifidx, ch.n, ch.jfail, ch.jerr, ch.dfail, ch.derr);
		printf("# churn_recv=%d\n", churn_got);
		if (ch.mode != 0) {
			printf("# churn_elapsed_ms=%ld\n", ch.elapsed_ms);
			rx_omem(fd, "churned");
		}
	}
	if (sorted) flush_sorted();
	printf("total=%d\n", got); fflush(stdout);

	if (argv2) {
		int count2 = -1, timeout2 = 3, sorted2 = 0, min_seq2 = -1;
		for (int i = 0; i < argc2; i++) {
			if (!strcmp(argv2[i], "--count") && i + 1 < argc2) count2 = atoi(argv2[++i]);
			else if (!strcmp(argv2[i], "--timeout") && i + 1 < argc2) timeout2 = atoi(argv2[++i]);
			else if (!strcmp(argv2[i], "--sorted")) sorted2 = 1;
			else if (!strcmp(argv2[i], "--min-seq") && i + 1 < argc2) min_seq2 = atoi(argv2[++i]);
		}
		printf("phase2\n"); fflush(stdout);
		do_actions(fd, argc2, argv2);
		printf("# ready2 pid=%d\n", (int)getpid());
		fflush(stdout);
		got = recv_loop(fd, count2, timeout2, sorted2, NULL, &churn_got, min_seq2, 2);
		if (sorted2) flush_sorted();
		printf("total=%d\n", got); fflush(stdout);
		if (argv3) {
			printf("post\n"); fflush(stdout);
			do_actions(fd, argc3, argv3);
		}
	}
	return 0;
}

/* /proc/net/igmp6 (현재 netns) 에서 dev 가 group 에 가입돼 있는지 */
static void print_maddr(const struct in6_addr *g, const char *stage)
{
	static const char *devs[] = { "veth1", "dummy0" };
	char hex[33], gs[64], line[256], d[64], a[64];
	for (int i = 0; i < 16; i++) sprintf(hex + 2 * i, "%02x", g->s6_addr[i]);
	inet_ntop(AF_INET6, g, gs, sizeof(gs));
	for (unsigned k = 0; k < sizeof(devs) / sizeof(devs[0]); k++) {
		FILE *f = fopen("/proc/net/igmp6", "r");
		int found = 0;
		if (!f) { printf("maddr %s %s=NA stage=%s errno=%d\n", devs[k], gs, stage, errno); continue; }
		while (fgets(line, sizeof(line), f))
			if (sscanf(line, "%*d %63s %63s", d, a) == 2 && !strcmp(d, devs[k]) && !strcmp(a, hex))
				found = 1;
		fclose(f);
		printf("maddr %s %s=%s stage=%s\n", devs[k], gs, found ? "yes" : "no", stage);
	}
	fflush(stdout);
}

/* ---- tcp: 가입한 리스닝 소켓에서 accept (사례 22) ---- */
#define TCP_MAX_JOIN 8
static int tcp_main(int argc, char **argv)
{
	int port = 7100, v4 = 0, one = 1, zero = 0, rc;
	struct in6_addr jg[TCP_MAX_JOIN]; int njg = 0;
	alarm(10);	/* 어떤 단계에서 막혀도 종료 → 스크립트가 실패로 표시 */
	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--conn") && i + 1 < argc) v4 = !strcmp(argv[++i], "v4");
	}
	int ls = socket(AF_INET6, SOCK_STREAM, 0);
	if (ls < 0) die("socket");
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	if (setsockopt(ls, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero))) die("V6ONLY");
	struct sockaddr_in6 sa; memset(&sa, 0, sizeof(sa));
	sa.sin6_family = AF_INET6; sa.sin6_port = htons(port); sa.sin6_addr = in6addr_any;
	if (bind(ls, (struct sockaddr *)&sa, sizeof(sa))) die("bind");
	if (listen(ls, 4)) die("listen");
	printf("listen [::]:%d\n", port);
	for (int i = 0; i < argc; i++)
		if (!strcmp(argv[i], "--join") && i + 1 < argc) {
			unsigned ifx;
			if (do_join(ls, argv[++i], NULL)) return 1;
			if (njg < TCP_MAX_JOIN && !parse_group(argv[i], &jg[njg], &ifx)) njg++;
		}
	print_omem(ls, "listen", "parent");
	for (int k = 0; k < njg; k++) print_maddr(&jg[k], "listen");

	int c;
	if (v4) {
		struct sockaddr_in d; memset(&d, 0, sizeof(d));
		d.sin_family = AF_INET; d.sin_port = htons(port);
		inet_pton(AF_INET, "127.0.0.1", &d.sin_addr);
		c = socket(AF_INET, SOCK_STREAM, 0);
		if (c < 0) die("socket client");
		rc = connect(c, (struct sockaddr *)&d, sizeof(d));
		printf("connect 127.0.0.1:%d rc=%d errno=%d\n", port, rc, rc ? errno : 0);
	} else {
		struct sockaddr_in6 d; memset(&d, 0, sizeof(d));
		d.sin6_family = AF_INET6; d.sin6_port = htons(port); d.sin6_addr = in6addr_loopback;
		c = socket(AF_INET6, SOCK_STREAM, 0);
		if (c < 0) die("socket client");
		rc = connect(c, (struct sockaddr *)&d, sizeof(d));
		printf("connect [::1]:%d rc=%d errno=%d\n", port, rc, rc ? errno : 0);
	}
	fflush(stdout);
	if (rc) return 1;

	struct sockaddr_in6 peer; socklen_t pl = sizeof(peer);
	int a = accept(ls, (struct sockaddr *)&peer, &pl);
	if (a < 0) die("accept");
	char ps[64]; inet_ntop(AF_INET6, &peer.sin6_addr, ps, sizeof(ps));
	printf("accept peer=%s\n", ps);	/* 포트는 비결정적이라 출력하지 않음 */
	fflush(stdout);
	print_omem(ls, "accepted", "parent");
	print_omem(a, "accepted", "child");

	rc = close(a);
	printf("child closed rc=%d\n", rc); fflush(stdout);
	print_omem(ls, "child_closed", "parent");
	for (int k = 0; k < njg; k++) print_maddr(&jg[k], "child_closed");

	rc = close(ls);
	printf("parent closed rc=%d\n", rc); fflush(stdout);
	for (int k = 0; k < njg; k++) print_maddr(&jg[k], "parent_closed");

	close(c);
	return 0;
}

static int tx_main(int argc, char **argv)
{
	int port = 7000, count = 1, seq = 0, many_n = 0, port_step = 0;
	const char *dev = NULL, *group = NULL, *src = NULL, *many_base = NULL;
	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--dev") && i + 1 < argc) dev = argv[++i];
		else if (!strcmp(argv[i], "--group") && i + 1 < argc) group = argv[++i];
		else if (!strcmp(argv[i], "--src") && i + 1 < argc) src = argv[++i];
		else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--seq-start") && i + 1 < argc) seq = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--many") && i + 2 < argc) { many_n = atoi(argv[++i]); many_base = argv[++i]; }
		else if (!strcmp(argv[i], "--port-step") && i + 1 < argc) port_step = atoi(argv[++i]);
	}
	if (!dev || (!group && many_n <= 0)) {
		fprintf(stderr, "tx --dev DEV (--group G | --many N BASE [--port-step S]) [--src S] [--count N]\n");
		return 2;
	}
	int fd = socket(AF_INET6, SOCK_DGRAM, 0);
	if (fd < 0) die("socket");
	unsigned ifidx = if_nametoindex(dev);
	if (!ifidx) die("if_nametoindex");
	if (setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &ifidx, sizeof(ifidx))) die("MULTICAST_IF");
	int hops = 1; setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, sizeof(hops));
	if (src) {
		struct sockaddr_in6 sa; memset(&sa, 0, sizeof(sa)); sa.sin6_family = AF_INET6;
		if (inet_pton(AF_INET6, src, &sa.sin6_addr) != 1) die("src");
		if (bind(fd, (struct sockaddr *)&sa, sizeof(sa))) die("bind src");
	}
	struct sockaddr_in6 dst; memset(&dst, 0, sizeof(dst));
	dst.sin6_family = AF_INET6; dst.sin6_port = htons(port);
	dst.sin6_scope_id = ifidx;
	if (many_n > 0) {
		struct in6_addr base;
		if (inet_pton(AF_INET6, many_base, &base) != 1) die("many base");
		for (int k = 0; k < many_n; k++) {
			dst.sin6_addr = nth_group(&base, k);
			dst.sin6_port = htons(port + k * port_step);
			for (int i = 0; i < count; i++) {
				char buf[64]; int n = snprintf(buf, sizeof(buf), "seq=%d", seq + i);
				if (sendto(fd, buf, n, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) die("sendto");
				usleep(1000);
			}
		}
		printf("sent %d each to %d groups base %s port %d step %d via %s\n",
		       count, many_n, many_base, port, port_step, dev);
		return 0;
	}
	if (inet_pton(AF_INET6, group, &dst.sin6_addr) != 1) die("group");
	for (int i = 0; i < count; i++) {
		char buf[64]; int n = snprintf(buf, sizeof(buf), "seq=%d", seq + i);
		if (sendto(fd, buf, n, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) die("sendto");
		usleep(1000);
	}
	printf("sent %d to %s via %s\n", count, group, dev);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "mc6test rx|tx|tcp ...\n"); return 2; }
	/* rx 는 IPV6_RECVPKTINFO 로 목적지 그룹을 알아낸다 */
	if (!strcmp(argv[1], "rx")) {
		/* rx_main 안에서 socket 을 만들므로 옵션만 넘김 */
		int r = rx_main(argc - 2, argv + 2);
		return r;
	}
	if (!strcmp(argv[1], "tx")) return tx_main(argc - 2, argv + 2);
	if (!strcmp(argv[1], "tcp")) return tcp_main(argc - 2, argv + 2);
	fprintf(stderr, "rx|tx|tcp\n"); return 2;
}
