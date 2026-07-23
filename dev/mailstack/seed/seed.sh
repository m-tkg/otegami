#!/usr/bin/env bash
# Loads the sample .eml fixtures in seed/fixtures/ into the dev mail stack's
# Dovecot INBOX, using `doveadm save` (the dovecot/dovecot image ships no
# shell, so this pipes each fixture's content through `docker compose exec`
# rather than copying files into a Maildir directly).
#
# Idempotent: each seeded user's INBOX is emptied (`doveadm expunge ... all`)
# before re-seeding, so running this repeatedly (e.g. once per verification
# run) reproduces the same fixed set of messages instead of accumulating
# duplicates. `doveadm expunge` on a mailbox that doesn't exist yet (first
# run against a fresh volume) exits non-zero; that's expected and harmless,
# hence `|| true`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAILSTACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

cd "$MAILSTACK_DIR"

reset_inbox() {
  local user="$1"
  echo "==> clearing $user INBOX (idempotent reseed)"
  docker compose exec -T dovecot doveadm expunge -u "$user" mailbox INBOX all || true
}

seed_message() {
  local user="$1"
  local file="$2"
  echo "==> seeding $(basename "$file") into $user INBOX"
  docker compose exec -T dovecot doveadm save -u "$user" -m INBOX < "$file"
}

reset_inbox "test1@otegami.test"
reset_inbox "test2@otegami.test"

seed_message "test1@otegami.test" "$FIXTURES_DIR/01-welcome.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/02-thread-original.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/03-thread-reply.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/04-newsletter.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/06-html-external-image.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/07-html-only-japanese.eml"
seed_message "test2@otegami.test" "$FIXTURES_DIR/05-test2-welcome.eml"

echo "==> done"
