# ios-network-recorder

A Moya plugin SDK that records iOS app network traffic as [HAR 1.2](http://www.softwareishard.com/blog/har-12-spec/) files and exports them via the iOS share sheet — so QA can hand developers a reproducible network snapshot alongside a bug report.

---

## Overview

```
QA finds bug → taps "Export HAR" → shares .har file via AirDrop/Jira
Developer receives .har → replays traffic locally → reproduces & fixes bug
```

**Phase 1 (this repo):** Capture — record requests/responses as HAR  
**Phase 2 (planned):** Replay — mock a URLSession using a captured HAR file

---

## Features

- Drop-in `MoyaRecorderPlugin` — no changes to existing provider setup
- HAR 1.2 compliant output (validated by `har-validator`)
- Request/response correlation via injected `X-NR-Request-ID` header (stripped from HAR output)
- Sensitive header masking: `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization` → `[REDACTED]`
- Binary response bodies base64-encoded in `content.text`
- Multipart upload params captured as HAR `params` array
- Thread-safe: `RecordingSession` actor + `NSLock`-protected `PendingStore`
- Export to `.har` file via `UIActivityViewController` (iOS share sheet)

---

## Requirements

- iOS 17+
- Swift 6+
- [Moya](https://github.com/Moya/Moya) 15+

---

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/kyungtaek/ios-network-recorder.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "NetworkRecorder", package: "ios-network-recorder")
        ]
    )
]
```

---

## Usage

### 1. Create a shared session and plugin

```swift
import NetworkRecorder
import Moya

let recordingSession = RecordingSession()
let recorderPlugin = MoyaRecorderPlugin(session: recordingSession)

let provider = MoyaProvider<MyAPI>(plugins: [recorderPlugin])
```

### 2. Start / stop recording

```swift
// Start
await recordingSession.startRecording()

// Make requests via your existing provider
let response = try await provider.request(.getUser)

// Stop
await recordingSession.stopRecording()
```

### 3. Export as HAR

```swift
let exporter = HARExporter()
let harURL = try await exporter.exportToFile(session: recordingSession)

// Present share sheet
let activityVC = UIActivityViewController(activityItems: [harURL], applicationActivities: nil)
present(activityVC, animated: true)
```

### 4. Browse and export sessions

`SessionListViewController` provides a ready-made UI for listing all persisted sessions.

```swift
let vc = SessionListViewController()                // uses SessionStore.shared
let nav = UINavigationController(rootViewController: vc)
present(nav, animated: true)
```

Features:
- Sessions listed newest first; current app-launch session is marked **CURRENT**
- Swipe left to export any session as `.har` (iOS share sheet)
- Swipe right to delete
- Pull to refresh

### Masking additional sensitive headers

```swift
let recorderPlugin = MoyaRecorderPlugin(
    session: recordingSession,
    sensitiveHeaders: MoyaRecorderPlugin.defaultSensitiveHeaders
        .union(["X-API-Key", "X-Auth-Token"])
)
```

### Pausing mid-session

```swift
await recordingSession.pauseRecording()   // entries accumulate but are not saved
await recordingSession.resumeRecording()
```

---

## Recording State Machine

```
idle ──startRecording()──▶ recording ──pauseRecording()──▶ paused
                               │                               │
                          stopRecording()               resumeRecording()
                               │                               │
                               ▼                               │
                            stopped ◀──stopRecording()─────────┘
                               │
                           reset()
                               │
                               ▼
                             idle
```

---

## HAR Timing Notes

Moya's plugin callbacks do not expose separate send/wait/receive phases. Timings are recorded as:

| Field     | Value        |
|-----------|--------------|
| `send`    | `0`          |
| `wait`    | total ms     |
| `receive` | `0`          |
| others    | `-1` (unmeasured) |

---

## Session Persistence

Each app launch automatically creates a new `RecordingSession` via `SessionStore`. Sessions are stored on disk and survive app restarts.

```swift
// App launch (AppDelegate / @main)
let session = try await SessionStore.shared.startNewSession()
let plugin  = MoyaRecorderPlugin(session: session)

// On stop / entering background
try await SessionStore.shared.persist(session)

// Query sessions
let items = try await SessionStore.shared.listSessions()
// items[0].isCurrentSession == true
// items[0].meta.startedAt / lastUpdatedAt / entryCount

// Export any session
let url = try await SessionStore.shared.exportSession(id: items[1].meta.id)
```

Sessions not updated for **7 days** are automatically purged on the next app launch.

Storage location: `ApplicationSupport/ios-network-recorder/sessions/{uuid}.nrsession`

---

## Project Structure

```
ios-network-recorder/
├── sdk/                        # Swift Package — NetworkRecorder
│   ├── Sources/NetworkRecorder/
│   │   ├── Plugin/             # MoyaRecorderPlugin, builders, redactor
│   │   ├── Session/            # RecordingSession (actor), PendingStore
│   │   ├── HAR/                # Codable HAR 1.2 models (Sendable)
│   │   ├── Store/              # SessionStore, SessionMeta
│   │   ├── Exporter/           # HARExporter
│   │   └── UI/                 # SessionListViewController (iOS)
│   └── Tests/NetworkRecorderTests/   # 52 unit tests
├── SampleApp/                  # Xcode demo app (XcodeGen)
├── prism/                      # OpenAPI mock server for E2E tests
└── scripts/harness.py          # Multi-agent dev harness
```

---

## Development

```bash
# SDK build & test
cd sdk && xcrun swift build
cd sdk && xcrun swift test

