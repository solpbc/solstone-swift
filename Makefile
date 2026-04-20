# solstone-swift build targets

.PHONY: generate build release sim sim-json sim-ipad sim-ipad-json sim-launch test ui-test integration-test integration-test-push integration-test-live test-one test-build test-fast \
		       install deploy launch cycle run unlock \
		       screenshot logs logs-collect log-show crash devices deps clean signing-check

SCHEME    ?= solstone-swift
PROJECT   ?= solstone-swift.xcodeproj
BUNDLE_ID ?= org.solpbc.solstone-swift
TEAM_ID   ?= VJ57N4RWDA
DEVICE    ?= 1776B0A9-E149-52A1-9F6F-04CCDE223940
SIM       ?= iPhone 17 Pro
SIM_IPAD  ?= iPad Pro 13-inch (M4)
ARCHIVE   ?= build/solstone-swift.xcarchive
APP       ?= $(ARCHIVE)/Products/Applications/solstone-swift.app
LOG_SUB   ?= org.solpbc.solstone-swift
KEYCHAIN  ?= ~/Library/Keychains/login.keychain-db
DERIVED   ?= DerivedData
SIM_APP    = $(DERIVED)/Build/Products/Debug-iphonesimulator/$(SCHEME).app
DEV_APP    = $(DERIVED)/Build/Products/Debug-iphoneos/$(SCHEME).app
DEVICE_LOG ?= /tmp/solstone-swift.log

# --- Project setup ---

generate:
	xcodegen generate

install: deps

deps: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'generic/platform=iOS' \
		-resolvePackageDependencies

# --- Keychain (required for device builds over SSH) ---

unlock:
	@security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development" || \
		{ echo "error: Keychain locked or no signing identity. Unlock in the build window:"; \
		  echo "  security unlock-keychain ~/Library/Keychains/login.keychain-db"; exit 1; }
	@echo "Keychain: signing identity accessible"

# --- Simulator (no device/signing needed) ---

sim: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED) \
		COMPILATION_CACHE_ENABLE_CACHING=YES \
		build

sim-json: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED) \
		COMPILATION_CACHE_ENABLE_CACHING=YES \
		build 2>&1 | xcsift

sim-ipad: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM_IPAD)' \
		-derivedDataPath $(DERIVED) \
		COMPILATION_CACHE_ENABLE_CACHING=YES \
		build

sim-ipad-json: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM_IPAD)' \
		-derivedDataPath $(DERIVED) \
		COMPILATION_CACHE_ENABLE_CACHING=YES \
		build 2>&1 | xcsift

sim-launch: sim
	@xcrun simctl boot '$(SIM)' 2>/dev/null || true
	xcrun simctl install booted $(SIM_APP)
	xcrun simctl launch --console-pty --terminate-running-process booted $(BUNDLE_ID)

test: generate
	@rm -rf build/test-results.xcresult
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED) \
		-resultBundlePath build/test-results.xcresult

ui-test: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-only-testing:solstone-swiftUITests \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED)

