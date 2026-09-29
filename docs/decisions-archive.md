# Decisions Archive

[architecture-decisions.md](architecture-decisions.md) 에서 **번복·대체가 확정된** Decision 의 원문을 무수정 보존하는 곳. live 파일이 길어지는 것을 막는 것이 목적이며, 상태·supersede 권위는 여전히 live 파일의 `상태 인덱스` 다 (여기 `목차` 는 네비게이션용).

옮길 때는 원문을 고치지 않는다 — 왜 그때 그렇게 판단했는지가 기록의 값이다.

## 목차

| # | 결정 한 줄 | 대체 |
|---|-----------|------|
| #4 | openclaw 통합을 완전 선택 기능으로 (미설치 시 완전 비가시) | #25 |

---

## Decision #4: openclaw 통합을 완전 선택 기능으로

- **도입**: v1.0.0 (#4)
- **컨텍스트**: 로컬 openclaw 게이트웨이의 건강 상태도 글랜스로 알면 좋지만, 이 앱 사용자 대부분은 openclaw 를 쓰지 않는다.
- **결정**: openclaw 관련 UI 는 **CLI 가 설치돼 있고 사용자가 `Claude + openclaw` 를 고른 경우에만** 존재한다. 그 외에는 메뉴바·팝오버·설정 어디에도 나타나지 않는다 — 비활성 상태로 회색 표시하지도 않는다.
- **이유**: [PHILOSOPHY.md](PHILOSOPHY.md) § Design Principles 2 — 전제가 없으면 흔적도 남기지 않는다. "회색으로 비활성" 도 글랜스를 방해하는 시각적 소음이다.
- **결정 세부**: 상태 판정은 포트/HTTP 체크가 아니라 `openclaw channels status --probe` 파싱이다. 게이트웨이는 살아 있어도 채널 워커만 죽은 상태(🟡)를 포트 체크로는 잡을 수 없기 때문이다.
- **결과**: 새 외부 의존성 없이 Foundation `Process` 만 쓴다. 셸아웃은 `OpenClawService` 에 격리하고 타임아웃·백그라운드 실행으로 메인 스레드를 막지 않는다. 자동복구(2회 연속 실패 + 쿨다운 600초 → `launchctl` 하드 재시작)를 붙였다.
- **동반 변경**: 앱 이름을 Quota → mongshell-menubar 로, 번들 ID 를 `com.quota.app` → `com.mongshell.menubar` 로 바꿨다 (Keychain 서비스·URL scheme 동반 변경). Claude Code 의 Keychain 항목 이름과 Claude 브랜드 문자열은 그대로 둔다 — 그건 우리 것이 아니다.
