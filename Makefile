# Build entry points for the otegami monorepo.
#
#   make mac              macOS app build (xcodebuild)
#   make mac-app          macOS Release build, bundled to dist/Otegami.app
#   make ios              iOS Simulator app build (xcodebuild)
#   make ios-device       iOS device build (signed with the registered team)
#   make test             OtegamiKit `swift test`
#   make server           build the otegami-relay server
#   make server-test      run the otegami-relay server test suite
#   make relay-docker     build the otegami-relay Docker image
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
SERVER_DIR := server/otegami-relay
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

.PHONY: all mac mac-app ios ios-device app-project test server server-test relay-docker \
	mailstack-up mailstack-down mailstack-seed deploy-ota clean

all: mac ios test

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

test:
	cd $(KIT_DIR) && swift test

server:
	cd $(SERVER_DIR) && swift build

server-test:
	cd $(SERVER_DIR) && swift test

# Build context is the repo root (not $(SERVER_DIR)) — see Dockerfile's
# doc comment for why (Package.swift depends on ../../packages/OtegamiKit).
relay-docker:
	docker build -f $(SERVER_DIR)/Dockerfile -t otegami-relay .

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
	cd $(SERVER_DIR) && swift package clean
	rm -rf $(APP_PROJECT) dist
