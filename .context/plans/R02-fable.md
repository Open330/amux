# R02: amux — 통합 제품화·배포 기획 (cmux fork + tmux + muxa 단일 패키지)

> R01(`R01-fable.md`)의 아키텍처 결정을 전제로, "별도 제품으로서의 amux"와 통합 배포 전략을 다룬다.
> 작성: Fable 5 (메인 세션). 라이선스·이름 충돌·tmux 제약은 이 세션에서 직접 확인.

---

## 0. 결론 요약

**통합 배포는 옳은 방향이다.** 이 제품의 가치는 "tmux + muxa + 네이티브 UI가 설정 없이 함께 동작"하는 데서 나오는데, 셋을 따로 설치시키면 온보딩에서 죽는다(현재 muxa만 해도 daemon + hook wiring이 필요). 단, 착수 전에 반드시 정리할 제약이 둘 있다:

1. **라이선스**: cmux는 GPL-3.0-or-later (또는 Manaflow 상업 라이선스). fork인 amux 앱은 GPL로 소스 공개하거나, Manaflow와 상업 라이선스를 협상해야 한다.
2. **이름**: "amux"는 *정확히 같은 컨셉*(agent multiplexer)으로 GitHub에 최소 6개 프로젝트가 이미 존재한다. 사용 가능하지만 검색성/상표 관점의 의사결정이 필요하다.

---

## 1. 라이선스 매트릭스

| 구성요소 | 라이선스 | amux에서의 처리 |
|---|---|---|
| cmux (fork 모체) | **GPL-3.0-or-later** + 상업 듀얼 (`LICENSE`, Manaflow, Inc.) | amux 앱 = 파생물 → **GPL-3.0-or-later로 공개** 또는 founders@manaflow.com 상업 라이선스. 저작권 고지 유지 의무 |
| Ghostty (GhosttyKit) | MIT | 문제 없음 |
| tmux | ISC (BSD 계열) | 바이너리 동봉 가능, 고지만 유지 |
| muxa (자사) | MIT OR Apache-2.0 | **별도 프로세스 + 소켓 IPC = "mere aggregation"** → muxa는 permissive 라이선스 유지 가능. muxa를 GPL로 바꿀 필요 없음 |

**권고**: amux 앱 저장소는 GPL-3.0-or-later 공개 fork로 시작(오픈소스 제품). muxa는 지금처럼 MIT/Apache 별도 repo 유지 — 이렇게 하면 muxa 단독 사용자(비-amux tmux 유저) 생태계도 계속 산다. 나중에 클로즈드/상업화가 필요해지면 그때 Manaflow와 협상. **이 결정은 fork 첫 커밋 전에 확정할 것.**

## 2. 이름 "amux" 충돌 현황 (2026-07 검색 기준)

같은 이름·같은 컨셉의 기존 프로젝트: prettysmartdev/amux(멀티 에이전트 컨테이너 오케스트레이션), weill-labs/amux(인간+에이전트 공유 TUI), jordanwebster/amux(원격 에이전트 세션 접속), mixpeek/amux(tmux 기반 Claude Code 병렬 실행), hewigovens/amux(tmux 에이전트 세션 CLI), andyrewlee/amux(워크스페이스 기반 병렬 에이전트 TUI).

- 시사점: ①"agent mux"라는 발상 자체가 검증된 수요라는 방증(긍정), ②`brew install amux`·`github.com/open330/amux` 검색성 경쟁 발생, ③CLI 바이너리 이름 충돌 가능(기존 amux 사용자 머신).
- 대응 옵션: (a) 그대로 진행 — 전부 소규모 CLI/TUI이고 네이티브 macOS 앱은 없음, "제품급 완성도"로 이기는 전략. (b) 표기 차별화(Amux, amux.dev 도메인 선점). (c) 대안 이름 검토.
- **권고**: (a)+(b). 단, 도메인·상표·crates.io/Homebrew 네임 선점 여부를 착수 주에 확인하고, 막히면 조기에 (c)로 피벗.

---

## 3. 통합 배포 아키텍처

### 3.1 앱 번들 구성

```
amux.app/Contents/
├── MacOS/amux                    # SwiftUI 셸 (cmux fork, GPL)
├── Frameworks/GhosttyKit.xcframework
└── Resources/bin/
    ├── tmux                      # 핀 버전 (예: 3.5a, universal, ISC 고지 동봉)
    ├── muxad                     # muxa 데몬 (Rust, 자사)
    ├── muxa                      # muxa CLI
    └── amux-cli                  # 단일 진입 CLI (기존 cmux CLI 계승)
```

