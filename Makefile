.PHONY: build bundle run release icon clean

build:
	swift build -c release

bundle:
	./scripts/make_app.sh

run:
	swift run ClaudeTrayMonitor

icon:
	./scripts/make_icon.sh

release: bundle
	cd build && rm -f ClaudeTrayMonitor-macos.zip && zip -r -q ClaudeTrayMonitor-macos.zip "Claude Tray Monitor.app"
	@echo "Release: build/ClaudeTrayMonitor-macos.zip"

clean:
	rm -rf .build build