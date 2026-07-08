# tmux + muxa + cmux: Agent-driven 멀티 세션 터미널 기획서

> R01 · 작성: Fable 5 (메인 세션, 코드베이스 직접 검증 기반)
> 근거 코드는 전부 이 세션에서 직접 확인한 파일/라인이며, 서브에이전트 출력에 의존하지 않음.

---

## 1. 비전과 포지셔닝

**한 문장**: "tmux 세션이 곧 워크스페이스이고, 에이전트 상태가 1급 시민인 macOS 네이티브 터미널."

cmux의 검증된 강점은 멀티 세션 UX(사이드바 워크스페이스, surface split, 소켓 CLI, 에이전트 알림)다. 그러나 세션의 *지속성*은 앱 프로세스에 묶여 있다. tmux를 진실 원천으로 삼으면:

- 앱을 꺼도/죽어도 세션·스크롤백·실행 중인 에이전트가 살아있다.
- 같은 세션을 CLI(`tmux attach`), SSH, 다른 기기에서 이어갈 수 있다.
- muxa가 이미 tmux pane 단위로 에이전트 상태를 추적하므로, "어느 워크스페이스의 어느 pane에서 어떤 에이전트가 입력을 기다리는가"가 공짜로 나온다.

### 역할 분담

| 레이어 | 역할 | 진실 원천인 것 |
|---|---|---|
| **tmux** | 세션/윈도우/pane 컨테이너, persistence, detach/attach | 세션 존재, pane 토폴로지, 터미널 출력 |
| **muxa (muxad)** | agent↔pane 상관, 상태 머신, 활동 원장 | 에이전트 상태(working/waiting_input/waiting_choice/…), 프롬프트 히스토리, stats |
| **cmux fork** | 네이티브 렌더링·UX 셸 | 포커스, 시각적 배치, 알림 정책, 사용자 입력 |

### 경쟁 제품 대비

- **iTerm2 `-CC`**: control mode 통합은 있으나 에이전트 개념이 없고 UI가 구세대.
- **Warp**: 에이전트 통합은 강하나 자사 클라우드/자사 에이전트 중심, tmux 지속성 없음.
- **WezTerm/Zellij**: 자체 멀티플렉서라 기존 tmux 생태계·muxa와 단절.
- **기존 cmux**: 세션이 앱 수명에 묶임, 에이전트 상태는 알림 수준.
- **본 제품**: 기존 tmux 워크플로를 그대로 흡수(attach만 하면 됨) + 에이전트 관측이 UI 기본 문법.

---

## 2. 검증된 기술적 기반 (fork가 물려받는 자산)

### 2.1 cmux에는 이미 tmux -CC 미러 스택이 있다

`RemoteTmux*` 계열(약 40파일)이 SSH 원격 tmux를 control mode로 미러링한다:

- `RemoteTmuxController.swift` — `@MainActor` 코디네이터. host+session 키로 `RemoteTmuxControlConnection`을 캐시/재사용 (`connectionsByHostSession`).
- `RemoteTmuxControlConnection.swift` — `Process`로 control 클라이언트를 spawn, stdout을 `RemoteTmuxControlStreamParser`로 파싱. **현재 `/usr/bin/ssh` 하드코딩** (`spawnProcess`, L332).
- `RemoteTmuxHost.controlModeArguments` (L331~) — 이미 `-CC new-session -A -s <name>`(attach-or-create) / `-CC attach-session -t <name>` 인자를 생성.
- `RemoteTmuxSessionMirror` / `RemoteTmuxWindowMirror` / `RemoteTmuxLayoutNode` / `RemoteTmuxWindowRegistry` — `%output` 등 control 알림을 cmux surface 트리로 투영.
- 베타 플래그: `betaFeatures.remoteTmux` (`RemoteTmuxController.isEnabled`).

**결론: "tmux 강결합"의 최대 난제(control mode 파서 + 미러링 + surface 공급)가 이미 풀려 있다.** 핵심 작업은 transport를 SSH 전용에서 프로토콜로 추상화해 **LocalTmuxTransport**(직접 `tmux -CC …` spawn)를 추가하고, 이 미러를 "원격 부가기능"에서 "워크스페이스의 기본 존재 방식"으로 승격하는 것이다.

### 2.2 muxa는 구독형 상태 스트림을 이미 제공한다