- 배포물: `amux-macos.dmg` + Sparkle 자동 업데이트(cmux 릴리스 파이프라인 계승: 서명/공증/`releases/latest` 패턴 재사용).
- Homebrew cask 병행. muxa 단독 배포(cargo/brew)는 기존대로 유지 — amux는 muxa의 수퍼셋 배포 채널.

### 3.2 tmux 번들링 전략 (통합 제품의 최대 기술 결정)

**제약**: tmux는 client와 server 버전이 다르면 attach가 거부되거나 기능이 깨진다. 사용자가 이미 homebrew tmux 서버를 돌리고 있으면 번들 tmux client로 그 세션에 붙을 수 없다.

**결정: 이중 모드.**

1. **amux 엔진 모드(기본)**: 번들 tmux를 **전용 소켓**(`tmux -L amux`)으로 구동. amux가 만드는 모든 워크스페이스 세션은 이 서버 소속. 장점: -CC 파서가 상대할 tmux 버전이 단일(호환성 매트릭스 소멸), 사용자 tmux 설정(`~/.tmux.conf`)의 status-line/키바인딩 간섭 없음(전용 `amux.conf` 주입), 시스템 tmux와 완전 무충돌.
2. **어댑션 모드(기존 tmux 유저 흡수)**: 시스템 tmux 서버 감지 시 사이드바 "System tmux" 섹션에 세션 노출, attach 시 **시스템 tmux 바이너리를 client로 exec**(버전 일치 보장). 버전이 -CC 지원 범위(≥3.2 권장) 밖이면 읽기 전용/호환 attach로 강등하고 안내.

R01의 "Detached 섹션"은 이 두 서버(amux 소켓 + default 소켓)를 모두 열거하는 것으로 확장된다.

### 3.3 muxad 수명주기와 zero-config 온보딩

- muxad는 앱이 소유하지 않는다: `launchd` LaunchAgent(`com.open330.amux.muxad`)로 등록해 **앱이 꺼져도 관측이 지속**(detach 후 밤새 에이전트 상태가 원장에 쌓여야 아침 timeline이 완성됨). 앱은 소켓 클라이언트일 뿐.
- 첫 실행 마법사(전부 사용자 동의 기반, `muxa init` 프리셋 재사용):
  1. muxad LaunchAgent 등록
  2. 에이전트 hook 자동 배선 — `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.gemini/settings.json`
  3. 알림 소유권: amux가 알림 담당, muxa notify off 프리셋 (R01 §4.3)
  4. (어댑션 모드 사용자) tmux status-line에 muxa status-line 추가 여부
- 제거도 일급: 설정에 "Uninstall integrations" (hook 제거 + LaunchAgent 해제 + 전용 서버 종료). muxa init의 uninstall 경로 재사용.

### 3.4 버전 결속과 호환성 매트릭스

- amux 릴리스 = {앱, 번들 tmux 버전, muxad/muxa 버전, muxa protocol 버전} 튜플로 핀. 릴리스 CI에 통합 스모크 테스트: 번들 tmux로 세션 생성 → -CC 미러 → muxad hello/subscribe → 가짜 AgentEvent ingest → 배지 상태 검증.
- muxa protocol은 pre-1.0이라 minor마다 깨질 수 있음(PROTOCOL.md 명시) → **동봉이 곧 해법**: 앱과 데몬이 항상 같이 업데이트되므로 protocol pin이 안전. 단 외부 설치 muxad(구버전)와 만날 수 있으므로 `hello` 협상 실패 시 "번들 muxad로 교체 제안" UX.
- 업그레이드 시 muxad 재시작 시퀀스: 새 버전 설치 → LaunchAgent 리로드 → 앱 재연결(스냅샷 reconcile). 상태는 muxad가 디스크 원장에 쌓으므로 유실 없음.

### 3.5 CLI 통합

`amux` 단일 CLI(기존 cmux 소켓 CLI 계승 + 확장):

```
amux new <name>        # tmux 세션 생성 + 앱 워크스페이스 (앱 미실행 시 세션만)
amux attach <name>     # 터미널에서 attach (bundled tmux -L amux)
amux ls                # 세션 + 에이전트 상태 (muxad snapshot 조인)
amux attend            # 가장 오래 blocked인 에이전트로 (앱 실행 중이면 앱 포커스)
amux send <target> "…" # send-keys 프롬프트 주입
amux stats / timeline  # muxa 위임
```

원칙: **앱 없이도 CLI+tmux+muxad만으로 성립**(headless에서도 muxa 가치 유지), 앱이 있으면 같은 명령이 GUI 포커스로 승격. R01 D5의 "단일 mutation 경로" 원칙과 동일 — CLI와 GUI가 같은 tmux/muxad를 본다.

### 3.6 저장소 구조

