SWIFT ?= $(HOME)/.swiftly/bin/swift

.PHONY: build test check-version doctor permit package-app package-linux package-win \
	install-daemon uninstall-daemon restart-daemon shutdown status logs codex-mcp-config check-local

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

# These register the built executable in .build/debug, which is a build directory: fine for a
# short development loop, never for a real install. The CLI warns about it.
install-daemon:
	$(SWIFT) run axon daemon install

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
