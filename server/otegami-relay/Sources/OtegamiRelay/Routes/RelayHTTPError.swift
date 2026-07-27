import Hummingbird
import HTTPTypes
import OtegamiRelayAPI

/// Every non-2xx response from `/v1/*` uses `RelayErrorResponse`'s shape
/// (shared with the app via `OtegamiRelayAPI`) instead of Hummingbird's
/// built-in `HTTPError` body format, so the app's error handling has one
/// JSON shape to decode regardless of which route failed.
struct RelayHTTPError: Error, HTTPResponseError {
    let status: HTTPResponse.Status
    let body: RelayErrorResponse

    init(_ status: HTTPResponse.Status, error: String, message: String) {
        self.status = status
        self.body = RelayErrorResponse(error: error, message: message)
    }

    static func unauthorized(_ message: String = "invalid or missing device credentials") -> RelayHTTPError {
        RelayHTTPError(.unauthorized, error: "unauthorized", message: message)
    }

    static func notFound(_ message: String) -> RelayHTTPError {
        RelayHTTPError(.notFound, error: "not_found", message: message)
    }

    static func badRequest(_ message: String) -> RelayHTTPError {
        RelayHTTPError(.badRequest, error: "bad_request", message: message)
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        var response = try context.responseEncoder.encode(body, from: request, context: context)
        response.status = status
        return response
    }
}

// Lets route handlers return these DTOs directly and have Hummingbird
// JSON-encode them (see `ResponseEncodable`'s doc comment in
// hummingbird's own source: any `Encodable` needs an explicit opt-in
// conformance to get response-generation "for free"). `OtegamiRelayAPI`
// itself stays Hummingbird-free (Linux-compatible, shared with the app),
// so these conformances live here instead.
extension RegisterDeviceResponse: @retroactive ResponseEncodable {}
extension WatchResponse: @retroactive ResponseEncodable {}
extension ListWatchesResponse: @retroactive ResponseEncodable {}