- `open330/amux` = cmux fork (GPL, 앱 + amux-cli + 릴리스 파이프라인). ghostty는 기존처럼 submodule.
- `open330/muxa` = 현행 유지 (MIT/Apache). amux 릴리스 CI가 태그된 muxa 릴리스 바이너리를 가져와 동봉(소스 vendoring 대신 릴리스 아티팩트 pin — 라이선스 경계도 명확해짐).
- tmux는 빌드 시 소스에서 universal 빌드(ISC 고지 포함) 또는 정적 빌드 아티팩트 pin.
- upstream cmux 머지 전략(R01 D5)은 유지하되, 제품 분기(브랜딩, 번들 ID `com.open330.amux`, 소켓 경로, Sparkle 피드 URL)는 초기 1회 커밋으로 격리해 머지 충돌 면적 최소화.

---

## 3.5+ Phase 0 실증 결과 (2026-07-07, Xcode 설치 전 셸 레벨 검증)

로컬 `tmux -CC`(tmux 3.7, pty 구동, `-f /dev/null` 격리)로 전 게이트 통과:

| 게이트 | 결과 |
|---|---|
| attach handshake / 재부착 | OK (~10ms) |
| `%session-renamed` / `%window-add` / `%layout-change` (외부 CLI 조작 포함) | OK |
| OSC 8 하이퍼링크 `%output` 패스스루 | OK |
| 200k 라인 flood | OK — 0.2s, 스트림 2.8MB, `%pause` 미발생(flow control 기본 off) |
| tmux 소유 스크롤백 (`capture-pane -S`) | OK (history-limit만큼 회수) |
| detach 후 세션 생존 | OK |

추가 실증 사실:
- **로컬 tmux client는 control mode여도 tty 필수** (`tcgetattr` 실패). 스파이크는 `script -q /dev/null` pty 래핑으로 해결(SSH 경로의 `-tt`와 동일한 CRLF 스트림). Phase 1에서 앱 내 PTY 스폰으로 대체 후보.
- **사용자 `~/.tmux.conf` 격리는 필수**: 격리 없이 amux 소켓 서버를 띄우자 tmux-resurrect/continuum이 사용자 세션 수십 개를 amux 서버에 복원해 스트림을 오염시켰다. amux 엔진은 반드시 전용 conf(스파이크는 `-f /dev/null`, 제품은 관리형 amux.conf)로 기동한다.
- **muxad 라이브 검증**: 설치 데몬은 protocol v3(min 1). v2 pin hello → snapshot(40 agents, 문서 밖 필드 포함 lenient 디코딩) → subscribe(실시간 transition 수신) → ingest 왕복(working→stopped) 전부 정상. `hello` 없는 요청은 strict-match로 거부되므로 모든 연결은 hello 선행.
- **`CmuxMuxa` 패키지 구현 완료**(`Packages/macOS/CmuxMuxa`): actor `MuxaClient`(hello/snapshot/transitions), lenient enum 디코딩, FakeMuxaDaemon 기반 Swift Testing 테스트. 라이브 muxad 대상 통합 검증 통과. pbxproj(cmux+cmux-unit)·워크스페이스 그룹·Package.resolved 정책 검사 통과. `swift test`는 CLT에 Testing 모듈이 없어 Xcode 설치 후 실행.

## 4. 로드맵 반영 (R01 델타)

- **Phase 0 게이트에 추가**: 번들 tmux(`-L amux` 전용 소켓)로 -CC 스파이크 수행 — 버전 핀의 이점을 처음부터 검증.
- **Phase 1**: 이중 모드 중 amux 엔진 모드만. 어댑션 모드(시스템 tmux 흡수)는 Phase 3로.
- **Phase 2**: muxad LaunchAgent + 첫 실행 마법사(hook 배선 동의 UX 포함).
- **Phase 4(신설, 제품화)**: 브랜딩 교체, dmg/Sparkle 파이프라인, Homebrew cask, 통합 스모크 CI, 라이선스 고지 화면(GPL 소스 링크 + tmux/Ghostty/muxa 고지), 문서 사이트.

## 5. 착수 주에 끝낼 결정 사항

1. 라이선스 노선 확정: GPL 공개 fork로 갈 것인가, Manaflow 상업 라이선스를 협상할 것인가. (권고: GPL 공개)
2. 이름 확정: amux 유지 여부 — 도메인/브랜드 선점 확인 후. (권고: 선점되면 유지)
3. 번들 tmux 버전 핀(3.5a 기준선) + 최소 지원 macOS 버전.
4. muxa에 amux 전용 확장이 필요한지(R01 §7-3): 통합 배포로 protocol pin이 쉬워졌으므로 subscribe 확장을 muxa 로드맵에 넣기 좋은 타이밍.
