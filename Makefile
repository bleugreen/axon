SWIFT ?= $(HOME)/.swiftly/bin/swift

.PHONY: build test check-version doctor permit package-app package-linux package-win \
	install-daemon serve uninstall-daemon restart-daemon shutdown status logs codex-mcp-config check-local

build:
	$(SWIFT) build

test:
	$(SWIFT) test

# VERSION is the release source; compiled and package literals are derived copies that drift silently.
check-version:
	./scripts/check-version

doctor:
	$(SWIFT) run axon doctor

permit:
	$(SWIFT) run axon permit

package-app:
	./scripts/package-app

package-linux:
	./scripts/package-rust axon-linux

package-win:
	./scripts/package-rust axon-win

# The macOS daemon is the Rust axon-mac and ships only inside Axon.app, so installing means
# packaging first and registering that bundle: fine for a short development loop from dist/, never
# for a real install. The verbs below act on whatever is registered, whichever CLI asks.
install-daemon: package-app
	./dist/Axon.app/Contents/Resources/bin/axon daemon install

# Development without packaging: the daemon on a private socket, no launchd, no menu.
serve:
	cd rust && AXON_SOCKET_PATH=$${AXON_SOCKET_PATH:-/tmp/axon-dev.sock} cargo run -p axon-mac -- serve

uninstall-daemon:
	$(SWIFT) run axon daemon uninstall

restart-daemon:
	$(SWIFT) run axon daemon restart

shutdown:
	$(SWIFT) run axon shutdown

status:
	$(SWIFT) run axon status

logs:
	tail -f $(HOME)/Library/Logs/Axon/daemon.out.log $(HOME)/Library/Logs/Axon/daemon.err.log

codex-mcp-config:
	@printf '%s\n' '[mcp_servers.axon]'
	@printf '%s\n' 'command = "$(CURDIR)/.build/debug/axon"'
	@printf '%s\n' 'args = ["mcp"]'

check-local: build install-daemon status
