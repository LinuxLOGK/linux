#!/usr/bin/env bash
# IPv6 소켓 멀티캐스트(S) 정확성 fixture.
#
# 사용법:
#   tools/run-fixture.sh <태그> [NN ...]     사례 실행 (NN 생략 시 01~37 전부). 일반 사용자로 실행, 내부에서 sudo.
#   tools/run-fixture.sh --diff <태그A> <태그B> "#" 줄을 빼고 사례별 diff
#   tools/run-fixture.sh --diff --behavior <태그A> <태그B>
#                                            위에 더해 omem= 줄과 12 의 한도 줄(many: first fail / joined=)도 빼고 비교.
#                                            전부 "같음" 이면 수신·판정 결과가 같다는 뜻.
#   tools/run-fixture.sh --omem <태그A> <태그B> 두 태그의 omem= 줄만 사례별로 나란히 (값이 다르면 * 표시)
#
# 사례 목록 (pre = filler 를 시험 가입보다 먼저, post = 나중에. filler = ff15::f:0~3 을 veth1 에 가입, 같은 소켓)
#   01 가입/미가입 그룹 송신 → 가입 그룹만 수신        02 같은 그룹 ifindex=0 두 번 가입 → EADDRINUSE
#   03 같은 그룹 veth1, dummy0 명시 가입 → 둘 다 성공   04 03 상태에서 ifindex=0 탈퇴 → 최신(dummy0) 제거
#   05 veth1 INCLUDE{fd00::1}, dummy0 INCLUDE{fd00::9}  06 05 에서 dummy0 항목 탈퇴 후 송신
#   07 05 의 가입 순서 반대                             08 ASM 가입 후 block fd00::1
#   09 mcall=1 은 미가입 그룹 수신, mcall=0 은 0        10 그룹 3/4/5 개 가입 수신, omem
#   11 그룹 31~1024 개 가입 수신                        12 optmem_max=20480 에서 가입 한계
#   13 1024 가입 → 1023 탈퇴 → 남은 1개만 수신          14 단계별 omem (없음 / 1024 / 1024 후 전부 탈퇴)
#   15 가입 상태 close 후 같은 포트 새 소켓             16 가입 상태 addrform, 전후 omem
#   17 수신 중 다른 그룹 churn 1000                     18 수신·송신 중 netns del
#   19 소켓 1024 개 (W_A)                               20 테이블 할당 실패 주입 (failslab 없으면 N/A)
#   21 4개 가입 → 전부 탈퇴 → 다시 4개, omem            22 그룹 2개 가입 TCP 리스닝 소켓 accept
#   23 pre: 03+04 (두 장치 가입, ifindex=0 중복 가입, ifindex=0 탈퇴), maddr
#   24 pre: 05 (veth1 INCLUDE{fd00::1}, dummy0 INCLUDE{fd00::9})
#   25 pre: 06 (24 에서 dummy0 항목 탈퇴 후 송신)
#   26 pre: 07 (24 의 가입 순서 반대)
#   27 post: 05/07 순서로 2개 가입 뒤 filler 로 4개째에 테이블 생성 → 테이블 생성 시 순서 보존
#   28 pre: 08 (ASM 가입 후 block fd00::1)
#   29 pre: 09 (filler 4 인 mcall=0 / mcall=1 소켓의 미가입 그룹 수신)
#   30 pre: 15 (5개 가입 상태 close → 같은 포트 새 소켓 가입·수신, 새 소켓 omem)
#   31 pre: 16 (5개 가입 상태 addrform, 전후 omem)
#   32 22 를 그룹 5개로 (TCP 리스닝 소켓 accept, 자식/부모 omem, dmesg)
#   33 MCAST_MSFILTER: 가입 1개 / filler 4 에서 올바른 ifindex 설정·조회, ifindex=0 설정 시도
#   34 pre: INCLUDE{fd00::1} → JOIN_SOURCE_GROUP fd00::9 추가 → LEAVE_SOURCE_GROUP fd00::1 제거, 단계별 수신
#   35 임계값 주변: 4 가입 → 1 탈퇴(3 남음) 수신 → 전부 탈퇴 → 5 재가입 수신, 단계별 omem
#   36 소켓 B 가 테이블 생성·해제 500회 하는 동안 같은 포트 소켓 A 수신 (B 는 0), dmesg
#   37 테이블 있는 소켓에서 수신 중 G 탈퇴/재가입 200회, 끝난 뒤 수신, dmesg
#
# 결과: ~/kdev-kit/logs/<태그>/_env.txt, NN.txt (원본 출력은 logs/<태그>/.work/NN/)
# 실패: 사례 안에서 시간 초과·기대 줄 누락이 있으면 "FAIL ..." 줄을 남기고, 끝에 실패 사례를 출력하고 종료 코드 1.
# 환경 오류: tx 출발지 주소가 5초 안에 bind 가능해지지 않거나, tx 가 실패(종료 코드 != 0 또는 "sent " 줄 없음)하면
#       "FIXTURE ERROR ..." 줄을 남긴다 (커널 동작 차이가 아니라 환경 문제). 하나라도 있으면 종료 코드 2.
#       --diff 는 FIXTURE ERROR 가 있는 사례를 비교하지 않고 따로 표시한다.
# 송수신 동기화: rx_bg 로 띄운 수신(--timeout 0 제외)에는 mc6test --sync-grace 를 붙인다. 수신은 --timeout 이 지나도
#       끝나지 않고, 스크립트가 그 단계 송신을 모두 마친 뒤 보내는 신호(rx_wait/rx_ready2: 1단계 SIGUSR1, 2단계 SIGUSR2)
#       를 받은 뒤 max(--timeout 끝, 신호 + SYNC_GRACE_MS(1.5초)) 에 끝난다. 빠른 커널에서는 기존과 같은 시점에 끝나고,
#       느린 커널(디버그)에서는 "송신이 다 끝난 뒤 1.5초" 까지 기다린다 (0개 수신이 정답인 사례도 같음).
# 시각 기록: 사례 끝에 "# timing rx|tx ..." 줄로 수신 단계 시작·종료(이유)와 각 tx 시작·종료를 사례 시작 기준 초로 남긴다.
#       어떤 수신 단계용 tx(그 단계 신호 전에 끝난 tx. 신호 없는 수신은 종료 전에 시작한 tx)가 그 단계 수신
#       종료 뒤에 끝났으면(수신이 --count 도달로 끝난 경우는 제외) "FIXTURE ERROR tx late: ..." 로 표시한다
#       (판정 대신 환경 문제로 분류).
# 실행 중 이 스크립트나 mc6test 를 고쳐도 영향이 없도록, 시작 시 둘 다 임시 디렉터리로 복사해 그 사본으로 실행한다.
# 규칙: 비결정적 값(시각, pid, 수신 수가 정해지지 않는 것)은 "#" 로 시작하는 줄에만 쓴다.
#       ifindex 숫자는 netns 를 올릴 때마다 바뀌므로 if=<n> 을 if=veth1 / if=dummy0 으로 바꿔 기록한다.
set -uo pipefail

KIT="${RF_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ "${1:-}" != "--diff" && "${1:-}" != "--omem" && -z "${RF_SNAP:-}" ]]; then
  SNAP=$(mktemp -d "${TMPDIR:-/tmp}/run-fixture.XXXXXX") || exit 1
  cp "${BASH_SOURCE[0]}" "$SNAP/run-fixture.sh" || exit 1
  [[ -x "$KIT/tools/mc6test" ]] && cp "$KIT/tools/mc6test" "$SNAP/mc6test"
  RF_SNAP="$SNAP" RF_KIT="$KIT" exec bash "$SNAP/run-fixture.sh" "$@"
fi
MC="${RF_SNAP:+$RF_SNAP/mc6test}"; MC="${MC:-$KIT/tools/mc6test}"
FIX="$KIT/guest/60-netns-fixture.sh"
LOGROOT="${LOGROOT:-$KIT/logs}"
OPTMEM_DEFAULT=262144
SYNC_GRACE_MS=1500   # 송신 완료 신호 뒤 수신을 더 기다리는 시간

G=ff15::1      # 기본 그룹
G2=ff15::2     # 미가입/보조 그룹
GS=ff15::5     # source filter 그룹
MB=ff15::1:0   # --many / --wa 기준 (하위 16비트 = 인덱스)
F=ff15::f:0    # filler 기준 (사례 23~37). 시험 그룹과 겹치지 않음
FILL=(--fill 4 $F@veth1)   # filler 4개: ff15::f:0 ~ ff15::f:3 를 veth1 에

