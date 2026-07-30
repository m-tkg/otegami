import Foundation
import NIOCore

/// SSRF defense for the relay's one outbound network primitive: opening a
/// TCP/TLS connection to an operator-*and-caller*-supplied `imapHost`/
/// `imapPort` (CLAUDE-SECURITY F2, HIGH — see
/// `CLAUDE-SECURITY-20260729-134850/CLAUDE-SECURITY-RESULTS.md`). Before
/// this fix, `POST /v1/watches`' JSON body drove `ClientBootstrap.connect`
/// with no validation at all, and `POST /v1/devices` (which hands out the
/// bearer credential every other route requires) was itself unauthenticated
/// — so *any* network client that could reach the relay's HTTP port could
/// make it dial an arbitrary host/port (loopback, Docker bridge, LAN,
/// cloud metadata endpoints), amplified by `MinimalIMAPClient`'s CRLF
/// injection (F3) into a blind protocol-smuggling primitive against
/// whatever answered.
///
/// Enforced in two places, deliberately with different scopes:
/// - **`POST /v1/watches`** (`WatchRoutes`): validates *both* the port
///   (against `allowedPorts`) and the resolved address (against
///   `allowPrivateNetworks`), rejecting the request outright (400) before
///   anything is persisted or a connection is ever attempted.
/// - **Every (re)connect** (`MinimalIMAPClient.connect`, called by
///   `WatcherPool.runWatchLoop` on every reconnect, not just the first):
///   re-resolves the host and validates *that* resolved address, then
///   connects to that literal `SocketAddress` rather than letting NIO
///   resolve `host`/`port` a second time internally. This closes the DNS
///   rebinding gap: even if a hostname's DNS answer changes between watch
///   creation and a much later reconnect (an operator's own host, or a
///   compromised one), each connection attempt is checked against its own
///   fresh resolution, and there's no time-of-check/time-of-use window
///   between "resolve" and "connect" *within* a single attempt — both use
///   the same resolved address.
///
/// Only the *address* is re-checked at connect time, not the port —
/// `WatchRecord.imapPort` is fixed at creation and doesn't change via DNS,
/// so re-validating it on every reconnect would buy nothing and would
/// break `WatcherPoolTests`' `FakeIMAPServer` (bound to an OS-assigned
/// ephemeral port) on every single reconnect, for no security benefit.
struct RelayNetworkPolicy: Sendable {
    enum ValidationError: Error, CustomStringConvertible, Equatable {
        case portNotAllowed(Int)
        case unresolvableHost(String)
        case disallowedAddress(host: String, reason: String)

        var description: String {
            switch self {
            case .portNotAllowed(let port):
                "port \(port) is not in the relay's allowed IMAP port list"
            case .unresolvableHost(let host):
                "could not resolve host \"\(host)\""
            case .disallowedAddress(let host, let reason):
                "\"\(host)\" resolves to a disallowed address (\(reason))"
            }
        }
    }

    /// Ports `POST /v1/watches` will accept. Standard IMAP (143/993) by
    /// default; an operator can widen this with `RELAY_EXTRA_IMAP_PORTS`
    /// (comma-separated) for a nonstandard deployment (e.g. a port-
    /// forwarded home server) — see docs/relay-deployment.md.
    var allowedPorts: Set<Int>

    /// When `false` (the production default), a resolved address that's
    /// loopback, link-local (169.254.0.0/16, fe80::/10), private
    /// (RFC1918, ULA fc00::/7), multicast, or unspecified (0.0.0.0/::) is
    /// rejected. Operators whose IMAP server genuinely lives on a private
    /// network the relay can reach (e.g. a home Dovecot instance on the
    /// same LAN/Docker network — a real, supported deployment shape per
    /// docs/relay-deployment.md's "宅内サーバー" example) must opt in
    /// explicitly via `RELAY_ALLOW_PRIVATE_IMAP_HOSTS=1`.
    var allowPrivateNetworks: Bool

    static let defaultAllowedPorts: Set<Int> = [143, 993]

    /// Production default: standard IMAP ports only, private/loopback
    /// targets rejected.
    static let strict = RelayNetworkPolicy(allowedPorts: defaultAllowedPorts, allowPrivateNetworks: false)

    /// `WatcherPoolTests`/`WatcherPoolRealDovecotIntegrationTests` dial
    /// `FakeIMAPServer`/dev-mailstack Dovecot directly on loopback — a
    /// local test process talking to itself on an OS-assigned port, not an
    /// instance of the threat this policy defends against. `allowedPorts`
    /// is irrelevant at connect time (see this type's doc comment); it's
    /// populated here only for symmetry with `.strict`.
    static let permissiveForTesting = RelayNetworkPolicy(allowedPorts: defaultAllowedPorts, allowPrivateNetworks: true)

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RelayNetworkPolicy {
        var ports = defaultAllowedPorts
        if let extra = environment["RELAY_EXTRA_IMAP_PORTS"] {
            for token in extra.split(separator: ",") {
                if let value = Int(token.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) {
                    ports.insert(value)
                }
            }
        }
        let allowPrivateRaw = (environment["RELAY_ALLOW_PRIVATE_IMAP_HOSTS"] ?? "").lowercased()
        let allowPrivate = ["1", "true", "yes"].contains(allowPrivateRaw)
        return RelayNetworkPolicy(allowedPorts: ports, allowPrivateNetworks: allowPrivate)
    }

