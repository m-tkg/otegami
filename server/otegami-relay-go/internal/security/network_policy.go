// Package security is SSRF defense for the relay's one outbound network
// primitive: opening a TCP/TLS connection to a caller-supplied
// imapHost/imapPort (mirrors the retired Swift relay's RelayNetworkPolicy;
// this port must not regress its CLAUDE-SECURITY F2 defenses).
//
// Enforced in two places, same as the retired Swift relay:
//   - POST /v1/watches (httpapi/watch_routes.go): validates both the port
//     and the resolved address, rejecting the request outright (400)
//     before anything is persisted or a connection is ever attempted.
//   - Every (re)connect (imapclient.Client.Connect, called by the watcher
//     pool on every reconnect, not just the first): re-resolves the host
//     and validates that resolved address, then connects to that literal
//     address rather than letting net.Dial resolve host/port a second
//     time internally — closing the DNS-rebinding gap the same way the
//     Swift side does.
package security

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// ValidationError mirrors RelayNetworkPolicy.ValidationError.
type ValidationError struct {
	Kind   string // "portNotAllowed" | "unresolvableHost" | "disallowedAddress"
	Port   int
	Host   string
	Reason string
}

func (e *ValidationError) Error() string {
	switch e.Kind {
	case "portNotAllowed":
		return fmt.Sprintf("port %d is not in the relay's allowed IMAP port list", e.Port)
	case "unresolvableHost":
		return fmt.Sprintf("could not resolve host %q", e.Host)
	case "disallowedAddress":
		return fmt.Sprintf("%q resolves to a disallowed address (%s)", e.Host, e.Reason)
	default:
		return "network policy validation error"
	}
}

// NetworkPolicy mirrors RelayNetworkPolicy.
type NetworkPolicy struct {
	AllowedPorts         map[int]bool
	AllowPrivateNetworks bool
}

// DefaultAllowedPorts mirrors RelayNetworkPolicy.defaultAllowedPorts.
func DefaultAllowedPorts() map[int]bool {
	return map[int]bool{143: true, 993: true}
}

// Strict mirrors RelayNetworkPolicy.strict — the production default.
func Strict() NetworkPolicy {
	return NetworkPolicy{AllowedPorts: DefaultAllowedPorts(), AllowPrivateNetworks: false}
}

// PermissiveForTesting mirrors RelayNetworkPolicy.permissiveForTesting.
func PermissiveForTesting() NetworkPolicy {
	return NetworkPolicy{AllowedPorts: DefaultAllowedPorts(), AllowPrivateNetworks: true}
}

// FromEnvironment mirrors RelayNetworkPolicy.fromEnvironment(_:).
func FromEnvironment(getenv func(string) string) NetworkPolicy {
	ports := DefaultAllowedPorts()
	if extra := getenv("RELAY_EXTRA_IMAP_PORTS"); extra != "" {
		for _, token := range strings.Split(extra, ",") {
			token = strings.TrimSpace(token)
			// strconv.Atoi (not fmt.Sscanf, which tolerates trailing
			// garbage like "993x") — matches Swift's strict Int.init.
			if value, err := strconv.Atoi(token); err == nil && value >= 1 && value <= 65535 {
				ports[value] = true
			}
		}
	}
	allowPrivateRaw := strings.ToLower(getenv("RELAY_ALLOW_PRIVATE_IMAP_HOSTS"))
	allowPrivate := allowPrivateRaw == "1" || allowPrivateRaw == "true" || allowPrivateRaw == "yes"
	return NetworkPolicy{AllowedPorts: ports, AllowPrivateNetworks: allowPrivate}
}

func (p NetworkPolicy) ValidatePort(port int) error {
	if !p.AllowedPorts[port] {
		return &ValidationError{Kind: "portNotAllowed", Port: port}
	}
	return nil
}

