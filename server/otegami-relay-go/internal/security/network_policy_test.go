package security

import "testing"

// Mirrors the retired Swift relay's
// WatchRoutesTests.createWatchRejectsPrivateHost arguments.
func TestStrictRejectsPrivateLoopbackLinkLocalHosts(t *testing.T) {
	hosts := []string{
		"127.0.0.1",        // loopback
		"10.0.0.5",         // RFC1918
		"172.16.0.1",       // RFC1918
		"192.168.1.1",      // RFC1918
		"169.254.1.1",      // link-local
		"0.0.0.0",          // unspecified
		"::1",              // IPv6 loopback
		"fe80::1",          // IPv6 link-local
		"fc00::1",          // IPv6 unique local
		"::ffff:127.0.0.1", // IPv4-mapped IPv6 loopback (must not bypass the IPv4 check)
	}
	policy := Strict()
	for _, host := range hosts {
		t.Run(host, func(t *testing.T) {
			if _, err := policy.ResolveAndValidate(host, 993); err == nil {
				t.Fatalf("expected %q to be rejected", host)
			}
		})
	}
}

func TestStrictAcceptsPublicHost(t *testing.T) {
	policy := Strict()
	if _, err := policy.ResolveAndValidate("203.0.113.10", 993); err != nil {
		t.Fatalf("expected TEST-NET-3 address to be accepted, got %v", err)
	}
}

func TestPermissiveForTestingAcceptsLoopback(t *testing.T) {
	policy := PermissiveForTesting()
	if _, err := policy.ResolveAndValidate("127.0.0.1", 993); err != nil {
		t.Fatalf("expected loopback to be accepted under permissiveForTesting, got %v", err)
	}
}

func TestValidatePortRejectsDisallowedPort(t *testing.T) {
	policy := Strict()
	if err := policy.ValidatePort(6379); err == nil {
		t.Fatal("expected 6379 to be rejected")
	}
	if err := policy.ValidatePort(993); err != nil {
		t.Fatalf("expected 993 to be allowed, got %v", err)
	}
	if err := policy.ValidatePort(143); err != nil {
		t.Fatalf("expected 143 to be allowed, got %v", err)
	}
}

func TestFromEnvironmentExtraPorts(t *testing.T) {
	env := map[string]string{
		"RELAY_EXTRA_IMAP_PORTS":         "1143, 2143",
		"RELAY_ALLOW_PRIVATE_IMAP_HOSTS": "1",
	}
	policy := FromEnvironment(func(k string) string { return env[k] })
	if err := policy.ValidatePort(1143); err != nil {
		t.Fatalf("expected 1143 to be allowed, got %v", err)
	}
	if err := policy.ValidatePort(2143); err != nil {
		t.Fatalf("expected 2143 to be allowed, got %v", err)
	}
	if !policy.AllowPrivateNetworks {
		t.Fatal("expected AllowPrivateNetworks to be true")
	}
}

func TestFromEnvironmentDefaults(t *testing.T) {
	policy := FromEnvironment(func(string) string { return "" })
	if err := policy.ValidatePort(143); err != nil {
		t.Fatal(err)
	}
	if err := policy.ValidatePort(993); err != nil {
		t.Fatal(err)
	}
	if err := policy.ValidatePort(1143); err == nil {
		t.Fatal("expected 1143 to be rejected by default")
	}
	if policy.AllowPrivateNetworks {
		t.Fatal("expected AllowPrivateNetworks to default to false")
	}
}
