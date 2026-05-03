# ios-network-recorder

Moya Plugin SDK — iOS 앱에서 네트워크 요청/응답을 HAR 1.2 파일로 녹화하고 공유하기로 export.

## 에이전트 정의

| 에이전트 | 역할 | 모델 |
|---------|------|------|
| **pm** | 라우팅 오케스트레이터 | Sonnet 4.6 |
| **architect** | Swift/iOS SDK 설계 | Opus 4.7 |
| **developer** | 구현 (Swift + SPM + Xcode) | Sonnet 4.6 |
| **qa** | 빌드/테스트/E2E 검증 | Sonnet 4.6 |
| **researcher** | 기술 리서치 | Haiku 4.5 |

## 프로젝트 구조

```
ios-network-recorder/
├── scripts/harness.py          # 멀티에이전트 제어 루프
├── .claude/agents/             # 에이전트 정의
├── runs/                       # session.log, handoffs (런타임 생성)
├── sdk/                        # Swift Package (NetworkRecorder)
│   ├── Package.swift
│   ├── Sources/NetworkRecorder/
│   └── Tests/NetworkRecorderTests/
├── SampleApp/                  # Xcode 프로젝트 (XcodeGen)
│   ├── project.yml
│   └── SampleApp/
├── prism/
│   ├── openapi.yaml
│   └── README.md
└── pyproject.toml
```

## 기술 스택

- Swift 6+, iOS 17+
- Moya (네트워크 추상화)
- Swift Package Manager (SDK 패키징)
- XcodeGen (SampleApp 프로젝트 생성)
- Prism (mock server)

## 주요 명령어

```bash
# 하네스 실행 (대화형)
uv run python scripts/harness.py

# 하네스 자동 실행
uv run python scripts/harness.py --auto --budget-minutes 60

# SDK 빌드 (xcrun 필수 — PATH의 swift는 5.2, xcrun swift는 6.x)
cd sdk && xcrun swift build

# SDK 테스트
cd sdk && xcrun swift test

# SampleApp 빌드 (XcodeGen 먼저)
xcodegen generate --spec SampleApp/project.yml
xcodebuild -project SampleApp/SampleApp.xcodeproj \
  -scheme SampleApp \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  build

# Prism mock server
npx @stoplight/prism-cli mock prism/openapi.yaml --port 4010
```

## 사전 조건

```bash
# 시뮬레이터 확인
xcrun simctl list devices available | grep "iPhone 16"

# 도구 설치
brew install xcodegen
npm install -g @stoplight/prism-cli har-validator
```

## ⚠️ 보안 주의사항

MVP에서 `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization` 헤더는 HAR에 `[REDACTED]`로 마스킹됩니다. 그 외 민감한 헤더가 있다면 `MoyaRecorderPlugin(sensitiveHeaders:)` 파라미터로 추가하세요. AirDrop/iCloud로 전송되는 HAR 파일에 토큰이 평문으로 포함되지 않도록 주의하세요.
