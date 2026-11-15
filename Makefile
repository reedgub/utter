.PHONY: build app install run test model clean

MODEL ?= small.en

build:
	swift build

app:
	scripts/build-app.sh

install: app
	-osascript -e 'quit app "Utter"' 2>/dev/null
	rm -rf /Applications/Utter.app
	cp -R build/Utter.app /Applications/Utter.app
	open /Applications/Utter.app

run: app
	-osascript -e 'quit app "Utter"' 2>/dev/null
	open build/Utter.app

test:
	swift test

model:
	scripts/download-model.sh $(MODEL)

clean:
	rm -rf .build build