# ---------------------------------------------------------------- omem 비교 모드
if [[ "${1:-}" == "--omem" ]]; then
  [[ $# -eq 3 ]] || { echo "사용법: $0 --omem <태그A> <태그B>" >&2; exit 1; }
  A="$LOGROOT/$2"; B="$LOGROOT/$3"
  for f in "$A"/[0-9][0-9].txt; do
    n=$(basename "$f" .txt)
    if [[ ! -f "$B/$n.txt" ]]; then echo "== $n: $3 에 없음"; continue; fi
    grep -q '^omem=' "$f" "$B/$n.txt" || continue
    echo "== $n  $(head -1 "$f" | sed 's/^# //')"
    grep -q '^FIXTURE ERROR' "$f" "$B/$n.txt" && echo "  (FIXTURE ERROR 있음: 환경 문제)"
    # omem= 줄과, 그 앞의 구분 줄(== / --)만 위치대로 짝지어 출력
    paste -d '\t' <(grep -E '^(omem=|== |-- )' "$f") <(grep -E '^(omem=|== |-- )' "$B/$n.txt") |
      awk -F'\t' -v ta="$2" -v tb="$3" '
        function val(s) { sub(/^omem=/, "", s); sub(/ .*/, "", s); return s }
        function rest(s) { return index(s, " ") ? substr(s, index(s, " ") + 1) : "" }
        $1 !~ /^omem=/ && $2 !~ /^omem=/ { ctx = ($1 == $2) ? $1 : $1 " | " $2; next }
        {
          if (ctx != "") { print "  " ctx; ctx = "" }
          if ($1 ~ /^omem=/ && $2 ~ /^omem=/ && rest($1) == rest($2)) {
            va = val($1); vb = val($2)
            printf "  %s %-36s %s=%-8s %s=%s\n", (va == vb ? " " : "*"), rest($1), ta, va, tb, vb
          } else {
            printf "  ? %s=[%s]  %s=[%s]\n", ta, $1, tb, $2
          }
        }'
  done
  exit 0
fi

# ---------------------------------------------------------------- diff 모드
if [[ "${1:-}" == "--diff" ]]; then
  BEHAVIOR=0
  if [[ "${2:-}" == "--behavior" ]]; then BEHAVIOR=1; set -- "$1" "${@:3}"; fi
  [[ $# -eq 3 ]] || { echo "사용법: $0 --diff [--behavior] <태그A> <태그B>" >&2; exit 1; }
  A="$LOGROOT/$2"; B="$LOGROOT/$3"; rc=0
  # --behavior: "#" 줄에 더해 omem= 줄과 12 의 한도 줄도 뺀다
  behavior_filter() {
    if [[ $2 == 12.txt ]]; then grep -v '^#' "$1" | grep -v '^omem=' | grep -vE '^many: (first fail at |joined=)'
    else grep -v '^#' "$1" | grep -v '^omem='; fi
  }
  if (( BEHAVIOR )); then
    echo "(--behavior: \"#\" 줄, omem= 줄, 12 의 many: first fail / joined= 줄 제외)"
    for f in "$A"/[0-9][0-9].txt; do
      n=$(basename "$f")
      if [[ ! -f "$B/$n" ]]; then echo "== $n: $3 에 없음"; rc=1; continue; fi
      if grep -q '^FIXTURE ERROR' "$f" "$B/$n"; then
        echo "== $n: FIXTURE ERROR (환경 문제, 커널 동작 비교 안 함)"
        grep -H '^FIXTURE ERROR' "$f" "$B/$n" | sed "s|^$LOGROOT/||"
        rc=1; continue
      fi
      if ! out=$(diff -u --label "$2/$n" --label "$3/$n" <(behavior_filter "$f" "$n") <(behavior_filter "$B/$n" "$n")); then
        echo "$out"; rc=1
      else
        echo "== $n 같음"
      fi
    done
    exit $rc
  fi
  for f in "$A"/[0-9][0-9].txt; do
    n=$(basename "$f")
    if [[ ! -f "$B/$n" ]]; then echo "== $n: $3 에 없음"; rc=1; continue; fi
    if grep -q '^FIXTURE ERROR' "$f" "$B/$n"; then
      echo "== $n: FIXTURE ERROR (환경 문제, 커널 동작 비교 안 함)"
      grep -H '^FIXTURE ERROR' "$f" "$B/$n" | sed "s|^$LOGROOT/||"
      rc=1; continue
    fi
    if ! out=$(diff -u --label "$2/$n" --label "$3/$n" <(grep -v '^#' "$f") <(grep -v '^#' "$B/$n")); then
      echo "$out"; rc=1
    else
      echo "== $n 같음"
    fi
  done
  exit $rc
fi

TAG="${1:?사용법: $0 <태그> [NN ...] | --diff [--behavior] A B | --omem A B}"; shift
CASES=("$@")
[[ ${#CASES[@]} -eq 0 ]] && CASES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22
                                     23 24 25 26 27 28 29 30 31 32 33 34 35 36 37)
[[ -x "$MC" ]] || { echo "$MC 없음. make -C $KIT/tools 먼저." >&2; exit 1; }
grep -qa -- '--sync-grace' "$MC" || { echo "$MC 가 --sync-grace 를 모름 (옛 빌드). make -C $KIT/tools 먼저." >&2; exit 1; }
D="$LOGROOT/$TAG"
mkdir -p "$D/.work"

sudo -v || exit 1

# ---------------------------------------------------------------- 공통 함수
dmesg_wb() { sudo dmesg | grep -cE 'WARNING|BUG' || true; }

cleanup() {
  sudo pkill -x mc6test 2>/dev/null || true
  failslab_restore
  sudo sysctl -qw net.core.optmem_max=$OPTMEM_DEFAULT
  "$FIX" down >/dev/null 2>&1 || true
}
trap 'cleanup; [[ -n "${RF_SNAP:-}" ]] && rm -rf "$RF_SNAP"' EXIT
# bash 는 TERM/HUP 로 끝날 때 EXIT trap 을 돌리지 않는다 → exit 으로 바꿔 cleanup(failslab 복구 등)이 돌게 한다
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

# ---------------------------------------------------------------- failslab (사례 20)
FAILSLAB=/sys/kernel/debug/failslab
FAILSLAB_KEYS=(probability interval times space verbose task-filter cache-filter ignore-gfp-wait)
FAILSLAB_SAVED=()      # "키=값" (키 cache 는 슬랩 캐시의 failslab). 비어 있으면 복구할 것 없음
FAILSLAB_CACHE=""      # /sys/kernel/slab/<kmalloc 4096 캐시>
# kmalloc 4096 캐시의 sysfs 디렉터리 (5.4 는 kmalloc-4k, 이름이 kmalloc-4096 인 커널도 대비)
failslab_cache_dir() {
  local c
  for c in kmalloc-4k kmalloc-4096; do
    [[ -d /sys/kernel/slab/$c && ! -L /sys/kernel/slab/$c ]] && { echo "/sys/kernel/slab/$c"; return 0; }
  done
  return 1
}
# failslab_write <파일> <값> : 쓰고 다시 읽어 같은지 확인. 쓰기 실패나 값 불일치는 항목 이름과 함께 fixture 오류
failslab_write() {
  local got
  echo "$2" | sudo tee "$1" >/dev/null 2>"$W/.failslab_err" || { fixture_err "failslab: $1 <- $2 실패: $(head -1 "$W/.failslab_err")"; return 1; }
  got=$(sudo cat "$1" 2>"$W/.failslab_err") || { fixture_err "failslab: $1 <- $2 후 다시 읽기 실패: $(head -1 "$W/.failslab_err")"; return 1; }
  [[ $got == "$2" ]] || { fixture_err "failslab: $1 <- $2 가 들어가지 않음 (다시 읽은 값: $got)"; return 1; }
}
failslab_save() {
  local k v
  FAILSLAB_SAVED=()
  v=$(sudo cat "$FAILSLAB_CACHE/failslab") || return 1
  FAILSLAB_SAVED+=("cache=$v")
  for k in "${FAILSLAB_KEYS[@]}"; do
    v=$(sudo cat "$FAILSLAB/$k") || { FAILSLAB_SAVED=(); return 1; }
    FAILSLAB_SAVED+=("$k=$v")
  done
}
# 저장해 둔 값으로 되돌린다. 캐시 플래그를 먼저 꺼서 주입을 바로 멈춘다. cleanup/EXIT trap 에서도 호출 (여러 번 호출해도 됨)
failslab_restore() {
  (( ${#FAILSLAB_SAVED[@]} )) || return 0
  local kv rc=0
  for kv in "${FAILSLAB_SAVED[@]}"; do
    if [[ $kv == cache=* ]]; then echo "${kv#cache=}" | sudo tee "$FAILSLAB_CACHE/failslab" >/dev/null || rc=1
    else echo "${kv#*=}" | sudo tee "$FAILSLAB/${kv%%=*}" >/dev/null || rc=1; fi
  done
  (( rc )) && echo "failslab 복구 실패: ${FAILSLAB_SAVED[*]} ($FAILSLAB_CACHE)" >&2
  FAILSLAB_SAVED=()
  return $rc
}
# 현재 값 한 줄 ("#" 줄용)
failslab_state() {
  local k out="cache($(basename "$FAILSLAB_CACHE"))=$(sudo cat "$FAILSLAB_CACHE/failslab" 2>&1)"
  for k in "${FAILSLAB_KEYS[@]}"; do out+=" $k=$(sudo cat "$FAILSLAB/$k" 2>&1)"; done
  echo "$out"
}

# 사례 실패 표시: "FAIL <이유>" 를 # 없이 남기고 이 사례를 실패로 기록
CASE_FAIL=0
fail() { echo "FAIL $*"; CASE_FAIL=1; }

# 환경 오류 표시: 커널 동작이 아닌 환경 문제. 백그라운드 서브셸(txf ... &)에서도 남도록 파일에 쌓고,
# 사례가 끝나면 실행부가 "FIXTURE ERROR ..." 줄로 옮긴다.
fixture_err() { echo "$*" >>"$W/.fixture_errors"; }

# tx_src_ready <주소...> : tx netns veth0 의 주소가 tentative/dadfailed 없이 있고 실제로 bind 되는지 확인.
# 될 때까지 최대 5초 대기, 끝내 안 되면 fixture 오류.
tx_src_ready() {
  local a st i
  for a in "$@"; do
    for i in $(seq 1 50); do
      st=$(sudo ip -n tx -6 addr show dev veth0 2>/dev/null | grep -E "inet6 ${a}/")
      if [[ -n "$st" && "$st" != *tentative* && "$st" != *dadfailed* ]] &&
         sudo ip netns exec tx python3 -I -c \
           'import socket,sys; socket.socket(socket.AF_INET6, socket.SOCK_DGRAM).bind((sys.argv[1], 0))' \
           "$a" 2>/dev/null; then
        continue 2
      fi
      sleep 0.1
    done
    st=$(sed -E 's/^ +//' <<<"$st")
    fixture_err "src $a: 5초 안에 bind 가능 상태가 되지 않음 (${st:-veth0 에 주소 없음})"
  done
}

# need <이름> <ERE> <최소 개수> <설명> : $W/<이름>.out 에 ERE 와 맞는 줄이 최소 개수 이상인지
need() {
  local n
  n=$(grep -cE "$2" "$W/$1.out" 2>/dev/null)
  (( ${n:-0} >= $3 )) || fail "$1: $4 (기대 >= $3, 실제 ${n:-0})"
}

# netns 재생성 + DAD 대기 + ifindex 기록
ns_up() {
  local optmem="${1:-$OPTMEM_DEFAULT}"
  sudo pkill -x mc6test 2>/dev/null || true
  "$FIX" down >>"$W/fixture.log" 2>&1
  OPTMEM_MAX="$optmem" "$FIX" up >>"$W/fixture.log" 2>&1
  tx_src_ready fd00::1
  VIDX=$(sudo ip netns exec rx cat /sys/class/net/veth1/ifindex)
  DIDX=$(sudo ip netns exec rx cat /sys/class/net/dummy0/ifindex)
}

# if=<숫자> → 인터페이스 이름
norm() { sed -E "s/\bif=${VIDX}\b/if=veth1/g; s/\bif=${DIDX}\b/if=dummy0/g"; }

# rx 를 백그라운드로 띄우고 "ready" 를 기다린다. --hold 가 없으면 --hold 0 을 붙인다.
#   rx_bg <이름> <mc6test rx 인자...>   → $W/<이름>.out, PID_<이름>(sudo pid), MPID_<이름>(mc6test pid)
rx_bg() {
  local name=$1; shift
  local args=("$@")
  # --hold 은 1단계 옵션: --phase2 가 있으면 그 앞만 보고, 붙일 때도 그 앞에 넣는다 (없으면 기존처럼 맨 뒤)
  local k p=${#args[@]}
  for k in "${!args[@]}"; do [[ ${args[$k]} == --phase2 ]] && { p=$k; break; }; done
  [[ " ${args[*]:0:p} " == *" --hold "* ]] || { args=("${args[@]:0:p}" --hold 0 "${args[@]:p}"); p=$((p + 2)); }
  # 1단계 --timeout (없으면 mc6test 기본 3). 0 이 아니면 송신 완료 신호에 맞춰 끝나도록 --sync-grace
  local to=3
  for k in "${!args[@]}"; do (( k < p )) && [[ ${args[$k]} == --timeout ]] && to=${args[$((k + 1))]}; done
  printf -v "SYNC_$name" '%s' 0
  printf -v "PH2_$name" '%s' $(( p < ${#args[@]} ))
  if [[ $to != 0 ]]; then
    args=("${args[@]:0:p}" --sync-grace $SYNC_GRACE_MS "${args[@]:p}")
    printf -v "SYNC_$name" '%s' 1
  fi
  sudo ip netns exec rx "$MC" rx "${args[@]}" >"$W/$name.out" 2>&1 &
  printf -v "PID_$name" '%s' $!
  local i st ok=0
  for i in $(seq 1 200); do
    grep -q 'ready pid=' "$W/$name.out" 2>/dev/null && { ok=1; break; }
    st=$(ps -o stat= -p "$!" 2>/dev/null); [[ -z "$st" || "$st" == Z* ]] && break
    sleep 0.05
  done
  (( ok )) || fail "rx_bg $name: ready 없음 (10초 시간 초과 또는 먼저 종료)"
  printf -v "MPID_$name" '%s' "$(sed -n 's/^# ready pid=\([0-9]*\).*/\1/p' "$W/$name.out" | head -1)"
}
# rx_signal <이름> USR1|USR2 : --sync-grace rx 에 "이 단계 송신 끝" 신호 (1단계 USR1, 2단계 USR2)
rx_signal() {
  local s="SYNC_$1" m="MPID_$1" p="PID_$1"
  [[ ${!s:-0} == 1 ]] || return 0
  echo "$1 $2 $EPOCHREALTIME" >>"$W/.rx_sync"
  if [[ -n "${!m:-}" ]]; then sudo kill -s "$2" "${!m}" 2>/dev/null
  else sudo pkill -"$2" -P "${!p}" 2>/dev/null; fi   # ready 를 못 본 경우: sudo 의 자식(mc6test)
  return 0
}
# rx_wait <이름> : 마지막 단계 송신 끝 신호를 보내고 종료를 기다린다
rx_wait() {
  local v="PID_$1" h="PH2_$1"
  if [[ ${!h:-0} == 1 ]]; then rx_signal "$1" USR2; else rx_signal "$1" USR1; fi
  wait "${!v}" 2>/dev/null
}
rx_kill() { local v="MPID_$1"; [[ -n "${!v:-}" ]] && sudo kill "${!v}" 2>/dev/null; rx_wait "$1"; }

rxf() { sudo ip netns exec rx "$MC" rx "$@" 2>&1; }   # 전경 rx
# txf <이름> <mc6test tx 인자...> → $W/<이름>.out. 종료 코드 != 0 이거나 "sent " 줄이 없으면 fixture 오류.
txf() {
  local name=$1; shift
  local rc ts=$EPOCHREALTIME
  sudo ip netns exec tx "$MC" tx --dev veth0 "$@" >"$W/$name.out" 2>&1; rc=$?
  echo "$name $ts $EPOCHREALTIME $rc" >>"$W/.tx_times"
  if (( rc != 0 )) || ! grep -q '^sent ' "$W/$name.out"; then
    fixture_err "tx $name: rc=$rc$(grep -q '^sent ' "$W/$name.out" || echo ', sent 줄 없음'): $(head -1 "$W/$name.out")"
  fi
  return $rc
}

show() { echo "-- $1"; cat "$W/$1.out"; }

# rx netns 안 장치 가입 여부
maddr() {
  local g=$1 dev
  for dev in veth1 dummy0; do
    if sudo ip -n rx -6 maddr show dev $dev | grep -qE "inet6 ${g}( |$)"; then
      echo "maddr $dev $g=yes"; else echo "maddr $dev $g=no"; fi
  done
}

# ---------------------------------------------------------------- 사례
c01() { echo "# 그룹 1개 가입, 가입/미가입 그룹 송신 → 가입 그룹만 수신 (미가입 그룹은 helper 소켓이 veth1 에 가입)"
  ns_up
  rx_bg helper --port 7999 --join $G2@veth1 --timeout 10
  rx_bg main --port 7000 --mcall 0 --join $G@veth1 --timeout 1 --sorted
  txf tx2 --port 7000 --group $G2 --count 3 --seq-start 100
  txf tx1 --port 7000 --group $G  --count 3
  rx_wait main; rx_kill helper
  show main; show helper; show tx2; show tx1
  maddr $G2
}

c02() { echo "# 같은 그룹 ifindex=0 두 번 가입 → 두 번째 EADDRINUSE"
  ns_up
  rxf --port 7000 --join $G --join $G --close
}

c03() { echo "# 같은 그룹을 veth1, dummy0 에 명시 ifindex 로 가입 → 둘 다 성공"
  ns_up
  rx_bg main --port 7000 --join $G@veth1 --join $G@dummy0 --hold 5 --timeout 0
  maddr $G
  rx_wait main; show main
}

c04() { echo "# 03 상태에서 ifindex=0 으로 탈퇴 → 최신(dummy0) 항목 제거, 남은 1개"
  ns_up
  rx_bg main --port 7000 --join $G@veth1 --join $G@dummy0 --drop $G --hold 5 --timeout 0
  maddr $G
  rx_wait main; show main
  echo "-- 남은 항목 재탈퇴(ifindex=0) / 한 번 더(없어야 함)"
  rxf --port 7001 --join $G@veth1 --join $G@dummy0 --drop $G --drop $G --drop $G --close
}

# 05~08 공통: tx 에 fd00::9 추가 후 두 출발지로 3개씩 송신
tx_two_src() {
  sudo ip -n tx addr add fd00::9/64 dev veth0 nodad
  tx_src_ready fd00::1 fd00::9
  txf tx1 --port 7000 --group $GS --src fd00::1 --count 3 --seq-start 0
  txf tx9 --port 7000 --group $GS --src fd00::9 --count 3 --seq-start 100
}

c05() { echo "# veth1 INCLUDE{fd00::1}, dummy0 INCLUDE{fd00::9} 순 가입 → 최신 항목(dummy0) 기준 fd00::9 만 수신"
  ns_up
  rx_bg main --port 7000 --join-src $GS@veth1=fd00::1 --join-src $GS@dummy0=fd00::9 --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
}

c06() { echo "# 05 에서 dummy0 항목 탈퇴 후 송신 → fd00::1 만 수신 (탈퇴는 수신 시작 전에 수행)"
  ns_up
  rx_bg main --port 7000 --join-src $GS@veth1=fd00::1 --join-src $GS@dummy0=fd00::9 --drop $GS@dummy0 --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
}

c07() { echo "# 05 의 가입 순서만 반대 (dummy0 먼저, veth1 나중) → 최신(veth1) 기준 fd00::1 만 수신"
  ns_up
  rx_bg main --port 7000 --join-src $GS@dummy0=fd00::9 --join-src $GS@veth1=fd00::1 --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
}

c08() { echo "# ASM 가입 후 --block fd00::1, 두 출발지 송신 → fd00::9 만 수신"
  ns_up
  rx_bg main --port 7000 --join $GS@veth1 --block $GS@veth1=fd00::1 --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
}

c09() { echo "# mcall=1 소켓은 미가입 그룹도 수신 (helper 가 그 그룹 가입). 대조: mcall=0 소켓은 0"
  ns_up
  rx_bg helper --port 7999 --join $G@veth1 --timeout 10
  rx_bg mc1 --port 7000 --mcall 1 --timeout 1 --sorted
  rx_bg mc0 --port 7000 --mcall 0 --timeout 1 --sorted
  txf tx --port 7000 --group $G --count 3
  rx_wait mc1; rx_wait mc0; rx_kill helper
  show mc1; show mc0; show helper; show tx
}

# rx netns 의 UDP6 수신 오류 카운터 (소켓 버퍼 초과로 버려진 패킷 구분용)
rx_nstat() {
  local out
  out=$(sudo ip netns exec rx nstat -asz Udp6RcvbufErrors Udp6InErrors 2>&1)
  echo "nstat rx Udp6RcvbufErrors=$(awk '$1=="Udp6RcvbufErrors"{print $2}' <<<"$out") Udp6InErrors=$(awk '$1=="Udp6InErrors"{print $2}' <<<"$out")"
  sed 's/^/# nstat| /' <<<"$out"
}

many_run() {  # many_run N [TIMEOUT] [mc6test rx 추가 인자...] : N 개 가입, N 개 그룹에 1개씩 송신
  local n=$1 to=${2:-3}; shift 2 2>/dev/null || shift $#
  echo "== N=$n"
  rx_bg m$n --port 7000 --many $n $MB@veth1 --count $n --timeout $to --sorted "$@"
  txf tx$n --port 7000 --many $n $MB
  rx_wait m$n; show m$n; show tx$n
  [[ " $* " == *" --omem "* ]] && need m$n '^omem=[0-9]+ stage=(joined|hold)$' 2 "omem= 줄 (joined, hold)"
}

c10() { echo "# 그룹 3/4/5 개 가입, 각 그룹 송신 → 전부 수신. 가입 직후·hold 의 omem= (S: 4개째에 테이블 크기만큼 증가)"
  ns_up
  for n in 3 4 5; do many_run $n 3 --omem; done
}

c11() { echo "# 그룹 31/32/33/64/65/1024 개 가입 → 가입 반환값 전부 0, 전부 수신"
  ns_up
  for n in 31 32 33 64 65 1024; do many_run $n 15; done
  rx_nstat
}

c12() { echo "# optmem_max=20480 에서 가입 한계 개수와 첫 실패 errno (끝나면 $OPTMEM_DEFAULT 로 복구)"
  ns_up 20480
  echo "optmem_max=$(sysctl -n net.core.optmem_max)"
  rxf --port 7000 --many 1024 $MB@veth1 --close
  sudo sysctl -qw net.core.optmem_max=$OPTMEM_DEFAULT
  echo "optmem_max restored=$(sysctl -n net.core.optmem_max)"
}

c13() { echo "# 1024 가입 → 앞 1023 탈퇴 → 1024 그룹 전부 송신 → 남은 1개(k=1023, 마지막 송신)만 수신"
  ns_up
  rx_bg main --port 7000 --many 1024 $MB@veth1 --drop-many 1023 --count 1 --timeout 15 --sorted
  txf tx --port 7000 --many 1024 $MB
  rx_wait main; show main; show tx
  rx_nstat
}

c14() { echo "# 단계별·--hold 의 omem= : 7000 가입 없음 / 7001 1024 가입 중 / 7002 1024 가입 후 전부 탈퇴"
  ns_up
  rx_bg base --port 7000 --omem --hold 2 --timeout 0
  rx_bg join --port 7001 --many 1024 $MB@veth1 --omem --hold 2 --timeout 0
  rx_bg dropall --port 7002 --many 1024 $MB@veth1 --drop-many 1024 --omem --hold 2 --timeout 0
  rx_wait base; rx_wait join; rx_wait dropall
  show base; show join; show dropall
  need base '^omem=[0-9]+ stage=' 2 "omem= 줄 (joined, hold)"
  need join '^omem=[0-9]+ stage=' 2 "omem= 줄 (joined, hold)"
  need dropall '^omem=[0-9]+ stage=' 3 "omem= 줄 (joined, dropped, hold)"
}

c15() { echo "# 가입 상태에서 close 후 같은 포트로 새 소켓 bind → 성공 (새 소켓 가입·수신까지)"
  ns_up
  echo "-- old"; rxf --port 7000 --join $G@veth1 --close
  rx_bg new --port 7000 --join $G@veth1 --timeout 1 --sorted
  txf tx --port 7000 --group $G --count 3
  rx_wait new; show new; show tx
}

c16() { echo "# 가입 상태에서 --addrform → 반환값과 전후 omem= (대조: 7001 은 addrform 없이 가입만)"
  ns_up
  rx_bg af --port 7000 --join $G@veth1 --addrform --omem --hold 2 --timeout 0
  rx_bg ref --port 7001 --join $G@veth1 --omem --hold 2 --timeout 0
  maddr $G
  rx_wait af; rx_wait ref; show af; show ref
  need af '^omem=[0-9]+ stage=' 4 "omem= 줄 (joined, addrform_before, addrform_after, hold)"
  need ref '^omem=[0-9]+ stage=' 2 "omem= 줄 (joined, hold)"
}

c17() { echo "# $G 수신 중 같은 소켓에서 $G2 churn 1000 (두 그룹 모두 계속 송신) → 커널 경고 없음"
  ns_up
  local b a
  b=$(dmesg_wb)
  rx_bg main --port 7000 --join $G@veth1 --churn 1000 $G2@veth1 --count 1000 --timeout 15
  txf tx1 --port 7000 --group $G  --count 1000 &
  local t1=$!
  txf tx2 --port 7000 --group $G2 --count 1000 &
  local t2=$!
  wait $t1 $t2; rx_wait main
  sleep 0.2
  a=$(dmesg_wb)
  echo "-- main (recv 줄은 그룹별 개수로 요약)"
  grep -v '^recv' "$W/main.out"
  grep '^recv' "$W/main.out" | sed -E 's/.*group=([^ ]*).*/recv_by_group \1/' | sort | uniq -c | sed 's/^ *//'
  show tx1; show tx2
  echo "dmesg_new_warn_bug=$((a - b))"
  echo "# dmesg WARNING|BUG before=$b after=$a"
  rx_nstat
}

c18() { echo "# 수신·송신 중 ip netns del rx (+ rx 프로세스 종료) → dmesg 경고 없음"
  ns_up
  local b a rc
  b=$(dmesg_wb)
  rx_bg main --port 7000 --join $G@veth1 --timeout 3
  # 송신 중 veth 쌍이 사라져 tx 가 sendto 실패로 끝나는 것이 정상 → txf(실패 검사) 대신 직접 실행
  sudo ip netns exec tx "$MC" tx --dev veth0 --port 7000 --group $G --count 1500 >"$W/tx.out" 2>&1 &
  local t=$!
  sleep 0.5
  sudo ip netns del rx; rc=$?
  echo "netns del rx rc=$rc"
  rx_kill main
  wait $t
  sleep 1
  a=$(dmesg_wb)
  echo "dmesg_new_warn_bug=$((a - b))"
  echo "# dmesg WARNING|BUG before=$b after=$a"
  echo "# tx veth0 after: $(sudo ip -n tx link show veth0 2>&1 | head -1)"
  sed 's/^/# main| /' "$W/main.out"
  sed 's/^/# tx| /' "$W/tx.out"
}

c19() { echo "# --wa 1024: 소켓 1024 개(포트 7000+i, 그룹 i) → 그룹별 1개씩 전부 수신"
  ns_up
  rx_bg wa --port 7000 --wa 1024 $MB@veth1 --count 1024 --timeout 15
  txf tx --port 7000 --many 1024 $MB --port-step 1
  rx_wait wa; show wa; show tx
  rx_nstat
}

c20() { echo "# 테이블 할당 실패 주입 (failslab: kmalloc-4k, make-it-fail 프로세스만). 한 소켓에서 fail 켜고 5개 가입(반환값 0, 테이블 없이 omem=5x88) → 5개 그룹 수신·미가입 그룹 0 → fail 끄고 1개 더 가입(테이블 생성, 6x88+2064) → 6개 수신 → 전부 탈퇴 omem=0"
  # failslab 없는 커널(v0, vl, vs)은 기존 결과와 같은 한 줄만
  if ! sudo test -d "$FAILSLAB"; then echo "N/A on V0"; return 0; fi
  if ! FAILSLAB_CACHE=$(failslab_cache_dir); then
    fixture_err "failslab: /sys/kernel/slab/kmalloc-4k (또는 kmalloc-4096) 디렉터리 없음 (캐시가 병합됐을 수 있음)"; return 0
  fi
  ns_up
  failslab_save || { fixture_err "failslab: 현재 설정을 읽지 못함"; return 0; }
  echo "# failslab before: $(failslab_state)"
  # times: 5.4 는 음수(-1 = 무제한)를 받지 않으므로(EINVAL) 충분히 큰 양수
  # ignore-gfp-wait=N: sock_kmalloc 은 GFP_KERNEL(__GFP_DIRECT_RECLAIM) 이라 Y 면 실패하지 않는다
  failslab_write "$FAILSLAB_CACHE/failslab" 1 &&
  failslab_write "$FAILSLAB/cache-filter" Y &&
  failslab_write "$FAILSLAB/task-filter" Y &&
  failslab_write "$FAILSLAB/ignore-gfp-wait" N &&
  failslab_write "$FAILSLAB/verbose" 0 &&
  failslab_write "$FAILSLAB/interval" 1 &&
  failslab_write "$FAILSLAB/space" 0 &&
  failslab_write "$FAILSLAB/probability" 100 &&
  failslab_write "$FAILSLAB/times" 1000000 || { failslab_restore; return 0; }
  echo "# failslab set: $(failslab_state)"
  # 미가입 그룹 ff15::1:5 를 helper 가 veth1 에 가입해 두어 소켓 필터까지 오게 한다 (main 은 mcall=0)
  rx_bg helper --port 7999 --join ${MB%:0}:5@veth1 --timeout 15
  rx_bg main --port 7000 --mcall 0 --make-it-fail 1 --fill 5 $MB@veth1 --omem --timeout 1 --sorted \
    --phase2 --make-it-fail 0 --fill 1 ${MB%:0}:5@veth1 --mark joined6 --min-seq 100 --count 6 --timeout 3 --sorted \
    --post --unfill 6 $MB@veth1 --mark dropped_all
  txf tx1 --port 7000 --many 6 $MB
  rx_ready2 main
  txf tx2 --port 7000 --many 6 $MB --seq-start 100
  rx_wait main; rx_kill helper
  failslab_restore || fixture_err "failslab: 원래 설정으로 복구 실패"
  echo "# failslab after: $(failslab_state)"
  show main; show helper; show tx1; show tx2
  need main '^make_it_fail=1 rc=0 errno=0$' 1 "make-it-fail 켜기 성공"
  # need 는 norm 전 원본을 보므로 if= 는 숫자
  need main "^fill ff15::1:0 n=5 if=$VIDX ok=5 failed=0\$" 1 "fail 중 5개 가입 전부 성공"
  need main '^make_it_fail=0 rc=0 errno=0$' 1 "make-it-fail 끄기 성공"
  need main "^fill ff15::1:5 n=1 if=$VIDX ok=1 failed=0\$" 1 "6번째 가입 성공"
  need main "^unfill ff15::1:0 n=6 if=$VIDX ok=6 failed=0\$" 1 "6개 전부 탈퇴"
  need main '^total=5$' 1 "1단계 total=5"
  need main '^total=6$' 1 "2단계 total=6"
  local leak
  leak=$(awk '/^phase2$/{exit} /^recv .*group=ff15::1:5 /' "$W/main.out" | wc -l)
  (( leak == 0 )) || fail "1단계에 미가입 그룹 ff15::1:5 수신 $leak 개"
  need main "$OMEM_RE" 4 "omem= 줄 (joined, hold, joined6, dropped_all)"
}

c21() { echo "# 4개 가입 → 전부 탈퇴 → 다시 4개 가입 → 각 그룹 수신. 단계마다 omem="
  ns_up
  rx_bg main --port 7000 --many 4 $MB@veth1 --drop-many 4 --rejoin --omem --count 4 --timeout 3 --sorted
  maddr ${MB%:0}:3
  txf tx --port 7000 --many 4 $MB
  rx_wait main; show main; show tx
  need main '^omem=[0-9]+ stage=' 4 "omem= 줄 (joined, dropped, rejoined, hold)"
}

c22() { echo "# 그룹 2개 가입한 IPv6 TCP 리스닝 소켓에서 accept (일반 IPv6 / v4-mapped), 자식 close → 부모 close. 단계마다 부모/자식 omem=, 장치 가입 여부"
  ns_up
  local b a conn port rc
  b=$(dmesg_wb)
  for conn in v6 v4; do
    if [[ $conn == v6 ]]; then port=7100; else port=7101; fi
    echo "== conn=$conn port=$port"
    # maddr 는 mc6test 가 단계마다 자기 netns 의 /proc/net/igmp6 에서 직접 읽어 출력 (동기화 불필요)
    timeout 15 sudo ip netns exec rx "$MC" tcp --port $port --join $G@veth1 --join $G2@veth1 --conn $conn \
      >"$W/t$conn.out" 2>&1
    rc=$?
    show t$conn
    echo "tcp $conn rc=$rc"
    (( rc == 0 )) || fail "tcp $conn: 종료 코드 $rc (124=스크립트 timeout, 142=mc6test 10초 alarm)"
    need t$conn '^omem=[0-9]+ stage=(listen|accepted|child_closed) sock=(parent|child)$' 4 "omem= 줄 (listen, accepted x2, child_closed)"
    need t$conn '^maddr (veth1|dummy0) ff15::[12]=(yes|no) stage=' 12 "maddr 줄 (그룹 2 x 장치 2 x 단계 3)"
    need t$conn '^parent closed rc=0$' 1 "parent closed"
  done
  sleep 1   # kfree_rcu 이후 경고까지 보기 위해
  a=$(dmesg_wb)
  echo "dmesg_new_warn_bug=$((a - b))"
  echo "# dmesg WARNING|BUG before=$b after=$a"
  if (( a > b )); then sudo dmesg | grep -E 'WARNING|BUG' | tail -n $((a - b)) | sed 's/^/# dmesg| /'; fi
}

# ---------------------------------------------------------------- 사례 23~37: 소켓 해시 테이블이 있는 상태
# (vs: 소켓 가입 수 4 에서 테이블 생성, 0 에서 해제. v0/vl 은 테이블 없음 → 판정은 같고 omem= 만 달라야 함)

# tx veth0 에 fd00::9 를 (없으면) 추가하고 fd00::1, fd00::9 가 bind 가능할 때까지 대기
tx_src9() {
  sudo ip -n tx -6 addr show dev veth0 | grep -q 'inet6 fd00::9/' ||
    sudo ip -n tx addr add fd00::9/64 dev veth0 nodad
  tx_src_ready fd00::1 fd00::9
}
# tx2 <접미사> <포트> <seq 기준> : $GS 로 fd00::1 에서 3개(seq 기준~), fd00::9 에서 3개(seq 기준+100~)
#   → $W/tx1<접미사>.out, $W/tx9<접미사>.out
tx2() {
  txf tx1$1 --port $2 --group $GS --src fd00::1 --count 3 --seq-start $3
  txf tx9$1 --port $2 --group $GS --src fd00::9 --count 3 --seq-start $(( $3 + 100 ))
}
# rx_ready2 <이름> : rx_bg 로 띄운 --phase2 rx 가 2단계 준비("# ready2")를 출력할 때까지 대기 (최대 20초)
rx_ready2() {
  local v="PID_$1" i st
  rx_signal "$1" USR1   # 1단계 송신 끝 → 1단계 수신을 끝내게
  for i in $(seq 1 400); do
    grep -q '^# ready2 pid=' "$W/$1.out" 2>/dev/null && return 0
    st=$(ps -o stat= -p "${!v}" 2>/dev/null); [[ -z "$st" || "$st" == Z* ]] && break
    sleep 0.05
  done
  fail "rx_ready2 $1: ready2 없음 (20초 시간 초과 또는 먼저 종료)"
}
OMEM_RE='^omem=[0-9]+ stage='

c23() { echo "# [pre] filler 4 → 같은 그룹 veth1, dummy0 명시 가입, ifindex=0 중복 가입(EADDRINUSE) → ifindex=0 탈퇴는 최신(dummy0) 제거 (03, 04 대응)"
  ns_up
  echo "== 03 대응: 두 장치 가입 + ifindex=0 중복 가입"
  rx_bg join --port 7000 "${FILL[@]}" --mark filled --join $G@veth1 --join $G@dummy0 --join $G --omem --hold 5 --timeout 0
  maddr $G
  rx_wait join; show join
  echo "== 04 대응: ifindex=0 탈퇴"
  rx_bg drop --port 7001 "${FILL[@]}" --mark filled --join $G@veth1 --join $G@dummy0 --join $G --drop $G --omem --hold 5 --timeout 0
  maddr $G
  rx_wait drop; show drop
  echo "-- 남은 항목 재탈퇴(ifindex=0) / 한 번 더(없어야 함)"
  rxf --port 7002 "${FILL[@]}" --join $G@veth1 --join $G@dummy0 --drop $G --drop $G --drop $G --omem --close
  need join "$OMEM_RE" 3 "omem= 줄 (filled, joined, hold)"
  need drop "$OMEM_RE" 4 "omem= 줄 (filled, joined, dropped, hold)"
}

c24() { echo "# [pre] filler 4 → veth1 INCLUDE{fd00::1}, dummy0 INCLUDE{fd00::9} 순 가입, 두 출발지 송신 (05 대응, 결과는 05 와 같아야 함)"
  ns_up
  rx_bg main --port 7000 "${FILL[@]}" --mark filled --join-src $GS@veth1=fd00::1 --join-src $GS@dummy0=fd00::9 --omem --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
  need main "$OMEM_RE" 3 "omem= 줄 (filled, joined, hold)"
}

c25() { echo "# [pre] 24 에서 dummy0 항목 탈퇴 후 송신 → fd00::1 만 수신 (06 대응, 탈퇴는 수신 시작 전에 수행)"
  ns_up
  rx_bg main --port 7000 "${FILL[@]}" --mark filled --join-src $GS@veth1=fd00::1 --join-src $GS@dummy0=fd00::9 --drop $GS@dummy0 --omem --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
  need main "$OMEM_RE" 4 "omem= 줄 (filled, joined, dropped, hold)"
}

c26() { echo "# [pre] 24 의 가입 순서 반대 (dummy0 먼저, veth1 나중) → 최신(veth1) 기준 fd00::1 만 수신 (07 대응)"
  ns_up
  rx_bg main --port 7000 "${FILL[@]}" --mark filled --join-src $GS@dummy0=fd00::9 --join-src $GS@veth1=fd00::1 --omem --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
  need main "$OMEM_RE" 3 "omem= 줄 (filled, joined, hold)"
}

c27() { echo "# [post] 같은 그룹 2개 항목 가입 뒤 filler 4 (4개째에 테이블 생성) → 생성 시 순서 보존. a: 05 순서(결과는 05 와 같아야 함), b: 07 순서(fd00::1 만)"
  ns_up
  tx_src9
  echo "== a: veth1 INCLUDE{fd00::1} → dummy0 INCLUDE{fd00::9} → filler 4"
  rx_bg a --port 7000 --join-src $GS@veth1=fd00::1 --join-src $GS@dummy0=fd00::9 --omem --mark joined2 "${FILL[@]}" --timeout 1 --sorted
  tx2 a 7000 0; rx_wait a
  show a; show tx1a; show tx9a
  echo "== b: dummy0 INCLUDE{fd00::9} → veth1 INCLUDE{fd00::1} → filler 4"
  rx_bg b --port 7001 --join-src $GS@dummy0=fd00::9 --join-src $GS@veth1=fd00::1 --omem --mark joined2 "${FILL[@]}" --timeout 1 --sorted
  tx2 b 7001 0; rx_wait b
  show b; show tx1b; show tx9b
  need a "$OMEM_RE" 3 "omem= 줄 (joined2, joined, hold)"
  need b "$OMEM_RE" 3 "omem= 줄 (joined2, joined, hold)"
}

c28() { echo "# [pre] filler 4 → ASM 가입 후 --block fd00::1, 두 출발지 송신 → fd00::9 만 수신 (08 대응)"
  ns_up
  rx_bg main --port 7000 "${FILL[@]}" --mark filled --join $GS@veth1 --block $GS@veth1=fd00::1 --omem --timeout 1 --sorted
  tx_two_src; rx_wait main
  show main; show tx1; show tx9
  need main "$OMEM_RE" 3 "omem= 줄 (filled, joined, hold)"
}

c29() { echo "# [pre] filler 4 인 mcall=1 소켓은 미가입 그룹도 수신, filler 4 인 mcall=0 소켓은 0 (helper 가 그 그룹 가입, 09 대응)"
  ns_up
  rx_bg helper --port 7999 --join $G@veth1 --timeout 10
  rx_bg mc1 --port 7000 --mcall 1 "${FILL[@]}" --omem --timeout 1 --sorted
  rx_bg mc0 --port 7000 --mcall 0 "${FILL[@]}" --omem --timeout 1 --sorted
  txf tx --port 7000 --group $G --count 3
  rx_wait mc1; rx_wait mc0; rx_kill helper
  show mc1; show mc0; show helper; show tx
  need mc1 "$OMEM_RE" 2 "omem= 줄 (joined, hold)"
  need mc0 "$OMEM_RE" 2 "omem= 줄 (joined, hold)"
}

c30() { echo "# [pre] filler 4 + G 가입(5개) 상태에서 close 후 같은 포트로 새 소켓 bind → 성공 (새 소켓도 5개 가입·수신, 15 대응)"
  ns_up
  echo "-- old"; rxf --port 7000 "${FILL[@]}" --join $G@veth1 --omem --close
  rx_bg new --port 7000 "${FILL[@]}" --join $G@veth1 --omem --timeout 1 --sorted
  txf tx --port 7000 --group $G --count 3
  rx_wait new; show new; show tx
  need new "$OMEM_RE" 2 "omem= 줄 (joined, hold)"
}

c31() { echo "# [pre] filler 4 + G 가입(5개) 상태에서 --addrform → 반환값과 전후 omem= (후 0, 대조: 7001 은 addrform 없이 5개 가입만, 16 대응)"
  ns_up
  rx_bg af --port 7000 "${FILL[@]}" --join $G@veth1 --addrform --omem --hold 2 --timeout 0
  rx_bg ref --port 7001 "${FILL[@]}" --join $G@veth1 --omem --hold 2 --timeout 0
  maddr $G
  rx_wait af; rx_wait ref; show af; show ref
  need af "$OMEM_RE" 4 "omem= 줄 (joined, addrform_before, addrform_after, hold)"
  need ref "$OMEM_RE" 2 "omem= 줄 (joined, hold)"
}

c32() { echo "# 그룹 5개 가입한 IPv6 TCP 리스닝 소켓에서 accept (일반 IPv6 / v4-mapped), 자식 close → 부모 close. 단계마다 부모/자식 omem=, 장치 가입 여부 (22 대응)"
  ns_up
  local b a conn port rc
  b=$(dmesg_wb)
  for conn in v6 v4; do
    if [[ $conn == v6 ]]; then port=7100; else port=7101; fi
    echo "== conn=$conn port=$port"
    timeout 15 sudo ip netns exec rx "$MC" tcp --port $port --join $G@veth1 --join $G2@veth1 \
      --join ff15::f:0@veth1 --join ff15::f:1@veth1 --join ff15::f:2@veth1 --conn $conn >"$W/t$conn.out" 2>&1
    rc=$?
    show t$conn
    echo "tcp $conn rc=$rc"
    (( rc == 0 )) || fail "tcp $conn: 종료 코드 $rc (124=스크립트 timeout, 142=mc6test 10초 alarm)"
    need t$conn '^omem=[0-9]+ stage=(listen|accepted|child_closed) sock=(parent|child)$' 4 "omem= 줄 (listen, accepted x2, child_closed)"
    need t$conn '^maddr (veth1|dummy0) ff15::(1|2|f:[0-2])=(yes|no) stage=' 30 "maddr 줄 (그룹 5 x 장치 2 x 단계 3)"
    need t$conn '^parent closed rc=0$' 1 "parent closed"
  done
  sleep 1   # kfree_rcu 이후 경고까지 보기 위해
  a=$(dmesg_wb)
  echo "dmesg_new_warn_bug=$((a - b))"
  echo "# dmesg WARNING|BUG before=$b after=$a"
  if (( a > b )); then sudo dmesg | grep -E 'WARNING|BUG' | tail -n $((a - b)) | sed 's/^/# dmesg| /'; fi
}

c33() { echo "# MCAST_MSFILTER: 가입 1개 / filler 4 상태에서 a) 올바른 ifindex 로 INCLUDE{fd00::9} → fd00::9 만 수신, msfget  b) ifindex=0 으로 설정 시도 → 반환값·errno (원본 동작 그대로 기록)"
  ns_up
  tx_src9
  local port=7000 v fill name
  for fill in 0 4; do
    for v in a b; do
      name=$v; (( fill )) && name=c$v
      local f=(); (( fill )) && f=("${FILL[@]}")
      local m=(--msfilter $GS@veth1=include:fd00::9 --msfget $GS@veth1)
      [[ $v == b ]] && m=(--msfilter $GS=include:fd00::9 --msfget $GS --msfget $GS@veth1)
      echo "== $name: filler $fill, $([[ $v == a ]] && echo 'ifindex=veth1' || echo 'ifindex=0') 로 msfilter"
      rx_bg $name --port $port "${f[@]}" --join $GS@veth1 "${m[@]}" --omem --timeout 1 --sorted
      tx2 $name $port 0; rx_wait $name
      show $name; show tx1$name; show tx9$name
      need $name '^msfilter .* rc=-?[0-9]+ errno=[0-9]+$' 1 "msfilter 줄"
      need $name '^msfget .* rc=0 ' 1 "msfget (veth1) 성공 줄"
      need $name "$OMEM_RE" 3 "omem= 줄 (joined, msfilter, hold)"
      port=$((port + 1))
    done
  done
}

c34() { echo "# [pre] filler 4 → G INCLUDE{fd00::1} 가입 → JOIN_SOURCE_GROUP 로 fd00::9 추가 → 두 출발지 수신 → LEAVE_SOURCE_GROUP 로 fd00::1 제거 → fd00::9 만 수신"
  ns_up
  tx_src9
  rx_bg main --port 7000 "${FILL[@]}" --mark filled --join-src $GS@veth1=fd00::1 --join-src $GS@veth1=fd00::9 \
    --msfget $GS@veth1 --omem --count 6 --timeout 3 --sorted \
    --phase2 --leave-src $GS@veth1=fd00::1 --msfget $GS@veth1 --mark left --min-seq 200 --timeout 2 --sorted
  tx2 1 7000 0
  rx_ready2 main
  tx2 2 7000 200
  rx_wait main
  show main; show tx11; show tx91; show tx12; show tx92
  need main '^phase2$' 1 "phase2 줄"
  need main '^total=' 2 "total= 줄 (1단계, 2단계)"
  need main "$OMEM_RE" 4 "omem= 줄 (filled, joined, hold, left)"
}

c35() { echo "# 임계값 주변: 4개 가입 → 1개 탈퇴(3개 남음, 남은 그룹 수신) → 나머지 전부 탈퇴 → 다시 5개 가입 → 수신. 단계마다 omem= (vs: 3개에서 테이블 유지, 0개에서 해제)"
  ns_up
  rx_bg main --port 7000 --fill 4 $MB@veth1 --mark joined4 --unfill 1 $MB@veth1 --mark left3 --omem --timeout 1 --sorted \
    --phase2 --unfill 3 ${MB%:0}:1@veth1 --mark dropped_all --fill 5 $MB@veth1 --mark rejoined5 --min-seq 100 --count 5 --timeout 3 --sorted
  txf tx1 --port 7000 --many 4 $MB
  rx_ready2 main
  txf tx2 --port 7000 --many 5 $MB --seq-start 100
  rx_wait main; show main; show tx1; show tx2
  need main '^total=' 2 "total= 줄 (1단계, 2단계)"
  need main "$OMEM_RE" 6 "omem= 줄 (joined4, left3, joined, hold, dropped_all, rejoined5)"
}

c36() { echo "# 소켓 B(같은 포트, mcall=0, 가입 없음)의 스레드가 filler 4 가입 → 전부 탈퇴 500회(테이블 생성·해제 500회)하는 동안 G 로 3000개 송신. A(G 가입 1개)는 3000, B 는 0"
  ns_up
  local b a t
  b=$(dmesg_wb)
  rx_bg A --port 7000 --join $G@veth1 --omem --count 3000 --timeout 20
  txf tx --port 7000 --group $G --count 3000 &
  t=$!
  rx_bg B --port 7000 --mcall 0 --churn-fill 500 4 $F@veth1 --omem --timeout 10
  wait $t; rx_wait A; rx_wait B
  sleep 1   # kfree_rcu 이후 경고까지 보기 위해
  a=$(dmesg_wb)
  echo "-- A (recv 줄은 그룹별 개수로 요약)"
  grep -v '^recv' "$W/A.out"
  grep '^recv' "$W/A.out" | sed -E 's/.*group=([^ ]*).*/recv_by_group \1/' | sort | uniq -c | sed 's/^ *//'
  show B; show tx
  echo "dmesg_new_warn_bug=$((a - b))"
  echo "# dmesg WARNING|BUG before=$b after=$a"
  if (( a > b )); then sudo dmesg | grep -E 'WARNING|BUG' | tail -n $((a - b)) | sed 's/^/# dmesg| /'; fi
  rx_nstat
  need B '^churn_fill .* join_fail=0\(errno=0\) drop_fail=0\(errno=0\)$' 1 "churn_fill 실패 0"
  need B '^omem=[0-9]+ stage=churned$' 1 "omem= 줄 (churned)"
}

c37() { echo "# filler 4 + G 가입 소켓이 G 수신 중 G 탈퇴/재가입 200회 (G 로 2000개 계속 송신). 끝난 뒤(G 가입 상태) 3개 송신 → 3개 수신"
  ns_up
  local b a n
  b=$(dmesg_wb)
  rx_bg main --port 7000 "${FILL[@]}" --join $G@veth1 --churn-rejoin 200 $G@veth1 --omem --timeout 8 \
    --phase2 --mark after_churn --min-seq 5000 --count 3 --timeout 10 --sorted
  txf tx1 --port 7000 --group $G --count 2000
  rx_ready2 main
  txf tx2 --port 7000 --group $G --count 3 --seq-start 5000
  rx_wait main
  sleep 1
  a=$(dmesg_wb)
  echo "-- main (1단계 G 수신은 '# recv' 줄, 개수만 # 줄로)"
  grep -v '^# recv' "$W/main.out" | grep -v '^# stale recv'
  n=$(grep -c '^# recv' "$W/main.out")
  echo "# churn_recv_lines=$n stale_in_phase2=$(grep -c '^# stale recv' "$W/main.out")"
  (( n > 0 )) || fail "churn 중 G 수신 0"
  show tx1; show tx2
  echo "dmesg_new_warn_bug=$((a - b))"
  echo "# dmesg WARNING|BUG before=$b after=$a"
  if (( a > b )); then sudo dmesg | grep -E 'WARNING|BUG' | tail -n $((a - b)) | sed 's/^/# dmesg| /'; fi
  rx_nstat
  need main '^churn_rejoin .* drop_fail=0\(errno=0\) join_fail=0\(errno=0\)$' 1 "churn_rejoin 실패 0"
  need main '^total=3$' 1 "2단계 total=3"
  need main "$OMEM_RE" 4 "omem= 줄 (joined, hold, churned, after_churn)"
}

# ---------------------------------------------------------------- 시각 기록 / tx late 판정
# timing_report <사례 시작 epoch> : "# timing ..." 줄을 출력하고, tx late 는 fixture_err 로 남긴다.
#   rx: $W/<이름>.out 의 "# rx_start/rx_end phase=" (mc6test), sync: $W/.rx_sync, tx: $W/.tx_times (txf)
timing_report() {
  local f
  for f in "$W"/*.out; do
    [[ -e $f ]] || continue
    grep -E '^# rx_(start|end) phase=' "$f" | sed "s|^|$(basename "$f" .out) |"
  done | awk -v T0="$1" -v txf="$W/.tx_times" -v syf="$W/.rx_sync" '
    function rel(t) { return sprintf("+%.3f", t - T0) }
    function kv(s, k,   r) { r = s; if (!match(r, " " k "=[^ ]*")) return ""; r = substr(r, RSTART + length(k) + 2, RLENGTH - length(k) - 2); return r }
    { line = " " $0; id = $1 SUBSEP kv(line, "phase")
      if (!(id in seen)) { seen[id] = 1; order[++n] = id }
      if ($3 == "rx_start") st[id] = kv(line, "t") + 0
      else { en[id] = kv(line, "t") + 0; why[id] = kv(line, "reason") } }
    END {
      while ((getline l < syf) > 0) { split(l, a, " "); sy[a[1] SUBSEP (a[2] == "USR1" ? 1 : 2)] = a[3] + 0 }
      nt = 0
      while ((getline l < txf) > 0) { split(l, a, " "); nt++; tn[nt] = a[1]; ts[nt] = a[2] + 0; te[nt] = a[3] + 0; trc[nt] = a[4] }
      for (i = 1; i <= n; i++) {
        id = order[i]; split(id, k, SUBSEP)
        printf "# timing rx %s phase=%s start=%s end=%s reason=%s sync=%s\n", k[1], k[2],
          (id in st) ? rel(st[id]) : "-", (id in en) ? rel(en[id]) : "-(종료 줄 없음)", (id in why) ? why[id] : "-",
          (id in sy) ? rel(sy[id]) : "-"
      }
      for (j = 1; j <= nt; j++) printf "# timing tx %s start=%s end=%s rc=%s\n", tn[j], rel(ts[j]), rel(te[j]), trc[j]
      for (i = 1; i <= n; i++) {
        id = order[i]; split(id, k, SUBSEP)
        if (!(id in en) || why[id] == "count") continue
        for (j = 1; j <= nt; j++)
          # 신호가 있으면: 그 신호 전에 끝난 tx(= 이 단계용 송신) 가 수신 종료 뒤에 끝났는지.
          # 신호가 없으면: 수신 종료 전에 시작해 종료 뒤에 끝난 tx
          if ((id in sy) ? (te[j] <= sy[id] && te[j] > en[id]) : (ts[j] < en[id] && te[j] > en[id]))
            printf "LATE tx %s 끝 %s 가 rx %s phase=%s 끝 %s(reason=%s) 뒤\n", tn[j], rel(te[j]), k[1], k[2], rel(en[id]), why[id]
      }
    }' >"$W/.timing"
  grep '^# timing ' "$W/.timing"
  grep '^LATE ' "$W/.timing" | sed 's/^LATE /tx late: /' | while IFS= read -r l; do fixture_err "$l"; done
}

# ---------------------------------------------------------------- 실행
dm_before=$(dmesg_wb)
{
  echo "tag=$TAG"
  echo "uname -r: $(uname -r)"
  echo "linux commit: $(git -C ~/linux rev-parse HEAD 2>&1) ($(git -C ~/linux describe --always --tags 2>&1))"
  echo "linux branch: $(git -C ~/linux rev-parse --abbrev-ref HEAD 2>&1)"
  echo "optmem_max(start): $(sysctl -n net.core.optmem_max)"
  echo "date: $(date -Is)"
  echo "mc6test sha256: $(sha256sum "$MC" | cut -d' ' -f1)  (실행 사본: $MC)"
  echo "run-fixture.sh sha256: $(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
  echo "cases: ${CASES[*]}"
  echo "dmesg WARNING|BUG before: $dm_before"
} >"$D/_env.txt"

FAILED=(); FIXERR=()
for nn in "${CASES[@]}"; do
  declare -F "c$nn" >/dev/null || { echo "사례 $nn 없음" >&2; FAILED+=("$nn(없음)"); continue; }
  W="$D/.work/$nn"; rm -rf "$W"; mkdir -p "$W"
  VIDX=__none__; DIDX=__none__
  CASE_FAIL=0
  t0=$(date +%s.%N)
  "c$nn" >"$W/raw.txt" 2>&1
  t1=$(date +%s.%N)
  timing_report "$t0" >"$W/timing.txt"
  { norm <"$W/raw.txt"
    cat "$W/timing.txt"
    [[ -s "$W/.fixture_errors" ]] && sed 's/^/FIXTURE ERROR /' "$W/.fixture_errors"
    echo "# elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')s date=$(date -Is)"; } >"$D/$nn.txt"
  if [[ -s "$W/.fixture_errors" ]]; then
    FIXERR+=("$nn")
    printf '%s  FIXTURE ERROR  %s\n' "$nn" "$(grep -m1 '^FIXTURE ERROR ' "$D/$nn.txt" | sed 's/^FIXTURE ERROR //')"
  elif (( CASE_FAIL )); then
    FAILED+=("$nn")
    printf '%s  FAIL  %s\n' "$nn" "$(grep -m1 '^FAIL ' "$D/$nn.txt")"
  else
    printf '%s  %s\n' "$nn" "$(head -1 "$D/$nn.txt" | sed 's/^# //')"
  fi
done

cleanup
dm_after=$(dmesg_wb)
{
  echo "optmem_max(end): $(sysctl -n net.core.optmem_max)"
  echo "dmesg WARNING|BUG after: $dm_after"
  echo "date(end): $(date -Is)"
  echo "failed: ${FAILED[*]:-none}"
  echo "fixture_error: ${FIXERR[*]:-none}"
} >>"$D/_env.txt"
echo "완료: $D  (dmesg WARNING|BUG $dm_before → $dm_after)"
(( ${#FAILED[@]} )) && echo "실패 사례: ${FAILED[*]}" >&2
if (( ${#FIXERR[@]} )); then
  echo "FIXTURE ERROR 사례 (환경 문제, 결과를 커널 비교에 쓰지 말 것): ${FIXERR[*]}" >&2
  exit 2
fi
(( ${#FAILED[@]} )) && exit 1
exit 0
