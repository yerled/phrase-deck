.PHONY: generate build release package run open clean

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
	rm -rf dist/PhraseDeck.app
	mkdir -p dist
	cp -R build/Build/Products/Release/PhraseDeck.app dist/
	xattr -cr dist/PhraseDeck.app || true
	@echo "Packaged: $(CURDIR)/dist/PhraseDeck.app"

run: package
	open dist/PhraseDeck.app

open: generate
	open PhraseDeck.xcodeproj

clean:
	rm -rf build PhraseDeck.xcodeproj dist
