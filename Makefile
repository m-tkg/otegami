# Build entry points for the otegami monorepo.
#
#   make mac              macOS app build (xcodebuild)
#   make mac-app          macOS Release build, bundled to dist/Otegami.app
#   make ios              iOS Simulator app build (xcodebuild)
#   make ios-device       iOS device build (signed with the registered team)
#   make ios-apptests     apps 層ユニットテスト (OtegamiAppTests/NotificationServiceTests)
#   make test             OtegamiKit `swift test`
#   make check-localization  Localizable.xcstrings coverage check (Task #170)
#   make relay-go         build the Go otegami-relay server
#   make relay-go-test    run the Go otegami-relay server test suite
#   make relay-go-docker  build the Go otegami-relay Docker image
#   make verify-<scenario>  scripts/verify-screen.sh <scenario> (tap-free
#                          screenshot; see that script's own header comment
#                          for the scenario list, e.g. `make verify-list`)
#   make mailstack-up     start the dev IMAP/SMTP mail stack (Dovecot + Mailpit)
#   make mailstack-down   stop the dev mail stack
#   make mailstack-seed   load sample messages into the dev mail stack
#   make deploy-ota       build + publish an Ad Hoc IPA for OTA install (see docs/ota-deploy.md)
#   make clean            remove build products

APP_DIR := apps/Otegami
APP_PROJECT := $(APP_DIR)/Otegami.xcodeproj
APP_SCHEME := Otegami
IOS_SIMULATOR ?= iPhone 17 Pro Max

KIT_DIR := packages/OtegamiKit
RELAY_GO_DIR := server/otegami-relay-go
MAILSTACK_DIR := dev/mailstack
DIST_DIR := dist

# Config/Signing.xcconfig ships with no DEVELOPMENT_TEAM (public OSS default —
# see its own doc comment); a developer sets one in the git-ignored
# Config/Local.xcconfig (Config/Local.xcconfig.sample). Without it, Automatic
# signing can't produce a provisioning profile for the macOS target's iCloud
# KVS entitlement (Config/Otegami-macOS.entitlements) and `xcodebuild` hard
# -fails with "requires a development team" even for a local, non-distributed
# build — iOS Simulator builds don't hit this (Simulator doesn't enforce
# provisioning), but macOS ones do. So `mac`/`mac-app` fall back to an
# unsigned build (same flags ci-app.yml uses, for the same reason) whenever
# there's no Local.xcconfig, so a fresh clone always builds; once a developer
# creates Local.xcconfig with their own team, these targets go back to a
# normal signed build using it.
LOCAL_XCCONFIG := $(APP_DIR)/Config/Local.xcconfig
ifeq (,$(wildcard $(LOCAL_XCCONFIG)))
MAC_SIGNING_FLAGS := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
else
MAC_SIGNING_FLAGS :=
endif

.PHONY: all mac mac-app ios ios-device ios-apptests app-project test check-localization \
	relay-go relay-go-test relay-go-docker verify-% \
	mailstack-up mailstack-down mailstack-seed deploy-ota clean

all: mac ios test check-localization

# xcodegen keeps the Xcode project in sync with project.yml; regenerate
# before every app build so new source files are always picked up.
app-project:
	cd $(APP_DIR) && xcodegen generate

mac: app-project
	xcodebuild \
		-project $(APP_PROJECT) \
		-scheme $(APP_SCHEME) \
		-destination 'platform=macOS' \
		$(MAC_SIGNING_FLAGS) \
		build

