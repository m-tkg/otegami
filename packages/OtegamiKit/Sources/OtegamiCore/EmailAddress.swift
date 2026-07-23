/// A single email address, optionally with a display name (e.g. from a
/// `From:` or `To:` header).
public struct EmailAddress: Codable, Hashable, Sendable {
    /// The display name, e.g. "Jane Doe" in `Jane Doe <jane@example.com>`.
    /// `nil` when the header only carries a bare address.
    public var name: String?

    /// The address itself, e.g. "jane@example.com".
    public var address: String

    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }
}

extension EmailAddress: CustomStringConvertible {
    public var description: String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }
}
