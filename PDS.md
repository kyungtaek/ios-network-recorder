# PDS — ios-network-recorder

## MVP 목표

QA가 iOS 앱에서 버그를 발견했을 때, 발생 당시의 네트워크 트래픽을 녹화해서 개발자에게 전달할 수 있는 SDK.

## Done-When (QA 검증 기준)

| # | 기준 | 검증 방법 |
|---|------|----------|
| 1 | SDK 빌드 성공 | `xcrun swift build` exit 0, zero errors |
| 2 | 유닛 테스트 전체 통과 (52개 이상) | `xcrun swift test` all PASS |
| 3 | SampleApp 빌드 성공 | `xcodebuild ... build` exit 0 |
| 4 | 200 OK 응답 녹화 | HAR entries에 status=200, headers, body 포함 |
| 5 | 에러 응답 녹화 (401, 500) | HAR entries에 각 status 존재 |
| 6 | HAR 1.2 스키마 유효성 | `har-validator` PASS |
| 7 | Query param 캡처 | GET `/items?q=foo&limit=10` → HAR queryString에 포함 |
| 8 | POST body 캡처 | POST `/items` → HAR postData.text에 body 포함 |
| 9 | Timing 규칙 준수 | `wait > 0`, `send=0`, `receive=0`, 미측정 = `-1` |
| 10 | 민감 헤더 마스킹 | Authorization 값이 `[REDACTED]` |
| 11 | Swift 6 / iOS 17 준수 | `swiftLanguageMode(.v6)` 빌드 경고/오류 없음, 배포 타겟 iOS 17 |
| 12 | SessionStore 세션 영속성 | `startNewSession()` → 파일 생성, `persist()` → 파일 업데이트, `listSessions()` → 최신순 정렬 |
| 13 | SessionListViewController UI | `SessionListViewController` 인스턴스화 가능, iOS 17+ 빌드 성공 |
| 14 | noMasking 옵션 | `sensitiveHeaders: .noMasking` 설정 시 Authorization 값이 `[REDACTED]` 아님 |
| 15 | allowedDomains 필터 | 허용 도메인만 녹화, 그 외 도메인 요청은 HAR에 포함 안 됨 |
| 16 | excludedQueryParams 필터 | 지정한 param이 HAR queryString 및 URL 모두에서 제거됨 |

## 범위 밖 (Non-Goals)

- WebSocket 녹화
- 멀티파트 body 내용 전체 캡처 (params 목록만)
- 실시간 스트리밍 body 캡처
- Android 지원
- 서드파티 SDK 트래픽 캡처 (Moya 외 URLSession 직접 호출)

## 보안 결정

- `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization` 헤더는 기본값으로 `[REDACTED]` 처리
- `sensitiveHeaders: MoyaRecorderPlugin.noMasking` 으로 마스킹 비활성화 가능 (디버그 빌드 전용)
- `sensitiveHeaders: MoyaRecorderPlugin.defaultSensitiveHeaders.union([...])` 으로 추가 헤더 마스킹 가능
