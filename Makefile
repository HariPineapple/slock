APP        := build/Slock.app
DEST       := $(HOME)/Applications/Slock.app
AGENTS     := $(HOME)/Library/LaunchAgents
UID        := $(shell id -u)
HOOK_LINE  := [ -f "$(HOME)/.slock/slock.zsh" ] && source "$(HOME)/.slock/slock.zsh"

.PHONY: build icon run reset-permissions dev-web install uninstall shell-hook restart logs

build:
	./scripts/make-cert.sh
	./scripts/bundle.sh

# Regenerates agent/AppIcon.icns from scripts/make-icon.swift.
icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o agent/AppIcon.icns

# Run the agent in the foreground from the build dir (for development).
run: build
	$(APP)/Contents/MacOS/Slock

dev-web:
	python3 web/server.py

install: build
	-launchctl bootout gui/$(UID)/dev.slock.agent 2>/dev/null
	-launchctl bootout gui/$(UID)/dev.slock.web 2>/dev/null
	rm -f $(AGENTS)/dev.slock.web.plist
	-pkill -x Slock; pkill -f "Slock.app/Contents/Resources/web/server.py"; sleep 1
	mkdir -p $(HOME)/Applications $(AGENTS) $(HOME)/.slock
	rm -rf $(DEST) && mv $(APP) $(DEST)
	cp shell/slock.zsh $(HOME)/.slock/slock.zsh
	sed "s|__HOME__|$(HOME)|g" launchd/dev.slock.agent.plist > $(AGENTS)/dev.slock.agent.plist
	launchctl bootstrap gui/$(UID) $(AGENTS)/dev.slock.agent.plist
	sleep 2 && open $(DEST)
	@echo "Installed ~/Applications/Slock.app (starts at login in the menu bar)."
	@echo "Run 'make shell-hook' to also log terminal commands."

# Adds one line to ~/.zshrc that sources the slock shell logger.
shell-hook:
	@mkdir -p $(HOME)/.slock && cp shell/slock.zsh $(HOME)/.slock/slock.zsh
	@grep -qF '.slock/slock.zsh' $(HOME)/.zshrc 2>/dev/null || printf '\n# slock shell logger\n%s\n' '$(HOOK_LINE)' >> $(HOME)/.zshrc
	@echo "Added to ~/.zshrc — open a new terminal to start logging commands."

# Clears Slock's stale privacy entries (e.g. left over from old ad-hoc builds) so you can grant them fresh.
reset-permissions:
	-tccutil reset ScreenCapture dev.slock.agent
	-tccutil reset Accessibility dev.slock.agent
	-tccutil reset AppleEvents dev.slock.agent

restart:
	launchctl kickstart -k gui/$(UID)/dev.slock.agent

logs:
	tail -f $(HOME)/.slock/agent.log

# Stops and removes the app + launch agents. Keeps your data in ~/.slock.
uninstall:
	-launchctl bootout gui/$(UID)/dev.slock.agent
	-launchctl bootout gui/$(UID)/dev.slock.web 2>/dev/null
	-pkill -x Slock
	rm -f $(AGENTS)/dev.slock.agent.plist $(AGENTS)/dev.slock.web.plist
	rm -rf $(DEST)
	@echo "Removed. Data kept in ~/.slock (delete it yourself if you want). Remove the slock line from ~/.zshrc too."