# SampleApp build
xcodegen generate --spec SampleApp/project.yml
xcodebuild -project SampleApp/SampleApp.xcodeproj \
  -scheme SampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  build

# Prism mock server (for E2E)
npx @stoplight/prism-cli mock prism/openapi.yaml --port 4010
```

---

## Security

HAR files contain full request/response data. Before sharing:

- `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization` are masked by default
- Add project-specific sensitive headers via `sensitiveHeaders:` parameter
- HAR files shared over AirDrop or attached to Jira tickets are visible to recipients — treat them as you would log files

---

## Roadmap

- [ ] **Phase 2: HAR Replay** — `HARReplayConfiguration` + `URLProtocol`-based mock, selective passthrough to real server, `ignoredQueryParams` for HMAC signatures
- [ ] `URLSession` direct support (non-Moya)
- [ ] SwiftUI export view component
- [ ] Automatic PII detection in response bodies

---

## License

MIT

---

---

# ios-network-recorder (한국어)

QA가 iOS 앱에서 버그를 발견했을 때 네트워크 트래픽을 [HAR 1.2](http://www.softwareishard.com/blog/har-12-spec/) 파일로 녹화하고 iOS 공유하기로 export하는 Moya 플러그인 SDK.

---

## 개요

```
QA 버그 발견 → "HAR 내보내기" 탭 → AirDrop/Jira로 .har 파일 공유
개발자 수신 → 로컬에서 트래픽 재현 → 버그 재현 및 수정
```

**Phase 1 (현재):** 캡처 — 요청/응답을 HAR로 녹화  
**Phase 2 (예정):** 리플레이 — 캡처된 HAR 파일로 URLSession 모킹

---

## 기능

- `MoyaRecorderPlugin` 단순 추가 — 기존 provider 코드 변경 불필요
- HAR 1.2 스펙 준수 (`har-validator` 검증 통과)
- `X-NR-Request-ID` 헤더로 요청/응답 상관관계 추적 (HAR 출력에서 자동 제거)
- 민감 헤더 자동 마스킹: `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization` → `[REDACTED]`
- binary 응답 body base64 인코딩 (`content.text`)
- multipart 업로드 파라미터를 HAR `params` 배열로 캡처
- 스레드 안전: `RecordingSession` actor + NSLock 기반 `PendingStore`
- `UIActivityViewController`로 `.har` 파일 export (iOS 공유하기)

---

## 요구사항

- iOS 17+
- Swift 6+
- [Moya](https://github.com/Moya/Moya) 15+

---

## 설치

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/kyungtaek/ios-network-recorder.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "NetworkRecorder", package: "ios-network-recorder")
        ]
    )
]
```

---

## 사용법

### 1. 세션과 플러그인 생성

```swift
import NetworkRecorder
import Moya

let recordingSession = RecordingSession()
let recorderPlugin = MoyaRecorderPlugin(session: recordingSession)

let provider = MoyaProvider<MyAPI>(plugins: [recorderPlugin])
```

### 2. 녹화 시작 / 중지

```swift
// 시작
await recordingSession.startRecording()

// 기존 provider로 요청 (코드 변경 없음)
let response = try await provider.request(.getUser)

// 중지
await recordingSession.stopRecording()
```

### 3. HAR 파일 export

```swift
let exporter = HARExporter()
let harURL = try await exporter.exportToFile(session: recordingSession)

// 공유하기 시트 표시
let activityVC = UIActivityViewController(activityItems: [harURL], applicationActivities: nil)
present(activityVC, animated: true)
```

### 4. 세션 목록 UI

```swift
let vc = SessionListViewController()   // SessionStore.shared 기본 사용
let nav = UINavigationController(rootViewController: vc)
present(nav, animated: true)
```

- 최신순 정렬, 현재 세션 **CURRENT** 배지 표시
- 왼쪽 스와이프 → `.har` export (iOS 공유하기)
- 오른쪽 스와이프 → 삭제
- 당겨서 새로고침

### 추가 민감 헤더 마스킹

```swift
let recorderPlugin = MoyaRecorderPlugin(
    session: recordingSession,
    sensitiveHeaders: MoyaRecorderPlugin.defaultSensitiveHeaders
        .union(["X-API-Key", "X-Auth-Token"])
)
```

---

## 보안 주의사항

HAR 파일에는 요청/응답 전체 데이터가 포함됩니다.

- `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization`은 기본값으로 마스킹됩니다
- 프로젝트별 민감 헤더는 `sensitiveHeaders:` 파라미터로 추가하세요
- AirDrop 또는 Jira 첨부 파일로 전송되는 HAR 파일은 수신자에게 노출됩니다 — 로그 파일처럼 취급하세요

---

## 로드맵

- [ ] **Phase 2: HAR 리플레이** — `HARReplayConfiguration` + `URLProtocol` 기반 모킹, 실서버 패스스루, `ignoredQueryParams` (HMAC 서명 등 동적 파라미터 무시)
- [ ] `URLSession` 직접 지원 (Moya 외)
- [ ] SwiftUI export 뷰 컴포넌트
- [ ] 응답 body 자동 PII 탐지

---

## 라이선스

MIT