`/Users/jiun/personal/muxa` (Rust, muxad 데몬 + CLI). 체크아웃의 PROTOCOL.md는 v2 기준이지만 **설치된 muxad는 protocol v3**(hello 응답 min=1/max=3, 라이브 확인 2026-07-07)이며 `last_response`, `rate_limit_*` 등 문서에 없는 추가 필드를 보낸다 — 클라이언트는 hello로 v2를 pin하고 unknown 필드/variant에 관대해야 한다(검증 완료: v2 pin으로 v3 데몬과 정상 통신).

- **Transport**: 유닉스 소켓(`$XDG_RUNTIME_DIR/muxa.sock` 또는 `/tmp/muxa-<uid>.sock`), line-delimited JSON, full-duplex.
- **메서드**: `hello`(capability 협상: `waiting_choice`, `needs_choice`, `rate_limited`), `snapshot`, `by_pane`, `by_session`, `recent_prompts`, `ingest`, `health`, 그리고 **`subscribe`** — 장수명 Transition 스트림 (`crates/muxa/src/ipc.rs` L104~, `TransitionStream` L824~; lag 시 클라이언트가 poll로 reconcile하는 설계까지 내장, L523).
- **Agent 스키마**: `kind`(claude_code/codex/gemini_cli/…), `session_id`, `pane`(%N), `tmux_session`, `cwd`, `state`(working/idle/waiting_input/waiting_choice/error/stopped/starting), `last_prompt`, `model`, `context_used_pct`, `cost_usd`, 타임스탬프.
- **활동 원장**: `activity.ndjson` state_transition + session_foreground 인터벌 → stats/timeline의 원천.

**결론: cmux fork는 muxad의 `hello`→`snapshot`→`subscribe` 시퀀스만 구현하면 pane 단위 에이전트 상태를 실시간으로 받는다.** `pane`(%N)과 `tmux_session`이 이벤트에 이미 붙어 있으므로, control mode 미러가 아는 pane ID와 조인하면 UI 배지 매핑이 O(1)이다.

---

## 3. 핵심 설계 결정

### D1. tmux 연동 = 로컬 control mode(-CC) + muxad 이벤트의 하이브리드

| 후보 | 평가 |
|---|---|
| (a) Ghostty pane 안에 일반 `tmux attach` | 구현 최소지만 tmux status line/copy-mode가 이중 UI로 남고, cmux가 pane 토폴로지를 모름 → "1:1 대응 UX" 불가 |
| (b) control mode(-CC) 미러 | tmux window/pane을 네이티브 surface로 투영. 기존 RemoteTmux 스택 재사용. 스크롤백·대량출력 리스크는 있으나 이미 SSH에서 운용 중 |
| (c) muxad 폴링/이벤트만 | 에이전트 상태는 얻지만 터미널 자체는 여전히 (a) 문제 |

**결정: (b)가 토폴로지·출력의 진실 원천, muxad `subscribe`가 에이전트 상태 레이어.** (a)는 "호환 모드"(비-cmux tmux 세션을 그냥 attach해서 보기)로 남겨둔다.

### D2. workspace ↔ tmux session 1:1 바인딩

- **생성**: 새 워크스페이스 = `tmux -CC new-session -A -s <slug>` (인자 생성 로직 기존 재사용). 워크스페이스 이름 변경 ↔ `rename-session` 양방향 동기화(`%session-renamed` 알림 수신).
- **닫기 = detach가 기본**, kill은 명시적 액션("Close and Kill Session"). tmux 철학과 일치.
- **복원**: 앱 재시작 시 `tmux list-sessions`로 발견 → 저장된 워크스페이스 스냅샷(`SessionPersistence.swift` 확장)과 세션 이름으로 reconcile → 자동 re-attach. cmux가 모르는 세션은 사이드바 "Detached" 섹션에 노출(고아 세션의 1급 취급 — 이것이 tmux 유저 온보딩의 핵심).
- **비-tmux 워크스페이스**: 과도기에는 기존 cmux 로컬 워크스페이스도 허용(설정으로 "항상 tmux" 전환). 최종적으로는 tmux-backed가 기본.

### D3. surface ↔ tmux window/pane: tmux가 소유, cmux는 투영

양방향 레이아웃 동기화(cmux split 트리 ↔ tmux layout)는 충돌 지옥이다(동시 resize, 외부 CLI의 `split-window`).

