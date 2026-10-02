.PHONY: build bundle install run release dmg publish icon clean

build:
	swift build -c release

bundle:
	./scripts/make_app.sh

install: bundle
	pkill -x ClaudeTrayMonitor || true
	rm -rf "$(HOME)/Applications/Claude Tray Monitor.app"
	mkdir -p "$(HOME)/Applications"
	cp -R "build/Claude Tray Monitor.app" "$(HOME)/Applications/"
	open "$(HOME)/Applications/Claude Tray Monitor.app"
	@echo "Installed: $(HOME)/Applications/Claude Tray Monitor.app"

run:
	swift run ClaudeTrayMonitor

icon:
	./scripts/make_icon.sh

release: bundle
	cd build && rm -f ClaudeTrayMonitor-macos.zip && zip -r -q ClaudeTrayMonitor-macos.zip "Claude Tray Monitor.app"
	@echo "Release: build/ClaudeTrayMonitor-macos.zip"

dmg:
	./scripts/make_dmg.sh

publish:
	./scripts/publish.sh

clean:
	rm -rf .build build