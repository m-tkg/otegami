import Testing

@testable import OtegamiRelay

/// Unit-level coverage of `RelayNetworkPolicy`'s IP classification
/// (CLAUDE-SECURITY F2) — `WatchRoutesTests` exercises the same policy
/// through the actual HTTP route; these tests isolate the classification
/// logic itself, including the IPv4-mapped-IPv6 unwrapping that a naive
/// implementation could miss.
@Suite("RelayNetworkPolicy")
struct RelayNetworkPolicyTests {
    @Test(
        "strict policy rejects private/loopback/link-local/multicast/unspecified addresses",
        arguments: [
            "127.0.0.1",
            "10.1.2.3",
            "172.31.255.255",
            "192.168.0.1",
            "169.254.0.1",
            "0.0.0.0",
            "224.0.0.1",
            "255.255.255.255",
            "::1",
            "::",
            "fe80::1",
            "fc00::1",
            "ff02::1",
            "::ffff:192.168.1.1", // IPv4-mapped private address must not bypass the IPv4 check
        ]
    )
    func strictRejectsDisallowedAddresses(host: String) throws {
        #expect(throws: RelayNetworkPolicy.ValidationError.self) {
            _ = try RelayNetworkPolicy.strict.resolveAndValidate(host: host, port: 993)
        }
    }

    @Test(
        "strict policy accepts public-looking literal addresses",
        arguments: [
            "203.0.113.10", // TEST-NET-3
            "198.51.100.10", // TEST-NET-2
            "8.8.8.8",
            "2606:4700:4700::1111",
        ]
    )
    func strictAcceptsPublicAddresses(host: String) throws {
        #expect(throws: Never.self) {
            _ = try RelayNetworkPolicy.strict.resolveAndValidate(host: host, port: 993)
        }
    }

    @Test("permissiveForTesting accepts loopback")
    func permissiveAcceptsLoopback() throws {
        #expect(throws: Never.self) {
            _ = try RelayNetworkPolicy.permissiveForTesting.resolveAndValidate(host: "127.0.0.1", port: 993)
        }
    }

    @Test("port allowlist accepts 143/993 and rejects anything else by default")
    func portAllowlist() {
        #expect(throws: Never.self) { try RelayNetworkPolicy.strict.validatePort(143) }
        #expect(throws: Never.self) { try RelayNetworkPolicy.strict.validatePort(993) }
        #expect(throws: RelayNetworkPolicy.ValidationError.self) { try RelayNetworkPolicy.strict.validatePort(6379) }
        #expect(throws: RelayNetworkPolicy.ValidationError.self) { try RelayNetworkPolicy.strict.validatePort(80) }
    }

    @Test("RELAY_EXTRA_IMAP_PORTS widens the port allowlist")
    func extraPortsFromEnvironment() throws {
        let policy = RelayNetworkPolicy.fromEnvironment(["RELAY_EXTRA_IMAP_PORTS": "1143, 2143"])
        #expect(policy.allowedPorts.contains(143))
        #expect(policy.allowedPorts.contains(993))
        #expect(policy.allowedPorts.contains(1143))
        #expect(policy.allowedPorts.contains(2143))
        try policy.validatePort(1143)
    }

    @Test("RELAY_ALLOW_PRIVATE_IMAP_HOSTS opts into allowing private/loopback hosts")
    func allowPrivateFromEnvironment() throws {
        let policy = RelayNetworkPolicy.fromEnvironment(["RELAY_ALLOW_PRIVATE_IMAP_HOSTS": "1"])
        #expect(policy.allowPrivateNetworks)
        _ = try policy.resolveAndValidate(host: "127.0.0.1", port: 993)
    }

    @Test("a syntactically invalid host is rejected without needing a network round trip")
    func unresolvableHostRejected() {
        // Contains a space — `getaddrinfo` rejects this locally (invalid
        // hostname syntax) rather than issuing a DNS query, so this test
        // doesn't depend on network access or DNS behavior in CI/sandboxed
        // environments the way a nonexistent-but-syntactically-valid
        // hostname would.
        #expect(throws: RelayNetworkPolicy.ValidationError.self) {
            _ = try RelayNetworkPolicy.strict.resolveAndValidate(host: "not a valid host", port: 993)
        }
    }
}
