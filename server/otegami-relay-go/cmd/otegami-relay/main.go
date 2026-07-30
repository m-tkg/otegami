// Command otegami-relay is the Go port of the otegami push relay server —
// mirrors App.swift (server/otegami-relay/Sources/OtegamiRelay/App.swift):
// read config from the environment, open the SQLite store, pick the push
// sender (real APNs iff every APNS_* var is set, console fallback
// otherwise), start the watcher pool alongside the HTTP API, and shut both
// down gracefully on SIGTERM/SIGINT.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/m-tkg/otegami-relay-go/internal/config"
	"github.com/m-tkg/otegami-relay-go/internal/cryptox"
	"github.com/m-tkg/otegami-relay-go/internal/httpapi"
	"github.com/m-tkg/otegami-relay-go/internal/oauth"
	"github.com/m-tkg/otegami-relay-go/internal/push"
	"github.com/m-tkg/otegami-relay-go/internal/store"
	"github.com/m-tkg/otegami-relay-go/internal/watcher"
)

// makePushSender mirrors App.swift's makePushSender: real APNs if every
// APNS_* env var is configured and the key file is readable, otherwise
// ConsoleSender.
func makePushSender(cfg config.Config, logger *slog.Logger) push.Sender {
	if cfg.APNs == nil {
		logger.Warn("APNS_* env vars not fully set; falling back to ConsoleSender (no real push will be sent)")
		return &push.ConsoleSender{Logger: logger}
	}
	keyPEM, err := os.ReadFile(cfg.APNs.KeyPath)
	if err != nil {
		logger.Warn("could not read APNS_KEY_PATH; falling back to ConsoleSender", "path", cfg.APNs.KeyPath)
		return &push.ConsoleSender{Logger: logger}
	}
	return push.NewAPNsSender(push.APNsConfig{
		PrivateKeyPEM: string(keyPEM),
		KeyID:         cfg.APNs.KeyID,
		TeamID:        cfg.APNs.TeamID,
		BundleID:      cfg.APNs.BundleID,
	}, nil, logger)
}

func run() error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg, err := config.FromOSEnvironment()
	if err != nil {
		logger.Error("configuration error", "error", err.Error())
		return err
	}

	// CLAUDE-SECURITY F2: surfaced once at startup too (not just on every
	// unauthenticated POST /v1/devices) so it's visible even on a quiet
	// relay nobody's actively probing yet.
	if cfg.DeviceRegistrationSecret == "" {
		logger.Warn("RELAY_DEVICE_REGISTRATION_SECRET is not set — POST /v1/devices is open to " +
			"anyone who can reach this relay. See docs/relay-deployment.md.")
	}
	if cfg.NetworkPolicy.AllowPrivateNetworks {
		logger.Warn("RELAY_ALLOW_PRIVATE_IMAP_HOSTS is set — this relay will connect to " +
			"loopback/link-local/private IMAP hosts requested by any authenticated watch. " +
			"Only enable this if the relay's own network is trusted.")
	}

	crypto, err := cryptox.NewFromBase64Key(cfg.MasterKeyBase64)
	if err != nil {
		logger.Error("RELAY_MASTER_KEY is invalid", "error", err.Error())
		return err
	}
	relayStore, err := store.Open(cfg.DatabasePath, crypto)
	if err != nil {
		logger.Error("could not open the relay database", "path", cfg.DatabasePath, "error", err.Error())
		return err
	}
	defer relayStore.Close()

	pushSender := makePushSender(cfg, logger)
	if cfg.GoogleOAuthClientID == "" && cfg.MicrosoftOAuthClientID == "" {
		logger.Info("RELAY_GOOGLE_CLIENT_ID/RELAY_MICROSOFT_CLIENT_ID are not set — an .oauth " +
			"watch (Gmail/Outlook) can be created but will never authenticate. See " +
			"docs/relay-deployment.md.")
	}
	exchanger := oauth.New(oauth.NewHTTPTransport(), cfg.GoogleOAuthClientID, cfg.MicrosoftOAuthClientID)

	pool := watcher.New(relayStore, pushSender, logger, watcher.Options{
		NetworkPolicy: cfg.NetworkPolicy,
		OAuth:         exchanger,
	})

	router := httpapi.NewRouter(relayStore, pool, cfg.NetworkPolicy, cfg.DeviceRegistrationSecret, logger)
	server := &http.Server{
		Addr:              fmt.Sprintf("0.0.0.0:%d", cfg.Port),
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	poolDone := make(chan struct{})
	go func() {
		defer close(poolDone)
		_ = pool.Run(ctx)
	}()

	serverErr := make(chan error, 1)
	go func() {
		logger.Info("otegami-relay listening", "addr", server.Addr)
		serverErr <- server.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		logger.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		<-poolDone
		return nil
	case err := <-serverErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("HTTP server failed", "error", err.Error())
			stop()
			<-poolDone
			return err
		}
		<-poolDone
		return nil
	}
}

func main() {
	if err := run(); err != nil {
		os.Exit(1)
	}
}