// ResolveAndValidate resolves host/port and validates the resolved
// address against this policy, returning the resolved net.IP so the
// caller can connect to that exact address (DNS-rebinding defense — see
// this package's doc comment).
func (p NetworkPolicy) ResolveAndValidate(host string, port int) (net.IP, error) {
	// Try parsing as a literal IP first (no DNS involved), same rationale
	// as the Swift side: avoids routing every literal IP through a
	// resolver that could behave unexpectedly for numeric addresses on
	// some platforms.
	if ip := net.ParseIP(host); ip != nil {
		if !p.AllowPrivateNetworks {
			if reason := DisallowedReason(ip); reason != "" {
				return nil, &ValidationError{Kind: "disallowedAddress", Host: host, Reason: reason}
			}
		}
		return ip, nil
	}

	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return nil, &ValidationError{Kind: "unresolvableHost", Host: host}
	}
	// Use the first resolved address, matching the Swift side's use of a
	// single `SocketAddress` from `makeAddressResolvingHost`. If it's
	// disallowed and allowPrivateNetworks is false, reject outright rather
	// than trying the next address — presenting an attacker with multiple
	// chances to sneak a private answer past validation would defeat the
	// point.
	chosen := ips[0]
	if !p.AllowPrivateNetworks {
		if reason := DisallowedReason(chosen); reason != "" {
			return nil, &ValidationError{Kind: "disallowedAddress", Host: host, Reason: reason}
		}
	}
	return chosen, nil
}

// DisallowedReason mirrors RelayNetworkPolicy.disallowedReason(for:) —
// empty string if addr is fine to connect to, otherwise a short,
// user-facing reason. Handles IPv4-mapped IPv6 (::ffff:a.b.c.d) by
// unwrapping and re-classifying as IPv4, exactly like the Swift side, so
// that representation can't bypass the IPv4 checks.
func DisallowedReason(ip net.IP) string {
	if v4 := ip.To4(); v4 != nil {
		return disallowedReasonIPv4(v4)
	}
	return disallowedReasonIPv6(ip.To16())
}

func disallowedReasonIPv4(b net.IP) string {
	a, bb := b[0], b[1]
	switch {
	case a == 0:
		return "unspecified/\"this network\" (0.0.0.0/8)"
	case a == 127:
		return "loopback (127.0.0.0/8)"
	case a == 10:
		return "private (RFC1918 10.0.0.0/8)"
	case a == 172 && bb >= 16 && bb <= 31:
		return "private (RFC1918 172.16.0.0/12)"
	case a == 192 && bb == 168:
		return "private (RFC1918 192.168.0.0/16)"
	case a == 169 && bb == 254:
		return "link-local (169.254.0.0/16)"
	case a == 100 && bb >= 64 && bb <= 127:
		return "carrier-grade NAT (100.64.0.0/10)"
	case a >= 224:
		return fmt.Sprintf("multicast/reserved (%d.0.0.0/4)", a)
	default:
		return ""
	}
}

func disallowedReasonIPv6(b net.IP) string {
	if b == nil {
		return "unresolvable IPv6 address"
	}
	allZero := true
	for _, x := range b {
		if x != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return "unspecified (::)"
	}
	isLoopback := true
	for i := 0; i < 15; i++ {
		if b[i] != 0 {
			isLoopback = false
			break
		}
	}
	if isLoopback && b[15] == 1 {
		return "loopback (::1)"
	}
	// IPv4-mapped (::ffff:a.b.c.d) — unwrap and re-classify as IPv4, same
	// as the Swift side, so an attacker can't smuggle a private IPv4
	// address past the IPv6 branch just by writing it in mapped form.
	isMapped := true
	for i := 0; i < 10; i++ {
		if b[i] != 0 {
			isMapped = false
			break
		}
	}
	if isMapped && b[10] == 0xFF && b[11] == 0xFF {
		return disallowedReasonIPv4(net.IPv4(b[12], b[13], b[14], b[15]).To4())
	}
	if b[0] == 0xFE && (b[1]&0xC0) == 0x80 {
		return "link-local (fe80::/10)"
	}
	if (b[0] & 0xFE) == 0xFC {
		return "unique local (fc00::/7)"
	}
	if b[0] == 0xFF {
		return "multicast (ff00::/8)"
	}
	return ""
}
