SHELL := /bin/zsh
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export PYTHONDONTWRITEBYTECODE := 1
SCRATCH ?= /private/tmp/harness-build

.PHONY: help build test test-native test-capture check package install icon preferences signing-tests source privacy
help:
	@printf '%s\n' 'build · test · test-native · test-capture · check · package · install · icon · preferences · signing-tests · source · privacy'
build:
	swift build --scratch-path "$(SCRATCH)"
test:
	swift test --scratch-path "$(SCRATCH)"
test-native:
	HARNESS_RUN_OVERLAY_GUI_TESTS=1 swift test --scratch-path "$(SCRATCH)"
test-capture:
	HARNESS_RUN_OVERLAY_GUI_TESTS=1 HARNESS_RUN_NATIVE_CAPTURE_TESTS=1 swift test --scratch-path "$(SCRATCH)"
check:
	HARNESS_SCRATCH="$(SCRATCH)" zsh ./scripts/check.sh
package:
	HARNESS_PACKAGE_SCRATCH="$(SCRATCH)" ./scripts/package.sh
install:
	python3 scripts/install.py
icon:
	./scripts/generate-icon.sh
preferences:
	python3 scripts/verify-preferences.py
signing-tests:
	python3 -m unittest discover -s Tests/PackagingTests
source:
	python3 scripts/source.py
privacy:
	python3 scripts/release_privacy.py
