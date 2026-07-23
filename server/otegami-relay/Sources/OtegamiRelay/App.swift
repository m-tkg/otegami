import Hummingbird

/// Builds the router for the relay's HTTP API. Separated from `main` so
/// tests can exercise it without binding a real socket.
func buildRouter() -> Router<BasicRequestContext> {
    let router = Router()
    router.get("/health") { _, _ in
        "ok"
    }
    return router
}

@main
struct OtegamiRelay {
    static func main() async throws {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: 8080))
        )
        try await app.runService()
    }
}
