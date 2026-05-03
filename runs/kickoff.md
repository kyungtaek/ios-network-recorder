---
id: kickoff
type: task
created_at: 2026-05-02T00:00:00Z
---

# ios-network-recorder MVP 개발 태스크

## 현재 상태

T1(프로젝트 스캐폴딩 + harness 이식)은 완료되었다.

- `sdk/Package.swift` — Moya 의존성 포함, `xcrun swift build` PASS 확인
- `.claude/agents/` — pm/architect/developer/qa/researcher 5개 에이전트 배치
- `CLAUDE.md`, `PDS.md` — 프로젝트 문서 완비
- 시뮬레이터: iPhone 16 / iOS 18.6 사용 가능 (`xcrun simctl` 확인됨)
- Swift: `xcrun swift` (6.x) 사용 필수 — PATH의 `swift`는 5.2라 직접 실행 불가

## 남은 작업 (T2–T7)

### T2: HAR 데이터 모델
`sdk/Sources/NetworkRecorder/HAR/` 하위에 HAR 1.2 Codable 모델 전체 구현.
- `HARDocument`, `HARLog`, `HAREntry`, `HARRequest`, `HARResponse`
- `HARTimings`, `HARPostData`, `HARContent`, `HARNameValue`, `HARCache`
- HAR 1.2 규칙: 미측정 timing = `-1`, `postData.mimeType` 필수
- `HARModelTests.swift`: JSON 인코딩/디코딩 왕복 + timings 합산 검증
- DoD: `xcrun swift test --filter HARModelTests` all PASS

### T3: MoyaRecorderPlugin + RecordingSession
- `RecordingState.swift` (enum: idle/recording/paused/stopped)
- `RecordingSession.swift` (actor):
  - `entries: [HAREntry]` — actor 내부 관리
  - `pendingEntries: [String: PendingEntry]` — **NSLock + Dictionary** (actor 밖, 동기 저장)
  - `startRecording()`, `pauseRecording()`, `resumeRecording()`, `stopRecording()`, `reset()`
- `MoyaRecorderPlugin.swift` (PluginType):
  - `prepare(_:target:)` → `X-NR-Request-ID` UUID 헤더 주입
  - `willSend(_:target:)` → request 캡처 + pendingEntry 등록
  - `didReceive(_:target:)` → response 캡처 + timing 계산 + entry 완성
  - Body 캡처: httpBody 직접 / multipart params 재구성 / streaming `[streaming-body]` 표기
  - 민감 헤더 마스킹: 기본값 `["Authorization","Cookie","Set-Cookie","Proxy-Authorization"]` → `[REDACTED]`
  - timing: `send=0, wait=totalElapsed, receive=0`, 나머지 `-1`
- `RecordingSessionTests.swift`: 상태 전이 전 경로, pendingEntry correlation 테스트
- DoD: `xcrun swift test` all PASS

### T4: HARExporter
- `HARExporter.swift`:
  - `exportToFile(session:) async throws -> URL`
  - 파일명: `session-{ISO8601}.har` in `FileManager.default.temporaryDirectory`
  - JSONEncoder: prettyPrinted + sortedKeys
- `HARExporterTests.swift`: 샘플 entries → 파일 생성 → JSON parse 왕복 검증
- DoD: `xcrun swift test` all PASS

### T5: SampleApp Xcode 프로젝트 (XcodeGen 필수)
- `SampleApp/project.yml` 작성 후 `xcodegen generate --spec SampleApp/project.yml`
- Info.plist: `NSAllowsLocalNetworking: true` (ATS — Prism localhost 통신)
- `APITarget.swift` (Moya TargetType):
  - `GET /users/me` (헤더: Authorization 포함)
  - `GET /items?q=&limit=` (query params)
  - `POST /items` (JSON body)
  - `GET /orders`
- `APIProvider.swift`: `MoyaProvider` + `MoyaRecorderPlugin` 통합
- SampleApp은 UI 없이 **XCUITest를 통해 자동화**:
  - `SampleAppUITests` 타겟 추가
  - `E2ERecordingTest.swift`:
    1. 레코딩 시작
    2. 모든 APITarget 요청 순차 실행 (200/401/500 케이스 포함)
    3. 레코딩 중단
    4. HAR export → `/tmp/exported.har` 저장
  - 401: `Authorization: Bearer invalid` 헤더, 500: Prism `Prefer: code=500` 헤더로 유도
- DoD: `xcodebuild -project SampleApp/SampleApp.xcodeproj -scheme SampleApp -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build` exit 0

### T6: Prism mock server 설정 (T5와 병렬 가능)
`prism/openapi.yaml` 작성:
- `GET /users/me` → 200 (User) / 401 (Unauthorized)
- `GET /items?q=&limit=` → 200 (Item 배열)
- `POST /items` (body: name/price) → 201 / 400
- `GET /orders` → 200 / 500

DoD:
```bash
npx @stoplight/prism-cli mock prism/openapi.yaml --port 4010 &
curl -s http://127.0.0.1:4010/users/me       # 200
curl -s -H "Prefer: code=401" http://127.0.0.1:4010/users/me  # 401
curl -s -H "Prefer: code=500" http://127.0.0.1:4010/orders    # 500
```

### T7: E2E 통합 + HAR 검증 (QA 전담)
1. Prism 기동 (port 4010)
2. `xcodebuild test -scheme SampleApp ...` 로 `E2ERecordingTest` 실행
3. `/tmp/exported.har` 생성 확인
4. `npx har-validator /tmp/exported.har` PASS
5. HAR 내용 검증 (Python 스크립트):
   - status 200, 401, 500 각각 존재
   - query params (q, limit) 캡처
   - POST body (postData.text) 캡처
   - timing: wait > 0, send=0, receive=0
   - Authorization 헤더 값 = `[REDACTED]`

## 핵심 제약

- `xcrun swift build` / `xcrun swift test` 사용 (PATH swift는 5.2라 사용 불가)
- XcodeGen으로 SampleApp 프로젝트 생성 (`.pbxproj` 수동 작성 금지)
- Moya 외 새 SPM 의존성 추가 시 → risk_level: high handoff → human gate 필수
- QA eval rubric 10개 기준 전부 PASS해야 run_end (일부 PASS로 종료 금지)
- 평가 규칙 변경 금지. FAIL이 있으면 수정 후 재평가 루프

## 환경 정보

- Project root: /Users/kent/garage/ios-network-recorder
- Swift: `xcrun swift` (6.x) 사용
- Simulator: iPhone 16 / iOS 18.6
- Prism port: 4010
- HAR export 경로: `/tmp/exported.har`
