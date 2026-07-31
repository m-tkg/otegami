#!/usr/bin/env bash
# M9: end-to-end verification of otegami-relay's IDLE watch pipeline
# against a *real* IMAP server (dev/mailstack's Dovecot) — not a fake one.
# Confirms the whole path actually works together: go run ./cmd/otegami-relay
# -> POST /v1/devices -> POST /v1/watches -> the relay opens a real IMAP
# IDLE connection to Dovecot -> a new message injected via `doveadm save`
# wakes that IDLE -> ConsolePushSender logs the push it would have sent,
# with the right accountId. (FakeIMAPServer-driven unit coverage of the
# IDLE/polling logic itself lives in
# server/otegami-relay-go/internal/watcher/pool_test.go; this
# script is the "does it work against a real server" check the plan calls
# for.)
#
# Usage: scripts/verify-relay.sh
# Env:
#   RELAY_PORT   Port the relay listens on for this run (default: 8091)
#   TIMEOUT_SECS How long to wait for the watch to connect / for the push
#                to fire before giving up (default: 30 each)
#
# CLAUDE-SECURITY F2 note: this script's relay instance is started with
# RELAY_ALLOW_PRIVATE_IMAP_HOSTS=1 and RELAY_EXTRA_IMAP_PORTS=1143, since it
# deliberately points a watch at dev/mailstack's Dovecot on
# localhost:1143 — a loopback host and nonstandard port that
# RelayNetworkPolicy.strict (the production default) rejects on purpose.
# That's fine here: this whole script only ever talks to a relay it just
# started on the same machine, not the internet-facing deployment the
# strict default protects.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RELAY_PORT="${RELAY_PORT:-8091}"
TIMEOUT_SECS="${TIMEOUT_SECS:-30}"
RELAY_DIR="server/otegami-relay-go"
LOG_FILE="$(mktemp -t otegami-relay-verify.XXXXXX.log)"
DB_FILE="$(mktemp -t otegami-relay-verify.XXXXXX.sqlite)"
rm -f "$DB_FILE" # OtegamiRelay creates it; just need a unique path here
RELAY_PID=""

cleanup() {
  if [[ -n "$RELAY_PID" ]] && kill -0 "$RELAY_PID" 2>/dev/null; then
    echo "==> stopping relay (pid $RELAY_PID)"
    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  echo "==> restoring standard mailstack fixtures (the injected test message shouldn't linger)"
  make mailstack-seed >/dev/null 2>&1 || true
  rm -f "$DB_FILE"
  echo "==> full relay log: $LOG_FILE"
}
trap cleanup EXIT

echo "==> starting dev mailstack"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> building otegami-relay-go"
(cd "$RELAY_DIR" && go build ./...)

echo "==> starting otegami-relay on port $RELAY_PORT (log: $LOG_FILE)"
RELAY_MASTER_KEY="$(openssl rand -base64 32)"
export RELAY_MASTER_KEY
(
  cd "$RELAY_DIR" && \
  RELAY_PORT="$RELAY_PORT" RELAY_DATABASE_PATH="$DB_FILE" \
  RELAY_ALLOW_PRIVATE_IMAP_HOSTS=1 RELAY_EXTRA_IMAP_PORTS=1143 \
  go run ./cmd/otegami-relay
) >"$LOG_FILE" 2>&1 &
RELAY_PID=$!

echo "==> waiting for the relay to start listening"
deadline=$((SECONDS + TIMEOUT_SECS))
until curl -sf "http://localhost:$RELAY_PORT/health" >/dev/null 2>&1; do
  if [[ $SECONDS -ge $deadline ]]; then
    echo "error: relay never started listening on port $RELAY_PORT" >&2
    echo "----- log -----"; cat "$LOG_FILE"; echo "----------------"
    exit 1
  fi
  sleep 1
done
echo "    relay is up"