integration-test: PORT ?= 7071
integration-test: VOICE_PORT ?= 7072
integration-test: sim
	@set -eu; \
	MOCK_PID=""; \
	VOICE_MOCK_PID=""; \
	LAUNCH_PID=""; \
	MOCK_LOG=$$(mktemp -t solstone-swift-mock.XXXXXX); \
	VOICE_MOCK_LOG=$$(mktemp -t solstone-swift-voice-mock.XXXXXX); \
	APP_LOG=$$(mktemp -t solstone-swift-app.XXXXXX); \
	BOOT_LOG=$$(mktemp -t solstone-swift-boot.XXXXXX); \
	cleanup() { \
		status=$$?; \
		if xcrun simctl terminate booted $(BUNDLE_ID) >/dev/null 2>&1; then :; fi; \
		if [ -n "$$LAUNCH_PID" ] && kill -0 "$$LAUNCH_PID" 2>/dev/null; then kill "$$LAUNCH_PID" 2>/dev/null; fi; \
		if [ -n "$$MOCK_PID" ] && kill -0 "$$MOCK_PID" 2>/dev/null; then kill "$$MOCK_PID" 2>/dev/null; fi; \
		if [ -n "$$VOICE_MOCK_PID" ] && kill -0 "$$VOICE_MOCK_PID" 2>/dev/null; then kill "$$VOICE_MOCK_PID" 2>/dev/null; fi; \
		rm -f "$$MOCK_LOG" "$$VOICE_MOCK_LOG" "$$APP_LOG" "$$BOOT_LOG"; \
		exit $$status; \
	}; \
	trap cleanup EXIT INT TERM; \
	if ! xcrun simctl boot "$(SIM)" >"$$BOOT_LOG" 2>&1; then \
		if ! grep -q "Booted" "$$BOOT_LOG"; then \
			cat "$$BOOT_LOG"; \
			exit 1; \
		fi; \
	fi; \
	python3 test/mock_hub_phone.py --port $(PORT) >"$$MOCK_LOG" 2>&1 & \
	MOCK_PID=$$!; \
	python3 test/mock_voice_server.py --port $(VOICE_PORT) >"$$VOICE_MOCK_LOG" 2>&1 & \
	VOICE_MOCK_PID=$$!; \
	ready=0; \
	for _ in 1 2 3 4 5; do \
		if grep -q "^READY:$(PORT)$$" "$$MOCK_LOG"; then \
			ready=1; \
			break; \
		fi; \
		if ! kill -0 "$$MOCK_PID" 2>/dev/null; then \
			echo "mock hub-phone exited before becoming ready (port $(PORT) may be in use):"; \
			cat "$$MOCK_LOG"; \
			exit 1; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$ready" -ne 1 ]; then \
		echo "mock hub-phone did not become ready"; \
		cat "$$MOCK_LOG"; \
		exit 1; \
	fi; \
	voice_ready=0; \
	for _ in 1 2 3 4 5; do \
		if grep -q "^READY:$(VOICE_PORT)$$" "$$VOICE_MOCK_LOG"; then \
			voice_ready=1; \
			break; \
		fi; \
		if ! kill -0 "$$VOICE_MOCK_PID" 2>/dev/null; then \
			echo "mock voice server exited before becoming ready (port $(VOICE_PORT) may be in use):"; \
			cat "$$VOICE_MOCK_LOG"; \
			exit 1; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$voice_ready" -ne 1 ]; then \
		echo "mock voice server did not become ready"; \
		cat "$$VOICE_MOCK_LOG"; \
		exit 1; \
	fi; \
	xcrun simctl install booted $(SIM_APP); \
	SIMCTL_CHILD_MOCK_PORT=$(PORT) SIMCTL_CHILD_MOCK_VOICE_PORT=$(VOICE_PORT) xcrun simctl launch --console-pty --terminate-running-process booted $(BUNDLE_ID) --integration-test >"$$APP_LOG" 2>&1 & \
	LAUNCH_PID=$$!; \
	passed=0; \
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		if xcrun simctl spawn booted log show --info --last 2s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | grep -q "portal: spa ready"; then \
			passed=1; \
			break; \
		fi; \
		sleep 1; \
	done; \
	if [ "$$passed" -ne 1 ]; then \
		echo "integration-test failed: portal did not become ready"; \
		echo "--- subsystem log tail ---"; \
		xcrun simctl spawn booted log show --info --last 20s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 50; \
		echo "--- app log tail ---"; \
		tail -n 50 "$$APP_LOG"; \
		echo "--- mock log ---"; \
		cat "$$MOCK_LOG"; \
		echo "--- voice mock log ---"; \
		cat "$$VOICE_MOCK_LOG"; \
		exit 1; \
	fi; \
	for pattern in "voice session starting" "listening" "portal: nav hint applied: today" "brain: status ready"; do \
		matched=0; \
		for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
			if xcrun simctl spawn booted log show --info --last 30s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | grep -q "$$pattern"; then \
				matched=1; \
				break; \
			fi; \
			sleep 1; \
		done; \
		if [ "$$matched" -ne 1 ]; then \
			echo "integration-test failed: missing log pattern $$pattern"; \
			echo "--- subsystem log tail ---"; \
			xcrun simctl spawn booted log show --info --last 30s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 80; \
			echo "--- app log tail ---"; \
			tail -n 80 "$$APP_LOG"; \
			echo "--- mock log ---"; \
			cat "$$MOCK_LOG"; \
			echo "--- voice mock log ---"; \
			cat "$$VOICE_MOCK_LOG"; \
			exit 1; \
		fi; \
	done; \
	echo "--- subsystem log tail ---"; \
	xcrun simctl spawn booted log show --info --last 10s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 20; \
	echo "integration-test passed"; \
	tail -n 20 "$$APP_LOG"

