#!/usr/bin/env bash
# 테스트 환경: tx/rx namespace, veth0(tx)<->veth1(rx), rx 에 dummy0 (두 번째 인터페이스)
# 사용법: guest/60-netns-fixture.sh up | down | status
set -euo pipefail
CMD="${1:-up}"
OPTMEM="${OPTMEM_MAX:-262144}"

case "$CMD" in
up)
  ip netns list | grep -q '^tx' && { echo "이미 up. down 후 다시."; exit 0; }
  sudo modprobe veth dummy
  sudo ip netns add tx; sudo ip netns add rx
  sudo ip link add veth0 type veth peer name veth1
  sudo ip link set veth0 netns tx; sudo ip link set veth1 netns rx
  sudo ip -n rx link add dummy0 type dummy
  for ns in tx rx; do sudo ip -n $ns link set lo up; done
  sudo ip -n tx link set veth0 up
  sudo ip -n rx link set veth1 up
  sudo ip -n rx link set dummy0 up
  sudo ip -n tx addr add fd00::1/64 dev veth0
  sudo ip -n rx addr add fd00::2/64 dev veth1
  sudo ip -n rx addr add fd00:1::2/64 dev dummy0
  sudo ip netns exec rx sysctl -qw net.ipv6.conf.all.forwarding=0
  # 5.4 의 optmem_max 는 전역(init_net) 값. 모든 비교 이미지에서 같은 값으로.
  sudo sysctl -qw net.core.optmem_max="$OPTMEM"
  # DAD 끝날 때까지
  for i in $(seq 1 20); do
    sudo ip -n rx -6 addr show dev veth1 | grep -q tentative || break; sleep 0.5
  done
  echo "up 완료. optmem_max=$(sysctl -n net.core.optmem_max)"
  sudo ip netns exec rx ip -6 maddr show dev veth1 | sed 's/^/  rx veth1 기본 그룹: /'
  ;;
down)
  sudo ip netns del tx 2>/dev/null || true
  sudo ip netns del rx 2>/dev/null || true
  echo "down"
  ;;
status)
  ip netns list
  echo "--- rx 인터페이스"; sudo ip -n rx -6 addr
  echo "--- rx 가입 그룹"; sudo ip -n rx -6 maddr
  echo "--- optmem_max: $(sysctl -n net.core.optmem_max)"
  echo "--- 커널: $(uname -r)"
  ;;
*) echo "up|down|status" >&2; exit 1 ;;
esac
