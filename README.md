# IPv6 소켓 멀티캐스트(S) 정확성 fixture

Linux 5.4.214 의 소켓별 멀티캐스트 가입 검색(inet6_mc_check 등)이 패치 전후로 같은 판정을 내는지 확인하는 도구입니다.

- `tools/mc6test.c` : 가입·탈퇴·source filter·MSFILTER·ADDRFORM·TCP accept·송수신 도구 (`make`)
- `tools/run-fixture.sh` : 송신/수신 namespace 를 만들고 사례 01~37 을 실행
- `logs/v0|vl|vs` : 원본(V0), 공통 필드만(VL), 소켓 해시 켬(VS) 커널의 결과

## 실행
    cd tools && make
    ./run-fixture.sh <태그>                 # 01~37 전부 (sudo 필요)
    ./run-fixture.sh <태그> 05 26           # 일부만
    ./run-fixture.sh --diff --behavior v0 <태그>   # 메모리 값 제외, 판정만 비교
    ./run-fixture.sh --omem vl <태그>              # 옵션 메모리(sk_omem_alloc) 값 비교

## 해석
- `--behavior` 비교가 전부 "같음"이면 수신·필터·순서·정리 동작이 원본과 같습니다.
- `omem=` 은 getsockopt(SO_MEMINFO) 로 읽은 소켓 옵션 메모리입니다. 항목 크기는 V0 64B, VL/VS 88B,
  VS 는 가입 4개째부터 테이블 2064B 가 더해지고 0개가 되면 사라집니다.
- 20번(할당 실패 주입)은 CONFIG_FAILSLAB 이 켜진 디버그 커널에서만 실제로 돕니다.
- 인터페이스가 가입하지 않은 그룹의 패킷은 소켓 검사까지 오지 않습니다. 그래서 소켓 차단 사례는
  다른 소켓(helper)이 그 그룹에 가입한 상태에서 수행합니다.
- `FIXTURE ERROR` 는 시험 환경 문제이며 커널 동작 비교에 쓰지 않습니다.
