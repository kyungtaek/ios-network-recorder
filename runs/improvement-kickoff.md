# Phase 1 개선 — SDK 버그 수정 및 테스트 보강

## 배경

PDS 10개 기준 전체 PASS 달성 (run: 20260501T235529-bootstrap, 87분).
코드 검수에서 HAR 1.2 스펙 위반 및 동시성 버그 발견.
**목표: 회귀 없이 수정하고 QA 재검증 통과.**

## 작업 목록 (우선순위 순)

### T1 [CRITICAL] Binary 응답 Base64 인코딩 수정

**파일:** `sdk/Sources/NetworkRecorder/Plugin/HARResponseBuilder.swift` lines 36–45

**현상:**
```swift
let bodyText = String(data: response.data, encoding: .utf8)
let content = HARContent(
    size: response.data.count,
    mimeType: mime,
    text: bodyText,                                         // ← nil (binary)
    encoding: bodyText == nil && !response.data.isEmpty ? "base64" : nil,  // ← "base64" 표기만 함
    comment: nil
)
```
`text` 필드에 실제 `response.data.base64EncodedString()` 인코딩 안 함 — HAR 뷰어에서 binary body 표시 불가, HAR 1.2 스펙 위반.

**수정:**
binary 판별 시 `text: response.data.base64EncodedString()` 으로 교체.

**신규 테스트 (`HARResponseBuilderTests.swift` 또는 기존 파일 확장):**
- binary data(PNG 등) 응답 → `content.text == data.base64EncodedString()`
- `content.encoding == "base64"`

---

### T2 [HIGH] PendingStore.popByURL FIFO 보장

**파일:** `sdk/Sources/NetworkRecorder/Session/PendingStore.swift` lines 28–38

**현상:**
```swift
guard let key = map.keys.first(where: { ... }) else { return nil }
```
Swift Dictionary는 이터레이션 순서 미정의 → 동일 URL 엔트리 여러 개일 때 가장 오래된 엔트리 대신 임의 엔트리 반환.

**수정:**
삽입 순서 배열 `private var insertionOrder: [String] = []` 추가.
- `insert`: `insertionOrder.append(id)` 함께 실행
- `pop(id)`: `insertionOrder.removeAll { $0 == id }`
- `popByURL`: `insertionOrder.first(where: { map[$0]?.harRequest.url 기반 매칭 })` 으로 FIFO 보장

**신규 테스트:**
- 동일 base URL로 2개 엔트리 삽입 → `popByURL` 호출 → 첫 번째 삽입된 것 반환 검증

---

### T3 [MEDIUM] MoyaError 케이스 레이블 파싱 개선

**파일:** `sdk/Sources/NetworkRecorder/Plugin/HARResponseBuilder.swift` lines 70–74

**현상:**
```swift
let caseLabel = String(describing: error)
    .split(separator: "(")
    .first
    .map(String.init) ?? "moyaError"
```
Swift 내부 `describing` 구현에 의존 — 릴리즈 빌드 최적화나 Moya 버전 변경 시 불안정.

**수정:** MoyaError 케이스 명시적 switch:
```swift
let caseLabel: String
switch error {
case .imageMapping:       caseLabel = "imageMapping"
case .jsonMapping:        caseLabel = "jsonMapping"
case .stringMapping:      caseLabel = "stringMapping"
case .objectMapping:      caseLabel = "objectMapping"
case .encodableMapping:   caseLabel = "encodableMapping"
case .statusCode:         caseLabel = "statusCode"
case .underlying:         caseLabel = "underlying"
case .requestMapping:     caseLabel = "requestMapping"
case .parameterEncoding:  caseLabel = "parameterEncoding"
@unknown default:         caseLabel = "moyaError"
}
```

---

### T4 [LOW] redirectURL Location 헤더 캡처

**파일:** `sdk/Sources/NetworkRecorder/Plugin/HARResponseBuilder.swift`

**현상:** `redirectURL` 항상 `""` — 301/302 응답의 Location 헤더 미캡처.

**수정:**
```swift
let redirectURL = http?.value(forHTTPHeaderField: "Location") ?? ""
```

---

## 검증 기준

- `xcrun swift test` 전체 PASS (기존 32개 + 신규 테스트)
- PDS 10개 기준 전부 회귀 없음 (QA 재검증 필수)
- `har-validator` PASS 유지

## 완료 조건

QA가 PDS 10개 기준 재검증 후 전체 PASS → `halt`.
