# Full E2E Validation — Phase 1 완성 검증

## 배경

Phase 1 구현 완료 상태. 이전 하네스 2회 실행으로 기본 기능 검증됨.
이번 실행은 추가된 기능 전체를 PDS 16개 기준으로 종합 검증한다.

**변경 이력:**
- run `20260501T235529-bootstrap`: MVP 10개 기준 PASS
- run `20260502T095107-bootstrap`: 버그 수정 + 신규 기능 (noMasking, allowedDomains, excludedQueryParams, SessionStore, SessionListViewController, Swift 6, iOS 17)

## 검증 범위 (PDS 기준 16개)

### 기존 기준 재검증 (#1~#10)
- SDK 빌드, 유닛 테스트 52개 이상, SampleApp 빌드
- 200/401/500 캡처, HAR 1.2 스키마, query param, POST body, timing 규칙, 민감 헤더 마스킹

### 신규 기준 검증 (#11~#16)

**#11 Swift 6 / iOS 17 준수**
- `sdk/Package.swift`에 `swiftLanguageMode(.v6)` 확인
- `xcrun swift build` 에서 Swift 6 관련 에러/경고 없음
- 배포 타겟 `.iOS(.v17)` 확인

**#12 SessionStore 세션 영속성**
- `SessionStoreTests.swift` 9개 테스트 PASS 확인
- `startNewSession()` → `ApplicationSupport/ios-network-recorder/sessions/` 아래 파일 생성
- `persist()` → 파일 업데이트 (entryCount, lastUpdatedAt)
- `listSessions()` → startedAt 기준 내림차순 정렬

**#13 SessionListViewController UI**
- `#if canImport(UIKit)` 조건부 컴파일 확인
- iOS SampleApp 빌드에서 SessionListViewController 포함 성공

**#14 noMasking 옵션**
- `MoyaRecorderPlugin(sensitiveHeaders: .noMasking)` 로 초기화 시
- HAR에서 Authorization 헤더 값이 `[REDACTED]` 아닌 실제값

**#15 allowedDomains 필터**
- `allowedDomains: ["api.example.com"]` 설정 시 해당 도메인 요청만 녹화
- 그 외 도메인 (e.g. `other.example.com`) 요청은 HAR entries에 없음

**#16 excludedQueryParams 필터**
- `excludedQueryParams: ["md", "sig"]` 설정 시
- HAR `queryString` 배열에 `md`, `sig` 항목 없음
- HAR `request.url` 문자열에도 `md=`, `sig=` 없음

## 작업 지시

### Step 1: QA — 현재 상태 전체 검증

PDS 1~16 기준 전부 검증하라.
유닛 테스트 52개 확인 후 SampleApp E2E까지 수행하라.
신규 기준 #11~#16은 유닛 테스트 결과로 검증 가능하다 (SessionStoreTests, MoyaRecorderPluginTests 참조).

### Step 2: FAIL 항목 발견 시

Developer에게 라우팅. 수정 후 QA 재검증.

### Step 3: 전체 PASS 시

`halt` 상태로 종료. 최종 결과를 session.log에 기록.

## 완료 조건

PDS 16개 기준 전체 PASS → `halt`.

SampleApp 빌드가 시뮬레이터 문제로 불가한 경우:
- 기준 #3, #13은 "SKIPPED (simulator issue)" 처리 허용
- 나머지 15개 기준 PASS 시 `halt` 가능
