PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SRC    := $(CURDIR)

.PHONY: install uninstall test lint

# Links rather than copies, so a `git pull` updates the installed command.
install:
	mkdir -p "$(BINDIR)"
	ln -sf "$(SRC)/bin/winserver" "$(BINDIR)/winserver"
	@echo "Installed $(BINDIR)/winserver"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Add $(BINDIR) to your PATH, e.g.: echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.zshrc" ;; esac

uninstall:
	rm -f "$(BINDIR)/winserver"

test:
	bash tests/run.sh

lint:
	shellcheck -x bin/winserver lib/*.sh lib/backends/*.sh tests/run.sh tests/stub/hypervisor
	pwsh -NoProfile -File tests/lint-ps1.ps1
