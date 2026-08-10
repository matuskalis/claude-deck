APP_NAME := Claude Deck
BIN := .build/release/ClaudeDeck
APP := dist/$(APP_NAME).app

.PHONY: build install run clean

build:
	swift build -c release
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/ClaudeDeck"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign - "$(APP)"

install: build
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/$(APP_NAME).app"
	ditto "$(APP)" "$(HOME)/Applications/$(APP_NAME).app"

run: build
	pkill -x ClaudeDeck || true
	open "$(APP)"

clean:
	rm -rf .build dist