**결정: tmux layout이 단일 소유자.** cmux의 split/resize/close 제스처는 전부 tmux 명령(`split-window`, `resize-pane`, `kill-pane`)으로 번역해 발행하고, UI는 `%layout-change` 알림을 받아 다시 그린다(기존 `RemoteTmuxLayoutNode` 경로). 외부에서 `tmux split-window`를 쳐도 UI가 따라온다 — 이 속성이 "CLI와 GUI가 같은 세션을 본다"는 제품 약속의 근간.

- cmux 고유 개념(브라우저 패널, 마크다운 뷰어 등 비터미널 surface)은 tmux 밖의 **사이드카 surface**로 워크스페이스에 병치(레이아웃 메타데이터는 cmux가 저장).

### D4. muxa 통합: Swift `MuxaClient` + 상태 프로젝션

- 신규 패키지 `Packages/macOS/CmuxMuxa`: 유닉스 소켓 line-JSON 클라이언트. `hello`(v2 pin, capability 확인) → `snapshot` → `subscribe`. 연결 유실/lag 시 snapshot 재수행(프로토콜이 이 패턴을 전제함).
- 상태 조인: muxad `pane`(%N) ↔ control mode 미러의 pane ID → surface 배지. `tmux_session` ↔ 워크스페이스 배지(집계: 세션 내 최악 상태 우선 — blocked > waiting > working > idle).
- muxad 미설치/미실행 시 완전 우아한 강등: 터미널 기능은 전부 동작, 배지만 없음. 설정에서 "Install muxa" 온보딩 제공.
- **프롬프트 전송/attend**: muxad에는 쓰기 경로가 없으므로(관측 전용) 에이전트 입력은 **tmux `send-keys -t %N`** 로 직접 발행. attend = muxa의 "가장 오래 blocked" 정렬 로직을 클라이언트에서 재현(snapshot의 `last_activity_at` + state 기준)해 해당 워크스페이스/surface로 포커스 점프.

### D5. 기존 cmux 자산의 처분

- **재사용**: RemoteTmux 미러 스택(transport 추상화 후), 사이드바/워크스페이스 UI, 소켓 CLI(v2 dispatcher), 알림 파이프라인, Ghostty 렌더링.
- **수정**: `SessionPersistence`(tmux 세션 이름 기반 복원), 워크스페이스 생성 경로(tmux-backed 기본), 사이드바 모델(세션 상태 배지 — 단, CLAUDE.md의 스냅샷 경계 규칙 준수: 행에는 값 스냅샷만).
- **fork 전략**: upstream cmux를 주기적으로 머지하는 soft fork 권장. 신규 코드는 가능한 한 새 패키지(`CmuxTmuxLocal`, `CmuxMuxa`)와 얇은 접점으로 격리해 머지 충돌 면적 최소화.

---

## 4. UX 설계

### 4.1 정보 구조

```
┌─ Sidebar ────────────┐┌─ Workspace: api-refactor ($api-refactor) ─────────┐
│ SESSIONS             ││ ┌─ %3 claude ● working ──┬─ %4 codex ◐ waiting ─┐ │
│ ● api-refactor  2🤖  ││ │  ...ghostty surface... │  1) apply patch      │ │
│ ◐ bugfix-7503   1🤖⚠ ││ │                        │  2) skip             │ │
│ ○ notes              ││ │                        │  ❯ _                 │ │
│ DETACHED (tmux)      ││ ├────────────────────────┴──────────────────────┤ │
│ ⚪ scratch            ││ │ %5 zsh                                        │ │
│ ⚪ remote: gpu-box    ││ └───────────────────────────────────────────────┘ │
└──────────────────────┘└───────────────────────────────────────────────────┘
```

- 사이드바 = tmux 세션 목록(attached 워크스페이스 + Detached 섹션 + 원격 호스트). 세션별 에이전트 수·최악 상태 배지.
- surface 탭/헤더에 에이전트 배지: 상태 + `model` + `context_used_pct`(muxa heartbeat에서 공짜로 옴).
- 상태 시각 언어: working=차분한 진행 표시(애니메이션 최소 — 타이핑 지연 민감 경로 준수), waiting_input/waiting_choice=주황 계열 + 사이드바 상단 정렬, error=적색, idle=무채색.

### 4.2 핵심 플로우