# M10 (plan: "make mac-app (App bundle を dist/ に生成)"): a Release build,
# built to its own derived-data dir (not the incremental one `make mac`
# reuses — Debug and Release configs shouldn't share build products) and
# copied out to dist/Otegami.app. Uses plain `xcodebuild build` (not
# `archive` + `-exportArchive`) deliberately: `-exportArchive` requires an
# ExportOptions.plist describing a distribution method (App Store/ad-hoc/
# developer-id/...), which is a decision for whoever's actually shipping a
# build, not something this Makefile should bake in for an OSS project
# where every builder signs with their own team (Config/Signing.xcconfig's
# doc comment). A plain Release build already produces a fully-formed,
# locally-runnable .app signed with that same team.
mac-app: app-project
	rm -rf $(DIST_DIR)/Otegami.app $(DIST_DIR)/.mac-app-build
	xcodebuild \
		-project $(APP_PROJECT) \
		-scheme $(APP_SCHEME) \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath $(DIST_DIR)/.mac-app-build \
		$(MAC_SIGNING_FLAGS) \
		build
	mkdir -p $(DIST_DIR)
	cp -R $(DIST_DIR)/.mac-app-build/Build/Products/Release/Otegami.app $(DIST_DIR)/Otegami.app
	rm -rf $(DIST_DIR)/.mac-app-build
	@echo "==> $(DIST_DIR)/Otegami.app"

ios: app-project
	xcodebuild \
		-project $(APP_PROJECT) \
		-scheme $(APP_SCHEME) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' \
		build

ios-device: app-project
	xcodebuild \
		-project $(APP_PROJECT) \
		-scheme $(APP_SCHEME) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		build

# Phase 5 (テスト衛生): apps 層 (Otegami アプリ本体 / NotificationService
# extension) のユニットテスト。`OtegamiUITests` (XCUIApplication ベースの
# E2E、`ios`/`ios-device` の scheme test action にしか含めていない) とは
# 別に、`-only-testing:` で明示的にこの2ターゲットだけを回す — シミュレータ
# 起動・実アプリ操作を必要としない軽量テストなので、E2E を待たずに素早く
# 回せる。
ios-apptests: app-project
	xcodebuild \
		-project $(APP_PROJECT) \
		-scheme $(APP_SCHEME) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' \
		-only-testing:OtegamiAppTests \
		-only-testing:NotificationServiceTests \
		test

test:
	cd $(KIT_DIR) && swift test

# Task #170: guards against apps/Otegami/Sources string literals that never
# got a Localizable.xcstrings entry (always render in the source language,
# ja, regardless of the device's language setting) or that only got a ja
# entry (render in English always) — see scripts/check-localizable-
# coverage.py's docstring for the full rationale. Regenerating the catalog
# first also catches generate-localizable.py's `translations` dict drifting
# out of sync with a hand-edit made directly in Xcode's String Catalog
# editor (docs/localization.md's Task #145 note on this drift class) —
# `git diff --exit-code` fails the check if regenerating produces anything
# different from what's committed.
check-localization:
	python3 scripts/generate-localizable.py
	git diff --exit-code apps/Otegami/Resources/Localizable.xcstrings
	python3 scripts/check-localizable-coverage.py

# Delegates to scripts/verify-screen.sh's tap-free screenshot capture —
# `make verify-list` runs `scripts/verify-screen.sh list`, `make
# verify-composer-richtext` runs `scripts/verify-screen.sh composer-richtext`,
# etc. See that script's own header comment for the full scenario list and
# env vars (IOS_SIMULATOR, SCREENSHOT_DIR, APPEARANCE, LOCALE, ...).
verify-%:
	./scripts/verify-screen.sh $*

relay-go:
	cd $(RELAY_GO_DIR) && go build ./...

relay-go-test:
	cd $(RELAY_GO_DIR) && go test ./...

relay-go-docker:
	docker build -f $(RELAY_GO_DIR)/Dockerfile -t otegami-relay-go $(RELAY_GO_DIR)

mailstack-up:
	cd $(MAILSTACK_DIR) && docker compose up -d

mailstack-down:
	cd $(MAILSTACK_DIR) && docker compose down

mailstack-seed:
	cd $(MAILSTACK_DIR) && ./seed/seed.sh

# Builds an Ad Hoc IPA and publishes it (+ manifest.plist + install page) to
# the home Pi's nginx for OTA install on the registered iPhone. See
# docs/ota-deploy.md. The script runs its own `xcodegen generate`.
deploy-ota:
	./scripts/deploy-ota.sh

clean:
	cd $(KIT_DIR) && swift package clean
	rm -rf $(APP_PROJECT) dist
