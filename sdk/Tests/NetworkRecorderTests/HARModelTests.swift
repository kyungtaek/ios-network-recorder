// HARModelTests.swift — Unit tests for HAR 1.2 data models (T2).

import XCTest
@testable import NetworkRecorder

final class HARModelTests: XCTestCase {

    // MARK: - Coder helpers

    /// Returns a matched encoder/decoder pair using the custom ISO8601 date strategy.
    static func makeCoders() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(HARDateFormatter.iso8601.string(from: date))
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = HARDateFormatter.iso8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Cannot parse date: \(s)"
                )
            }
            return d
        }
        return (enc, dec)
    }

    // MARK: - test_HARDocument_roundTrip

    func test_HARDocument_roundTrip() throws {
        let (enc, dec) = HARModelTests.makeCoders()

        let creator = HARCreator(name: "test", version: "0.0.1")
        let timings = HARTimings(send: 0, wait: 123.4, receive: 0)
        let request = HARRequest(
            method: "GET",
            url: "https://example.com/api",
            headers: [HARNameValue(name: "Accept", value: "application/json")],
            queryString: [HARNameValue(name: "q", value: "hello")],
            bodySize: -1
        )
        let content = HARContent(size: 11, mimeType: "text/plain", text: "hello world")
        let response = HARResponse(
            status: 200,
            statusText: "OK",
            headers: [],
            content: content,
            bodySize: 11
        )
        let entry = HAREntry(
            startedDateTime: Date(timeIntervalSinceReferenceDate: 0),
            time: timings.send + timings.wait + timings.receive,
            request: request,
            response: response,
            timings: timings
        )
        let doc = HARDocument(log: HARLog(creator: creator, entries: [entry]))

        let data = try enc.encode(doc)
        let decoded = try dec.decode(HARDocument.self, from: data)
        XCTAssertEqual(doc, decoded)
    }

    // MARK: - test_HARCache_encodesAsEmptyObject

    func test_HARCache_encodesAsEmptyObject() throws {
        let (enc, _) = HARModelTests.makeCoders()
        let cache = HARCache()
        let data = try enc.encode(cache)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "HARCache should encode as a JSON object")
        XCTAssertEqual(json?.count, 0, "HARCache should encode as an empty JSON object {}")
    }

    // MARK: - test_HAREntry_timeEqualsTimingsSum

    func test_HAREntry_timeEqualsTimingsSum() {
        let timings = HARTimings(send: 0, wait: 456.7, receive: 0)
        let entry = HAREntry(
            startedDateTime: Date(),
            time: timings.send + timings.wait + timings.receive,
            request: HARRequest(
                method: "GET",
                url: "https://example.com",
                headers: [],
                queryString: [],
                bodySize: -1
            ),
            response: HARResponse(
                status: 200,
                statusText: "OK",
                headers: [],
                content: HARContent(size: 0, mimeType: "application/json"),
                bodySize: 0
            ),
            timings: timings
        )
        XCTAssertEqual(entry.time, timings.send + timings.wait + timings.receive)
    }

    // MARK: - test_HARDate_includesFractionalSeconds

    func test_HARDate_includesFractionalSeconds() throws {
        let (enc, dec) = HARModelTests.makeCoders()

        // Use a date with a known sub-second component
        let date = Date(timeIntervalSinceReferenceDate: 0.5)  // 0.500 seconds
        let encoded = HARDateFormatter.iso8601.string(from: date)
        XCTAssertTrue(
            encoded.contains("."),
            "ISO8601 string should contain fractional seconds, got: \(encoded)"
        )

        // Also verify round-trip through JSONEncoder preserves subsecond precision
        struct Wrapper: Codable { var d: Date }
        let wrapper = Wrapper(d: date)
        let data = try enc.encode(wrapper)
        let decoded = try dec.decode(Wrapper.self, from: data)
        // Compare with 1ms tolerance due to floating-point representation
        XCTAssertEqual(
            date.timeIntervalSinceReferenceDate,
            decoded.d.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    // MARK: - test_HARTimings_unmeasuredFieldsEncodeAsMinusOne

    func test_HARTimings_unmeasuredFieldsEncodeAsMinusOne() throws {
        let (enc, _) = HARModelTests.makeCoders()
        let timings = HARTimings(send: 0, wait: 100, receive: 0)
        let data = try enc.encode(timings)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["blocked"] as? Double, -1.0, "blocked should be -1")
        XCTAssertEqual(json?["dns"] as? Double, -1.0, "dns should be -1")
        XCTAssertEqual(json?["connect"] as? Double, -1.0, "connect should be -1")
        XCTAssertEqual(json?["ssl"] as? Double, -1.0, "ssl should be -1")
        XCTAssertEqual(json?["send"] as? Double, 0.0, "send should be 0")
        XCTAssertEqual(json?["wait"] as? Double, 100.0, "wait should be 100")
        XCTAssertEqual(json?["receive"] as? Double, 0.0, "receive should be 0")
    }
}
