---
name: Bug report
about: Something isn't working as expected
title: ""
labels: bug
assignees: ""
---

## Environment

- otegami platform: iOS / macOS (delete one)
- OS version:
- Device: (e.g. iPhone 17 Pro, physical device or Simulator; Mac model)
- Account type involved: Gmail / iCloud / generic IMAP-SMTP / not
  account-specific
- Commit / version you're on (`git rev-parse HEAD` if built from source):

## What happened

A clear description of the bug.

## Steps to reproduce

1.
2.
3.

## Expected behavior

What you expected to happen instead.

## Logs / screenshots

If applicable, attach a screenshot, and any relevant console output.

For sync/IMAP issues, Xcode's console log (or `xcrun simctl spawn booted
log stream` while reproducing) is usually the most useful thing to
attach — please redact real email addresses/message content if the log
happens to include any (it shouldn't for most sync-engine logging, but
double-check before pasting).

## Anything else

Anything else that might be relevant — did this used to work? Does it
reproduce against the [dev mail stack](../../docs/dev-mailstack.md)
instead of a real account, which would help narrow down whether it's
provider-specific?
