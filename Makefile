SWIFT ?= $(HOME)/.swiftly/bin/swift

.PHONY: build test doctor request-accessibility install-daemon start-daemon stop-daemon restart-daemon status health uninstall-daemon logs codex-mcp-config check-local

build:
	$(SWIFT) build

test:
	$(SWIFT) test

doctor:
	$(SWIFT) run axon doctor

request-accessibility:
	$(SWIFT) run axon request-accessibility

install-daemon:
	$(SWIFT) run axon daemon install

start-daemon:
	$(SWIFT) run axon daemon start

stop-daemon:
	$(SWIFT) run axon daemon stop

restart-daemon:
	$(SWIFT) run axon daemon stop
	$(SWIFT) run axon daemon start

status:
	$(SWIFT) run axon daemon status

health:
	$(SWIFT) run axon health

uninstall-daemon:
	$(SWIFT) run axon daemon uninstall

logs:
	tail -f $(HOME)/Library/Logs/Axon/daemon.out.log $(HOME)/Library/Logs/Axon/daemon.err.log

codex-mcp-config:
	@printf '%s\n' '[mcp_servers.axon]'
	@printf '%s\n' 'command = "$(CURDIR)/.build/debug/axon"'
	@printf '%s\n' 'args = ["mcp"]'

check-local: build start-daemon health
