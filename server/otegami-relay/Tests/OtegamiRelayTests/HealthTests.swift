import Hummingbird
import HummingbirdTesting
import Testing

@testable import OtegamiRelay

@Suite("Health endpoint")
struct HealthTests {
    @Test("GET /health returns ok")
    func healthReturnsOk() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(uri: "/health", method: .get) { response in
                    #expect(String(buffer: response.body) == "ok")
                }
            }
        }
    }
}
