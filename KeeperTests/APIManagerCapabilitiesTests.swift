import XCTest
@testable import Keepur

final class APIManagerCapabilitiesTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        URLProtocolStub.reset()
        URLProtocol.registerClass(URLProtocolStub.self)
        BeekeeperConfig.host = "test.example.com"
        KeychainManager.token = "test-token"
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(URLProtocolStub.self)
        URLProtocolStub.reset()
        KeychainManager.token = nil
        BeekeeperConfig.host = nil
        try await super.tearDown()
    }

    func test200ReturnsArrayVerbatim() async throws {
        URLProtocolStub.nextStatusCode = 200
        URLProtocolStub.nextBody = Data(#"{"capabilities":["beekeeper","hive-a","hive-b"]}"#.utf8)
        let result = try await APIManager.fetchCapabilities()
        XCTAssertEqual(result, ["beekeeper", "hive-a", "hive-b"])
    }

    func test401ThrowsUnauthorized() async {
        URLProtocolStub.nextStatusCode = 401
        URLProtocolStub.nextBody = Data()
        do {
            _ = try await APIManager.fetchCapabilities()
            XCTFail("expected unauthorized")
        } catch APIManager.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test500ThrowsRequestFailed() async {
        URLProtocolStub.nextStatusCode = 500
        URLProtocolStub.nextBody = Data()
        do {
            _ = try await APIManager.fetchCapabilities()
            XCTFail("expected requestFailed")
        } catch APIManager.APIError.requestFailed {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingTokenThrowsUnauthorized() async {
        KeychainManager.token = nil
        do {
            _ = try await APIManager.fetchCapabilities()
            XCTFail("expected unauthorized")
        } catch APIManager.APIError.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class URLProtocolStub: URLProtocol {
    static var nextStatusCode: Int = 200
    static var nextBody: Data = Data()

    static func reset() {
        nextStatusCode = 200
        nextBody = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.nextStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.nextBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
