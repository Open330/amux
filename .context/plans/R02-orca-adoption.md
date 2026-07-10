# R02 · orca 채택 로드맵 — 남은 항목 설계 노트

> stablyai/orca 4축 심층 분석(2026-07-10) 후속. R01의 로드맵을 보강한다.
> 이미 채택 완료: pane_read/pane_wait/pane_send + SKILL 플레이북, finished 알람 1.5s 디바운스,
> working 배지 30분 신선도 감쇠, 에이전트 카탈로그 + amux.agents/amux.launch_agent.

## 1. 인터-에이전트 메시지 버스 (orca orchestration의 amux 버전) — 다음 라운드 권장

현 상태로도 오케스트레이션 루프는 성립한다: `launch_agent`로 N개 세션에 fan-out →
`pane_wait for=idle` 배리어 → `pane_read` 수확. 버스가 추가로 주는 것은 (a) 코디네이터가
pane을 폴링하지 않아도 되는 typed 메시지 수신함, (b) 태스크 DAG 상태, (c) 에스컬레이션/게이트.

최소 구현(권장 스코프, ~1일):
- `amux.msg_send {to: workspace_id|"@all"|"@idle", type, payload}` — 워크스페이스별 수신함에 append.
  타입은 orca를 따라 `status|worker_done|escalation|decision_gate|handoff`로 시작.
- `amux.msg_check {for?, wait_ms, types?}` — long-poll (v2VmCall, pane_wait와 같은 레인/모양).
- 저장: 메모리 + `~/.local/state/amux/orchestration.ndjson` append(재시작 생존).
- 그룹 주소 해석은 muxa 상태로 (`@idle` = state idle인 agent가 있는 워크스페이스).
- SKILL.md에 코디네이터 규약 추가: dispatch preamble("보고는 amux rpc amux.msg_send로"),
  supervised vs handoff 구분(orca가 lifecycle 고아 방지를 위해 강하게 구분).

orca에서 그대로 가져올 가드: dispatch 시 git drift preflight(베이스가 20+ 커밋 뒤면 거부),
heartbeat staleness 경고, dispatch 실패 카운트 서킷 브레이커.

## 2. 사용량/rate-limit 추적 + 계정 핫스왑 — 별도 라운드 필요 (외부 API·자격증명)

orca 참조 구현: `src/main/rate-limits/*` + `claude-accounts/*`.
- Claude: `https://api.anthropic.com/api/oauth/usage` (OAuth bearer, beta 헤더), 자격증명은
  Keychain → managed-auth 파일 → config 순으로 읽고 만료 시 refresh. 직접 fetch가 막히면
  PTY로 claude CLI를 띄워 읽는 폴백.
- 핵심 안전장치(그대로 필요): **live-PTY gate** — 실행 중인 claude 세션이 있는 동안
  단일 사용 refresh 토큰을 회전시키지 않는 뮤텍스. 계정 전환 실패 시 롤백.
- amux 적용: 사이드바 세션 카드에 사용량/리셋 배지(muxa가 이미 `context_used_pct`,
  `cost_usd`를 나름) → 1차로는 muxa 필드 표면화가 공짜 승리, OAuth 사용량 API는 2차.

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
- quick-open에 세션/에이전트 엔티티 검색(orca WorktreeJumpPalette의 amux 버전).
