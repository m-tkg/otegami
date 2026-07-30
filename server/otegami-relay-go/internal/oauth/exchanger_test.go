package oauth

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/m-tkg/otegami-relay-go/internal/api"
)

// scriptedTransport mirrors ScriptedOAuthHTTPTransport — every test
// supplies its own handler.
type scriptedTransport struct {
	handler func(url, formBody string) (int, []byte, error)
	calls   int
}

func (t *scriptedTransport) Post(_ context.Context, url, formBody string) (int, []byte, error) {
	t.calls++
	return t.handler(url, formBody)
}

func TestGoogleSuccessfulRefresh(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		if url != "https://oauth2.googleapis.com/token" {
			t.Fatalf("got url %q", url)
		}
		for _, want := range []string{"client_id=test-google-client-id", "refresh_token=stored-refresh-token", "grant_type=refresh_token"} {
			if !strings.Contains(formBody, want) {
				t.Fatalf("form body missing %q: %q", want, formBody)
			}
		}
		if strings.Contains(formBody, "client_secret") {
			t.Fatalf("client_secret must never be sent: %q", formBody)
		}
		return 200, []byte(`{"access_token":"fresh-google-token","expires_in":3600}`), nil
	}}
	exchanger := New(transport, "test-google-client-id", "")
	token, err := exchanger.AccessToken(t.Context(), api.ProviderGoogle, "stored-refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	if token != "fresh-google-token" {
		t.Fatalf("got %q", token)
	}
}

func TestMicrosoftSuccessfulRefreshRepeatsScope(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		if url != "https://login.microsoftonline.com/common/oauth2/v2.0/token" {
			t.Fatalf("got url %q", url)
		}
		for _, want := range []string{"client_id=test-ms-client-id", "refresh_token=stored-refresh-token", "scope="} {
			if !strings.Contains(formBody, want) {
				t.Fatalf("form body missing %q: %q", want, formBody)
			}
		}
		if strings.Contains(formBody, "client_secret") {
			t.Fatalf("client_secret must never be sent: %q", formBody)
		}
		return 200, []byte(`{"access_token":"fresh-ms-token","expires_in":3600}`), nil
	}}
	exchanger := New(transport, "", "test-ms-client-id")
	token, err := exchanger.AccessToken(t.Context(), api.ProviderMicrosoft, "stored-refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	if token != "fresh-ms-token" {
		t.Fatalf("got %q", token)
	}
}

func TestMissingClientIDNeverCallsTransport(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		t.Fatal("transport should never be called when no client id is configured")
		return 0, nil, nil
	}}
	exchanger := New(transport, "", "")
	_, err := exchanger.AccessToken(t.Context(), api.ProviderGoogle, "whatever")
	var missing *MissingClientIDError
	if !errors.As(err, &missing) || missing.Provider != api.ProviderGoogle {
		t.Fatalf("got %v", err)
	}
	if transport.calls != 0 {
		t.Fatal("transport was called")
	}
}

func TestInvalidGrantResponse(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		return 400, []byte(`{"error":"invalid_grant","error_description":"Token has been expired or revoked."}`), nil
	}}
	exchanger := New(transport, "cid", "")
	_, err := exchanger.AccessToken(t.Context(), api.ProviderGoogle, "dead-token")
	if !errors.Is(err, ErrInvalidGrant) {
		t.Fatalf("got %v", err)
	}
}

func TestOtherErrorResponse(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		return 429, []byte(`{"error":"rate_limited"}`), nil
	}}
	exchanger := New(transport, "cid", "")
	_, err := exchanger.AccessToken(t.Context(), api.ProviderGoogle, "token")
	var failed *TokenRequestFailedError
	if !errors.As(err, &failed) || failed.Status != 429 {
		t.Fatalf("got %v", err)
	}
}

func TestUnparseableSuccessResponse(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		return 200, []byte("not json"), nil
	}}
	exchanger := New(transport, "cid", "")
	_, err := exchanger.AccessToken(t.Context(), api.ProviderGoogle, "token")
	if !errors.Is(err, ErrInvalidResponse) {
		t.Fatalf("got %v", err)
	}
}

func TestTransportFailureIsNetworkError(t *testing.T) {
	transport := &scriptedTransport{handler: func(url, formBody string) (int, []byte, error) {
		return 0, nil, errors.New("connection refused")
	}}
	exchanger := New(transport, "cid", "")
	_, err := exchanger.AccessToken(t.Context(), api.ProviderGoogle, "token")
	var netErr *NetworkError
	if !errors.As(err, &netErr) {
		t.Fatalf("got %v", err)
	}
}

func TestFormEncodePercentEncodesPerRFC3986(t *testing.T) {
	encoded := FormEncode(map[string]string{"refresh_token": "1//abc def+ghi", "grant_type": "refresh_token"})
	if encoded != "grant_type=refresh_token&refresh_token=1%2F%2Fabc%20def%2Bghi" {
		t.Fatalf("got %q", encoded)
	}
}