integration-test-live: PORT ?= 7071
integration-test-live: sim
	@set -eu; \
	LAUNCH_PID=""; \
	APP_LOG=$$(mktemp -t solstone-swift-live-app.XXXXXX); \
	BOOT_LOG=$$(mktemp -t solstone-swift-live-boot.XXXXXX); \
	cleanup() { \
		status=$$?; \
		if xcrun simctl terminate booted $(BUNDLE_ID) >/dev/null 2>&1; then :; fi; \
		if [ -n "$$LAUNCH_PID" ] && kill -0 "$$LAUNCH_PID" 2>/dev/null; then kill "$$LAUNCH_PID" 2>/dev/null; fi; \
		rm -f "$$APP_LOG" "$$BOOT_LOG"; \
		exit $$status; \
	}; \
	trap cleanup EXIT INT TERM; \
	if ! xcrun simctl boot "$(SIM)" >"$$BOOT_LOG" 2>&1; then \
		if ! grep -q "Booted" "$$BOOT_LOG"; then \
			cat "$$BOOT_LOG"; \
			exit 1; \
		fi; \
	fi; \
	xcrun simctl install booted $(SIM_APP); \
	SIMCTL_CHILD_LIVE_SERVER=$(SERVER) SIMCTL_CHILD_LIVE_PORT=$(PORT) xcrun simctl launch --console-pty --terminate-running-process booted $(BUNDLE_ID) --integration-test-live >"$$APP_LOG" 2>&1 & \
	LAUNCH_PID=$$!; \
	sleep 10; \
		echo "--- subsystem log tail ---"; \
		xcrun simctl spawn booted log show --info --last 15s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 40; \
		echo "integration-test-live launched"; \
		tail -n 40 "$$APP_LOG"

