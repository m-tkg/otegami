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

extension EmailAddress {
    /// Parses a comma-separated address list, accepting either a bare
    /// address (`"a@example.com"`) or a `"Name <a@example.com>"` form —
    /// matches what `EmailAddress.description` (used to prefill a reply's
    /// To/Cc fields) produces, so round-tripping through this field doesn't
    /// lose the display name.
    public static func parseAddresses(_ text: String) -> [EmailAddress] {
        text.split(separator: ",").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
                let name = trimmed[trimmed.startIndex..<open].trimmingCharacters(in: .whitespaces)
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { return nil }
                return EmailAddress(name: name.isEmpty ? nil : name, address: address)
            }
            return EmailAddress(address: trimmed)
        }
    }
}