echo "==> registering a device"
REGISTER_BODY='{"apnsToken":"verify-relay-test-token","environment":"sandbox"}'
REGISTER_RESPONSE="$(curl -sf -X POST "http://localhost:$RELAY_PORT/v1/devices" \
  -H 'Content-Type: application/json' -d "$REGISTER_BODY")"
DEVICE_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["deviceSecret"])' <<<"$REGISTER_RESPONSE")"
echo "    registered (response: $REGISTER_RESPONSE)"

ACCOUNT_ID="verify-relay-account-$$"
echo "==> creating a watch on Dovecot's test1@otegami.test INBOX (accountId=$ACCOUNT_ID)"
WATCH_BODY=$(python3 - <<PY
import json
print(json.dumps({
    "accountId": "$ACCOUNT_ID",
    "imapHost": "localhost",
    "imapPort": 1143,
    "imapUseTLS": False,
    "imapUsername": "test1@otegami.test",
    "auth": {"type": "password", "secret": "test1234"},
    "mailbox": "INBOX",
}))
PY
)
curl -sf -X POST "http://localhost:$RELAY_PORT/v1/watches" \
  -H "Authorization: Bearer $DEVICE_SECRET" \
  -H 'Content-Type: application/json' \
  -d "$WATCH_BODY" >/dev/null
echo "    watch created"

echo "==> waiting for the watch to connect and enter IDLE (accountId=$ACCOUNT_ID in the log)"
deadline=$((SECONDS + TIMEOUT_SECS))
until grep -q "watch connected" "$LOG_FILE" 2>/dev/null; do
  if [[ $SECONDS -ge $deadline ]]; then
    echo "error: watch never logged 'watch connected' within ${TIMEOUT_SECS}s" >&2
    echo "----- log -----"; cat "$LOG_FILE"; echo "----------------"
    exit 1
  fi
  sleep 1
done
echo "    watch connected — should be IDLE-ing against Dovecot now"
# A little extra headroom: the log line lands right as IDLE is issued, but
# there's an inherent (small) race between "issued IDLE" and "server is
# actually ready to notice a concurrent APPEND" — this is the real-server
# equivalent of FakeIMAPServer's "let the loop connect and establish its
# baseline" comment in WatcherPoolTests.swift.
sleep 2

echo "==> injecting a new message via doveadm (simulating another client's delivery)"
docker compose -f dev/mailstack/compose.yml exec -T dovecot \
  doveadm save -u test1@otegami.test -m INBOX \
  <<'EOF'
From: verify-relay@otegami.test
To: test1@otegami.test
Subject: otegami-relay verify-relay.sh probe
Date: Mon, 1 Jan 2024 00:00:00 +0000
Message-ID: <verify-relay-probe@otegami.test>
Content-Type: text/plain; charset=utf-8

This message exists only to wake an IDLE connection during
scripts/verify-relay.sh; it is not a real Dovecot fixture.
EOF
echo "    message injected"

echo "==> waiting for the push to fire (ConsolePushSender log line for accountId=$ACCOUNT_ID)"
# `accountId=` only ever appears in ConsolePushSender's/APNsSender's own
# log line (WatcherPool's "watch connected"/reconnect logs key on watchId,
# not accountId) — so this alone is enough to confirm the push fired for
# *this* watch specifically, not just that some push fired.
deadline=$((SECONDS + TIMEOUT_SECS))
until grep -q "accountId=$ACCOUNT_ID" "$LOG_FILE" 2>/dev/null; do
  if [[ $SECONDS -ge $deadline ]]; then
    echo "error: no push fired for accountId=$ACCOUNT_ID within ${TIMEOUT_SECS}s" >&2
    echo "----- log -----"; cat "$LOG_FILE"; echo "----------------"
    exit 1
  fi
  sleep 1
done
echo
echo "✔ PASS: real Dovecot IDLE -> new mail -> push fired, end to end."
grep "accountId=$ACCOUNT_ID" "$LOG_FILE" | tail -1
