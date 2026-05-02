// HARResponseBuilderTests.swift — Tests for HARResponseBuilder (T1 regression fixes).

import XCTest
import Moya
@testable import NetworkRecorder

final class HARResponseBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func makeHTTPResponse(
        url: URL = URL(string: "https://api.example.com/data")!,
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/octet-stream"]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func makeMoyaResponse(
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/octet-stream"]
    ) -> Response {
        let httpResp = makeHTTPResponse(statusCode: statusCode, headers: headers)
        return Response(statusCode: statusCode, data: data, request: nil, response: httpResp)
    }

    // MARK: - T1: Binary body — base64 encode

    func test_build_binaryBody_base64EncodesText() {
        // PNG magic bytes — not valid UTF-8
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47])
        let response = makeMoyaResponse(
            data: pngHeader,
            headers: ["Content-Type": "image/png"]
        )
        let harResponse = HARResponseBuilder.build(from: response, sensitiveHeaders: [])

        XCTAssertEqual(
            harResponse.content.text,
            pngHeader.base64EncodedString(),
            "Binary body must be base64-encoded in content.text"
        )
        XCTAssertEqual(
            harResponse.content.encoding,
            "base64",
            "content.encoding must be 'base64' for binary data"
        )
    }

    // MARK: - T1: UTF-8 body — plain text, no encoding flag

    func test_build_utf8Body_plainTextNoEncoding() {
        let bodyData = Data("hello".utf8)
        let response = makeMoyaResponse(
            data: bodyData,
            headers: ["Content-Type": "text/plain"]
        )
        let harResponse = HARResponseBuilder.build(from: response, sensitiveHeaders: [])

        XCTAssertEqual(
            harResponse.content.text,
            "hello",
            "UTF-8 body must appear verbatim in content.text"
        )
        XCTAssertNil(
            harResponse.content.encoding,
            "content.encoding must be nil for valid UTF-8 body"
        )
    }

    // MARK: - T4: Location header captured as redirectURL

    func test_build_301_capturesLocationAsRedirectURL() {
        let response = Response(
            statusCode: 301,
            data: Data(),
            request: nil,
            response: HTTPURLResponse(
                url: URL(string: "https://api.example.com/old")!,
                statusCode: 301,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://api.example.com/new"]
            )!
        )
        let harResponse = HARResponseBuilder.build(from: response, sensitiveHeaders: [])
        XCTAssertEqual(
            harResponse.redirectURL,
            "https://api.example.com/new",
            "redirectURL must be populated from Location header"
        )
    }

    func test_build_200_redirectURLIsEmpty() {
        let response = makeMoyaResponse(data: Data("{\"ok\":true}".utf8),
                                        headers: ["Content-Type": "application/json"])
        let harResponse = HARResponseBuilder.build(from: response, sensitiveHeaders: [])
        XCTAssertEqual(
            harResponse.redirectURL,
            "",
            "redirectURL must be empty when no Location header is present"
        )
    }

    // MARK: - T3: Explicit MoyaError case labels

    func test_buildError_statusCode_caseLabel() {
        let httpResp = makeHTTPResponse(statusCode: 404)
        let innerResponse = Response(statusCode: 404, data: Data(), request: nil, response: httpResp)
        let error = MoyaError.statusCode(innerResponse)
        let built = HARResponseBuilder.buildError(error: error, sensitiveHeaders: [])
        XCTAssertTrue(
            built.comment.contains("statusCode"),
            "Error comment must contain 'statusCode', got: \(built.comment)"
        )
    }

    func test_buildError_underlying_caseLabel() {
        let urlError = URLError(.notConnectedToInternet)
        let error = MoyaError.underlying(urlError, nil)
        let built = HARResponseBuilder.buildError(error: error, sensitiveHeaders: [])
        XCTAssertTrue(
            built.comment.contains("underlying"),
            "Error comment must contain 'underlying', got: \(built.comment)"
        )
    }
}
