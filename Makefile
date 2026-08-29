.PHONY: generate build run open clean

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme PhraseDeck -configuration Debug \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
		build

run: build
	open build/Build/Products/Debug/PhraseDeck.app

open: generate
	open PhraseDeck.xcodeproj

clean:
	rm -rf build PhraseDeck.xcodeproj