integration-test-push: PORT ?= 7071
integration-test-push: VOICE_PORT ?= 7072
integration-test-push: PUSH_PORT ?= 8474
integration-test-push: sim
	@set -eu; \
		MOCK_PID=""; \
		VOICE_MOCK_PID=""; \
		PUSH_MOCK_PID=""; \
		LAUNCH_PID=""; \
		MOCK_LOG=$$(mktemp -t solstone-swift-mock.XXXXXX); \
		VOICE_MOCK_LOG=$$(mktemp -t solstone-swift-voice-mock.XXXXXX); \
		PUSH_MOCK_LOG=$$(mktemp -t solstone-swift-push-mock.XXXXXX); \
		PUSH_COUNT=$$(mktemp -t solstone-swift-push-count.XXXXXX); \
		APP_LOG=$$(mktemp -t solstone-swift-push-app.XXXXXX); \
		BOOT_LOG=$$(mktemp -t solstone-swift-push-boot.XXXXXX); \
		cleanup() { \
			status=$$?; \
			if xcrun simctl terminate booted $(BUNDLE_ID) >/dev/null 2>&1; then :; fi; \
			if [ -n "$$LAUNCH_PID" ] && kill -0 "$$LAUNCH_PID" 2>/dev/null; then kill "$$LAUNCH_PID" 2>/dev/null; fi; \
			if [ -n "$$MOCK_PID" ] && kill -0 "$$MOCK_PID" 2>/dev/null; then kill "$$MOCK_PID" 2>/dev/null; fi; \
			if [ -n "$$VOICE_MOCK_PID" ] && kill -0 "$$VOICE_MOCK_PID" 2>/dev/null; then kill "$$VOICE_MOCK_PID" 2>/dev/null; fi; \
			if [ -n "$$PUSH_MOCK_PID" ] && kill -0 "$$PUSH_MOCK_PID" 2>/dev/null; then kill "$$PUSH_MOCK_PID" 2>/dev/null; fi; \
			rm -f "$$MOCK_LOG" "$$VOICE_MOCK_LOG" "$$PUSH_MOCK_LOG" "$$PUSH_COUNT" "$$APP_LOG" "$$BOOT_LOG"; \
			exit $$status; \
		}; \
		trap cleanup EXIT INT TERM; \
		if ! xcrun simctl boot "$(SIM)" >"$$BOOT_LOG" 2>&1; then \
			if ! grep -q "Booted" "$$BOOT_LOG"; then \
				cat "$$BOOT_LOG"; \
				exit 1; \
			fi; \
		fi; \
		for port in $(PORT) $(VOICE_PORT) $(PUSH_PORT); do \
			pids=$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null || true); \
			if [ -n "$$pids" ]; then \
				kill $$pids 2>/dev/null || true; \
				sleep 1; \
			fi; \
		done; \
		python3 test/mock_hub_phone.py --port $(PORT) >"$$MOCK_LOG" 2>&1 & \
		MOCK_PID=$$!; \
		python3 test/mock_voice_server.py --port $(VOICE_PORT) >"$$VOICE_MOCK_LOG" 2>&1 & \
		VOICE_MOCK_PID=$$!; \
		python3 test/mock_push_server.py --port $(PUSH_PORT) --count-file "$$PUSH_COUNT" >"$$PUSH_MOCK_LOG" 2>&1 & \
		PUSH_MOCK_PID=$$!; \
		ready=0; \
		for _ in 1 2 3 4 5; do \
			if grep -q "^READY:$(PORT)$$" "$$MOCK_LOG"; then ready=1; break; fi; \
			if ! kill -0 "$$MOCK_PID" 2>/dev/null; then cat "$$MOCK_LOG"; exit 1; fi; \
			sleep 1; \
		done; \
		[ "$$ready" -eq 1 ] || { echo "mock hub-phone did not become ready"; cat "$$MOCK_LOG"; exit 1; }; \
		voice_ready=0; \
		for _ in 1 2 3 4 5; do \
			if grep -q "^READY:$(VOICE_PORT)$$" "$$VOICE_MOCK_LOG"; then voice_ready=1; break; fi; \
			if ! kill -0 "$$VOICE_MOCK_PID" 2>/dev/null; then cat "$$VOICE_MOCK_LOG"; exit 1; fi; \
			sleep 1; \
		done; \
		[ "$$voice_ready" -eq 1 ] || { echo "mock voice server did not become ready"; cat "$$VOICE_MOCK_LOG"; exit 1; }; \
		push_ready=0; \
		for _ in 1 2 3 4 5; do \
			if grep -q "^READY:$(PUSH_PORT)$$" "$$PUSH_MOCK_LOG"; then push_ready=1; break; fi; \
			if ! kill -0 "$$PUSH_MOCK_PID" 2>/dev/null; then cat "$$PUSH_MOCK_LOG"; exit 1; fi; \
			sleep 1; \
		done; \
		[ "$$push_ready" -eq 1 ] || { echo "mock push server did not become ready"; cat "$$PUSH_MOCK_LOG"; exit 1; }; \
		xcrun simctl install booted $(SIM_APP); \
		SIMCTL_CHILD_MOCK_PORT=$(PORT) SIMCTL_CHILD_MOCK_VOICE_PORT=$(VOICE_PORT) SIMCTL_CHILD_MOCK_PUSH_PORT=$(PUSH_PORT) xcrun simctl launch --console-pty --terminate-running-process booted $(BUNDLE_ID) --integration-test --integration-test-push-register --integration-test-push-tap=briefing >"$$APP_LOG" 2>&1 & \
		LAUNCH_PID=$$!; \
		app_ready=0; \
		for _ in 1 2 3 4 5 6 7 8 9 10; do \
			if xcrun simctl spawn booted log show --info --last 2s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | grep -q "portal: spa ready"; then app_ready=1; break; fi; \
			sleep 1; \
		done; \
		[ "$$app_ready" -eq 1 ] || { echo "integration-test-push failed: app did not become ready"; tail -n 80 "$$APP_LOG"; cat "$$MOCK_LOG"; cat "$$VOICE_MOCK_LOG"; cat "$$PUSH_MOCK_LOG"; exit 1; }; \
		positive=0; \
		for _ in 1 2 3 4 5; do \
			if xcrun simctl spawn booted log show --info --last 5s --predicate 'subsystem == "org.solpbc.solstone-swift" AND category == "router"' 2>/dev/null | grep -q "routed to today"; then positive=1; break; fi; \
			sleep 1; \
		done; \
		[ "$$positive" -eq 1 ] || { echo "integration-test-push failed: missing routed to today log"; xcrun simctl spawn booted log show --info --last 20s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 80; exit 1; }; \
		sleep 10; \
		if xcrun simctl spawn booted log show --info --last 10s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | grep -q "voice session starting"; then \
			echo "integration-test-push failed: unexpected voice session start"; \
			xcrun simctl spawn booted log show --info --last 20s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 80; \
			exit 1; \
		fi; \
		if xcrun simctl spawn booted log show --info --last 10s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | grep -q "listening"; then \
			echo "integration-test-push failed: unexpected listening log"; \
			xcrun simctl spawn booted log show --info --last 20s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 80; \
			exit 1; \
		fi; \
		if ! curl -s "http://127.0.0.1:$(PUSH_PORT)/api/push/status" | grep -Eq '"registration_count"[[:space:]]*:[[:space:]]*[1-9]'; then \
			echo "integration-test-push failed: mock push server never saw registration"; \
			cat "$$PUSH_COUNT"; \
			cat "$$PUSH_MOCK_LOG"; \
			exit 1; \
		fi; \
		echo "--- subsystem log tail ---"; \
		xcrun simctl spawn booted log show --info --last 10s --predicate 'subsystem == "org.solpbc.solstone-swift"' 2>/dev/null | tail -n 40; \
		echo "integration-test-push passed"; \
		tail -n 20 "$$APP_LOG"