    func validatePort(_ port: Int) throws {
        guard allowedPorts.contains(port) else { throw ValidationError.portNotAllowed(port) }
    }

    /// Resolves `host`/`port` and validates the resolved address against
    /// this policy, returning the resolved `SocketAddress` so the caller
    /// can connect to that *exact* address (see this type's doc comment on
    /// why that matters for DNS rebinding).
    ///
    /// - Warning: Blocking (`getaddrinfo` via
    ///   `SocketAddress.makeAddressResolvingHost`) — callers must not call
    ///   this from an `EventLoop` thread. Both call sites (`WatchRoutes`'
    ///   async route handler, `MinimalIMAPClient.connect`'s async function)
    ///   run on the Swift concurrency thread pool, not an `EventLoop`
    ///   thread, so a brief block here is acceptable — this is a low-
    ///   volume, human-triggered operation (watch creation, IMAP
    ///   reconnect), not a hot path.
    func resolveAndValidate(host: String, port: Int) throws -> SocketAddress {
        // `host` is very often already a literal IP (self-hosted setups,
        // or a hostname's earlier resolution result being re-validated) —
        // try parsing it directly first (`inet_pton` under the hood, no
        // syscall/DNS involved) before falling back to
        // `makeAddressResolvingHost`'s real `getaddrinfo`-based DNS
        // resolution for genuine hostnames. This isn't just an
        // optimization: `getaddrinfo` with no hints applies glibc's
        // `AI_ADDRCONFIG`-style family filtering even to numeric
        // addresses on some platforms/configurations (observed
        // firsthand — a Linux container with no non-loopback IPv6
        // interface configured fails to "resolve" a perfectly valid
        // literal public IPv6 address through `getaddrinfo`), so routing
        // every literal IP through DNS resolution risks spurious
        // `unresolvableHost` failures unrelated to whether the address
        // itself is fine to connect to.
        let address: SocketAddress
        if let literal = try? SocketAddress(ipAddress: host, port: port) {
            address = literal
        } else {
            do {
                address = try SocketAddress.makeAddressResolvingHost(host, port: port)
            } catch {
                throw ValidationError.unresolvableHost(host)
            }
        }
        if !allowPrivateNetworks, let reason = Self.disallowedReason(for: address) {
            throw ValidationError.disallowedAddress(host: host, reason: reason)
        }
        return address
    }

    /// `nil` if `address` is fine to connect to; otherwise a short,
    /// user-facing reason.
    static func disallowedReason(for address: SocketAddress) -> String? {
        switch address {
        case .v4(let v4):
            var addr = v4.address.sin_addr
            return disallowedReasonIPv4(&addr)
        case .v6(let v6):
            var addr = v6.address.sin6_addr
            return disallowedReasonIPv6(&addr)
        case .unixDomainSocket:
            // `makeAddressResolvingHost` never produces this case; only
            // reachable if a future caller constructs one directly.
            return "unix domain socket"
        }
    }

    private static func disallowedReasonIPv4(_ addr: inout in_addr) -> String? {
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        precondition(bytes.count == 4)
        let a = bytes[0], b = bytes[1]
        if a == 0 { return "unspecified/\"this network\" (0.0.0.0/8)" }
        if a == 127 { return "loopback (127.0.0.0/8)" }
        if a == 10 { return "private (RFC1918 10.0.0.0/8)" }
        if a == 172, (16...31).contains(b) { return "private (RFC1918 172.16.0.0/12)" }
        if a == 192, b == 168 { return "private (RFC1918 192.168.0.0/16)" }
        if a == 169, b == 254 { return "link-local (169.254.0.0/16)" }
        // RFC 6598 carrier-grade NAT — not one of the report's named
        // ranges, but shares the same "not actually reachable from the
        // public internet, likely internal" reasoning; included as
        // defense in depth.
        if a == 100, (64...127).contains(b) { return "carrier-grade NAT (100.64.0.0/10)" }
        // 224-239 multicast, 240-255 reserved/broadcast — neither is ever
        // a legitimate unicast IMAP target.
        if a >= 224 { return "multicast/reserved (\(a).0.0.0/4)" }
        return nil
    }

    private static func disallowedReasonIPv6(_ addr: inout in6_addr) -> String? {
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        precondition(bytes.count == 16)
        if bytes.allSatisfy({ $0 == 0 }) { return "unspecified (::)" }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return "loopback (::1)" }
        // IPv4-mapped (::ffff:a.b.c.d) — unwrap and re-classify as IPv4 so
        // an attacker can't smuggle a private IPv4 address past the IPv6
        // branch just by writing it in mapped form.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            var v4 = in_addr()
            withUnsafeMutableBytes(of: &v4) { dest in
                for index in 0..<4 { dest[index] = bytes[12 + index] }
            }
            return disallowedReasonIPv4(&v4)
        }
        if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return "link-local (fe80::/10)" }
        if (bytes[0] & 0xFE) == 0xFC { return "unique local (fc00::/7)" }
        if bytes[0] == 0xFF { return "multicast (ff00::/8)" }
        return nil
    }
}
