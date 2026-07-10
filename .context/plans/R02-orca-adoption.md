# R02 · orca 채택 로드맵 — 남은 항목 설계 노트

> stablyai/orca 4축 심층 분석(2026-07-10) 후속. R01의 로드맵을 보강한다.
> 이미 채택 완료: pane_read/pane_wait/pane_send + SKILL 플레이북, finished 알람 1.5s 디바운스,
> working 배지 30분 신선도 감쇠, 호스트별 에이전트 카탈로그 + amux.agents/amux.launch_agent,
> muxa 전체 상태/컨텍스트/비용을 노출하는 amux.agent_status, 통합 tmux 세션 quick-open,
> 재시작에 안전한 typed orchestration 메시지/태스크/게이트/heartbeat.

## 1. 인터-에이전트 메시지 버스 (orca orchestration의 amux 버전) — 채택 완료

구현된 RPC:
- `amux.msg_send` / `amux.msg_check`: direct/group 주소, sequence cursor, 이벤트 기반 long-poll.
- `amux.task_create` / `amux.task_list` / `amux.task_update`: dependency DAG와 실행 가능 상태.
- `amux.gate_create` / `amux.gate_list` / `amux.gate_resolve`: 승인 전 실행/완료 차단.
- `amux.heartbeat`: 작업별 생존 상태와 stale 경고.

메시지 타입은 `status|dispatch|worker_done|merge_ready|escalation|handoff|decision_gate|heartbeat`.
상태는 `~/.local/state/amux/orchestration.ndjson`에 append되고 재시작 시 복원되며, 디렉터리와
파일 권한은 각각 0700/0600으로 강제한다. 태스크 생성 시 보고된 base distance가 20 commits를
넘으면 거부한다. `skills/amux-agent-driving/SKILL.md`에 supervised/handoff 운용 규약과 예제를
기록했다.

남은 선택 항목: muxa 상태 기반 동적 그룹(`@idle`)과 반복 dispatch 실패 circuit breaker.
현재 direct/group 메시지와 task 상태 전이가 명시적이어서 핵심 오케스트레이션에는 필요하지 않다.

## 2. 사용량/rate-limit 추적 + 계정 핫스왑 — 별도 라운드 필요 (외부 API·자격증명)

orca 참조 구현: `src/main/rate-limits/*` + `claude-accounts/*`.
- Claude: `https://api.anthropic.com/api/oauth/usage` (OAuth bearer, beta 헤더), 자격증명은
  Keychain → managed-auth 파일 → config 순으로 읽고 만료 시 refresh. 직접 fetch가 막히면
  PTY로 claude CLI를 띄워 읽는 폴백.
- 핵심 안전장치(그대로 필요): **live-PTY gate** — 실행 중인 claude 세션이 있는 동안
  단일 사용 refresh 토큰을 회전시키지 않는 뮤텍스. 계정 전환 실패 시 롤백.
- amux 적용: 사이드바 세션 카드에 사용량/리셋 배지(muxa가 이미 `context_used_pct`,
  `cost_usd`를 나름) → `amux.agent_status`와 에이전트 상세 모달로 1차 필드 표면화 완료.
  사이드바 시각화와 OAuth 사용량 API는 2차.

## 3. 모바일/원격 관측 — 설계 원칙만 기록

orca: 폰→데스크톱 직결 WS + nacl.box E2EE + 기기별 토큰(0600 파일) + Tailscale로 오프-LAN.
푸시 인프라 없음 → 데스크톱이 잠들면 알림 두절이 최대 UX 구멍.
amux가 하게 되면: tmux 서버는 앱과 독립적으로 살아있으므로 muxad에 얇은 알림 릴레이를 붙이는
편이 orca보다 유리(데스크톱 앱이 꺼져도 daemon이 알림 가능). QR 페어링 페이로드/E2EE 형식은
orca 것을 차용하되 공개키 지문 대역외 검증을 추가.

## 4. 미채택 소품 (기회 있을 때)

- OSC 9999 인라인 상태 폴백(`\x1b]9999;<json>\x07`) — tmux를 투명 통과하므로 muxa 훅이
  못 붙는 환경의 대안 트랜스포트. muxa 쪽 스펙과 합의 필요.
- draft prefill 런치(`claude --prefill` 등) — launch_agent에 `draft: true` 파라미터로.
- Codex managed CODEX_HOME + hooks 신뢰 해시(Codex 0.129+가 미신뢰 훅을 조용히 버림) —
  muxa 훅 설치 경로에서 처리해야 함.
- quick-open에 세션/에이전트 엔티티 검색(orca WorktreeJumpPalette의 amux 버전) — 채택 완료.
