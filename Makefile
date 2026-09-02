.PHONY: generate build release package run dev logs open clean

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme PhraseDeck -configuration Debug \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		build

release: generate
	xcodebuild -scheme PhraseDeck -configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
		build

package: release
	-killall PhraseDeck 2>/dev/null
	sleep 0.3
	rm -rf dist/PhraseDeck.app
	mkdir -p dist
	cp -R build/Build/Products/Release/PhraseDeck.app dist/
	xattr -cr dist/PhraseDeck.app || true
	@echo "Packaged: $(CURDIR)/dist/PhraseDeck.app"

run: package
	-killall PhraseDeck 2>/dev/null
	sleep 0.3
	open dist/PhraseDeck.app

# Daily loop: Debug build, replace the running app. Same bundle ID, so TCC permissions stick.
dev: build
	-killall PhraseDeck 2>/dev/null
	sleep 0.3
	open build/Build/Products/Debug/PhraseDeck.app
	@echo "Launched Debug: $(CURDIR)/build/Build/Products/Debug/PhraseDeck.app"
	@echo "Logs: make logs"

logs:
	log stream --style compact --predicate 'process == "PhraseDeck"'

open: generate
	open PhraseDeck.xcodeproj

clean:
	rm -rf build PhraseDeck.xcodeproj dist