test-one: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED) \
		-only-testing:'$(SCHEME)Tests/$(TEST)'

test-build: generate
	xcodebuild build-for-testing -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED)

test-fast:
	xcodebuild test-without-building \
		-project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DERIVED)

# --- Device (requires iPhone connected to Mac) ---

build: generate unlock
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-destination 'id=$(DEVICE)' \
		-derivedDataPath $(DERIVED) \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		COMPILATION_CACHE_ENABLE_CACHING=YES \
		build

release: generate unlock
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) \
		-skipMacroValidation \
		-configuration Release \
		-archivePath $(ARCHIVE) \
		-destination 'id=$(DEVICE)' \
		-derivedDataPath $(DERIVED) \
		DEVELOPMENT_TEAM=$(TEAM_ID)

deploy: build
	@tmux kill-window -t hopper:logs 2>/dev/null || true
	@rm -f $(DEVICE_LOG)
	@tmux new-window -t hopper: -d -n logs \
		"pymobiledevice3 syslog live --tunnel '' 2>&1 | grep --line-buffered solstone-swift | tee $(DEVICE_LOG)"
	@sleep 2
	xcrun devicectl device install app --device $(DEVICE) $(DEV_APP)
	@echo "Deployed — logs streaming to $(DEVICE_LOG)"

launch:
	xcrun devicectl device process launch --console --device $(DEVICE) $(BUNDLE_ID)

cycle: deploy launch

run: deploy
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE_ID)

# --- Device debugging (requires pymobiledevice3 tunneld running) ---

screenshot:
	@pymobiledevice3 developer dvt screenshot /tmp/solstone-swift-screenshot.png --tunnel '' 2>&1 || \
		{ echo "error: run 'sudo pymobiledevice3 remote tunneld' on the Mac first"; exit 1; }
	@echo "Screenshot: /tmp/solstone-swift-screenshot.png"

logs:
	@cat $(DEVICE_LOG) 2>/dev/null || echo "No logs. Run 'make run' to deploy with log capture."

logs-collect:
	sudo log collect --device-udid $(DEVICE) --output /tmp/solstone-swift-logs.logarchive
	@echo "Collected to /tmp/solstone-swift-logs.logarchive"
	@echo "View with: log show --predicate 'subsystem == \"$(LOG_SUB)\"' /tmp/solstone-swift-logs.logarchive"

log-show:
	log show --predicate 'subsystem == "$(LOG_SUB)"' --style compact /tmp/solstone-swift-logs.logarchive

crash:
	pymobiledevice3 crash pull /tmp/solstone-swift-crashes --tunnel '' 2>&1 || \
		idevicecrashreport /tmp/solstone-swift-crashes 2>&1 || \
		{ echo "error: install pymobiledevice3 or libimobiledevice"; exit 1; }
	@echo "Crash reports: /tmp/solstone-swift-crashes/"

# --- Utilities ---

signing-check:
	@echo "=== Signing Identities ==="
	@security find-identity -p codesigning -v
	@echo ""
	@echo "=== Team: $(TEAM_ID) ==="
	@echo "=== Bundle: $(BUNDLE_ID) ==="
	@echo ""
	@echo "=== Provisioning Profiles ==="
	@ls ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision 2>/dev/null | while read p; do \
		name=$$(security cms -D -i "$$p" 2>/dev/null | plutil -extract Name raw - 2>/dev/null); \
		team=$$(security cms -D -i "$$p" 2>/dev/null | plutil -extract TeamIdentifier.0 raw - 2>/dev/null); \
		echo "  $$name (team: $$team)"; \
	done || echo "  (none found)"
	@echo ""
	@if security find-identity -p codesigning -v | grep -q "Apple Development"; then \
		echo "OK: Apple Development certificate found"; \
	else \
		echo "MISSING: No Apple Development certificate. Add account in Xcode > Settings > Accounts."; \
	fi

devices:
	xcrun devicectl list devices

clean:
	xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) -skipMacroValidation 2>/dev/null || true
	rm -rf build/ $(PROJECT)
