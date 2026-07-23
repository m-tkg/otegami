import Hummingbird
import HummingbirdTesting
import Testing

@testable import OtegamiRelay

@Suite("Health endpoint")
struct HealthTests {
    @Test("GET /health returns ok")
    func healthReturnsOk() async throws {
        let router = buildRouter()
        let app = Application(router: router)
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }
}
