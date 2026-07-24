# Build entry points for the otegami monorepo.
#
#   make mac              macOS app build (xcodebuild)
#   make ios              iOS Simulator app build (xcodebuild)
#   make ios-device       iOS device build (signed with the registered team)
#   make test             OtegamiKit `swift test`
#   make server           build the otegami-relay server
#   make server-test      run the otegami-relay server test suite
#   make relay-docker     build the otegami-relay Docker image
#   make mailstack-up     start the dev IMAP/SMTP mail stack (Dovecot + Mailpit)
#   make mailstack-down   stop the dev mail stack
#   make mailstack-seed   load sample messages into the dev mail stack
#   make clean            remove build products

APP_DIR := apps/Otegami
APP_PROJECT := $(APP_DIR)/Otegami.xcodeproj
APP_SCHEME := Otegami
IOS_SIMULATOR ?= iPhone 17 Pro Max

KIT_DIR := packages/OtegamiKit
SERVER_DIR := server/otegami-relay
MAILSTACK_DIR := dev/mailstack

.PHONY: all mac ios ios-device app-project test server server-test relay-docker \
	mailstack-up mailstack-down mailstack-seed clean

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
		build

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

clean:
	cd $(KIT_DIR) && swift package clean
	cd $(SERVER_DIR) && swift package clean
	rm -rf $(APP_PROJECT) dist