1. **새 작업 시작**: ⌘N → 세션 이름 입력 → tmux 세션 생성 + attach → 첫 pane에서 에이전트 실행 → muxa hook이 자동 감지, 배지 등장.
2. **Attend 점프** (킬러 기능): 전역 단축키 → 가장 오래 입력 대기 중인 에이전트의 워크스페이스+surface로 즉시 포커스. waiting_choice면 선택지 UI를 네이티브 시트로 승격하는 것도 후속 후보.
3. **끄고 퇴근**: 앱 종료 = 전 세션 detach. 노트북/SSH에서 `tmux attach -t api-refactor`로 계속. 다음날 앱 실행 시 전부 재부착 + 밤새 상태 변화가 배지로.
4. **Attach 없이 프롬프트**: 사이드바 세션 카드에서 프롬프트 composer 열기 → `send-keys`로 주입(muxa watch의 composer UX를 네이티브로).
5. **회고**: muxa `stats`/`timeline` 데이터를 워크스페이스별 패널로 렌더(작업/대기/사람 개입 시간).

### 4.3 알림 정책

muxa 데스크톱 알림과 cmux 알림의 **이중 발화 방지**가 필수: cmux가 실행 중이고 muxad에 연결돼 있으면 cmux가 알림 소유(muxa notify는 설정에서 끄도록 온보딩), cmux 미실행 시 muxa가 폴백. `needs_input`/`needs_choice`/`error`만 데스크톱 알림, 나머지는 배지.

---

## 5. 로드맵

### Phase 0 — 타당성 게이트 (1~2주)
`LocalTmuxTransport` 스파이크: `RemoteTmuxControlConnection`의 ssh spawn을 분기해 로컬 `tmux -CC new-session -A`를 물리고 기존 미러로 렌더.
**게이트 기준**: (1) `yes`/`find /` 급 대량 출력에서 타이핑 지연 없음, (2) 스크롤백 UX 결정(control mode에서 히스토리는 tmux 소유 — `capture-pane` 페이징 vs Ghostty 스크롤백 이중화 중 택1), (3) TUI 앱(vim, claude code) 정상, (4) OSC(하이퍼링크, 클립보드) 패스스루 확인. **여기서 막히면 D1을 (a) 호환 모드 우선으로 피벗.**

### Phase 1 — tmux-backed 워크스페이스 (3~4주)
워크스페이스 생성=tmux 세션, 닫기=detach, 재시작 복원 reconcile, Detached 섹션, split/resize→tmux 명령 번역, 이름 양방향 동기화. 기존 소켓 CLI에 세션 타깃팅 추가.

### Phase 2 — muxa 통합 (2~3주)
`CmuxMuxa` 패키지(hello/snapshot/subscribe), 사이드바·surface 배지, attend 단축키, 알림 중복 제거, muxa 미설치 온보딩.

### Phase 3 — 차별화 UX
프롬프트 composer(send-keys), waiting_choice 네이티브 시트, stats/timeline 패널, 원격 호스트(기존 RemoteTmux 경로와 muxa 원격 스토리 통합).

---

## 6. 리스크

| 리스크 | 심각도 | 완화 |
|---|---|---|
| control mode 스크롤백/대량출력/렌더 성능 | **최고** | Phase 0 게이트로 선검증, 실패 시 호환 모드 피벗. 기존 SSH 미러 운용 경험이 완화 근거 |
| tmux layout↔cmux 제스처 번역의 엣지(중첩 split, zoom) | 중 | tmux 단일 소유 원칙 고수, `%layout-change` 재투영만 신뢰 |
| muxa 프로토콜 pre-1.0 변동 | 중 | `hello` capability 협상 사용, muxa 버전 pin + 같은 조직이 양쪽을 소유하므로 co-evolve 가능 |
| 이중 알림/이중 status UI | 저 | 온보딩에서 tmux status-line/muxa notify off 프리셋 제공 |
| upstream cmux 머지 비용 | 중 | 신규 패키지 격리 + 접점 최소화, 주기적 sync 브랜치 |

---

## 7. 열린 질문 (다음 라운드에서 결정)

1. 제품명/브랜딩, 그리고 upstream cmux와의 관계(공개 fork인가, private인가).
2. 스크롤백 전략 최종안 — Phase 0 실측 후 결정.
3. muxa에 cmux 전용 sink(또는 subscribe 확장)를 추가할지, 클라이언트 조인으로 충분한지.
4. zellij 등 tmux 외 백엔드는 muxa 로드맵과 맞춰 갈지(초기엔 tmux only 권장).
5. 기존 cmux의 Cloud VM/웹 스택을 fork에서 유지할지 제거할지.
