# lupus — install the binary and module tree to a local path.
# Requires GNU Make (uses ?= for overridable defaults).
#
# The entry script (bin/lupus) resolves its own directory, strips /bin,
# and looks for modules under that root.  So installing the binary to
# $(PREFIX)/bin/lupus means the modules must live under $(PREFIX)/lupus/.
#
# Targets
#   install (default)   — copy bin/lupus → $(BIN)/lupus
#                         copy lupus/     → $(LIB)/lupus/
#                         always overwrites the destination; asks for
#                         confirmation first unless FORCE=1 is given
#   uninstall           — remove everything installed
#   reinstall           — uninstall + install
#
# Variables
#   PREFIX   — install root              (default: $(HOME)/.local)
#   DESTDIR  — staging root for packages (default: empty)
#   BIN      — binary directory          (default: $(DESTDIR)$(PREFIX)/bin)
#   LIB      — module directory          (default: $(DESTDIR)$(PREFIX))
#   FORCE    — skip the overwrite confirmation prompt when set
#
# Examples
#   make                              # → ~/.local/bin/lupus  +  ~/.local/lupus/
#   make PREFIX=/usr/local            # → /usr/local/bin/lupus  +  /usr/local/lupus/
#   make DESTDIR=/tmp/stage PREFIX=/usr  → /tmp/stage/usr/bin/lupus + /tmp/stage/usr/lupus/
#   make FORCE=1                      # skip the "overwrite?" prompt (e.g. packaging)

PREFIX ?= $(HOME)/.local
DESTDIR ?=
BIN    ?= $(DESTDIR)$(PREFIX)/bin
LIB    ?= $(DESTDIR)$(PREFIX)
FORCE  ?=

LUPSRC = bin/lupus
LUPBIN = $(BIN)/lupus
LUPMOD = $(LIB)/lupus

.PHONY: all install uninstall reinstall

all: install

# No freshness tracking: install always copies everything, so it always
# reflects the current source tree. Since that means overwriting whatever
# is already at $(BIN)/$(LIB), confirm with the user first (unless FORCE=1).
install:
	@if [ -z "$(FORCE)" ]; then \
		echo "This will overwrite:"; \
		echo "  $(LUPBIN)"; \
		echo "  $(LUPMOD)/"; \
		printf "Continue? [y/N] "; \
		read -r ans; \
		case "$$ans" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac; \
	fi
	@mkdir -p $(BIN)
	cp $(LUPSRC) $(LUPBIN)
	chmod 755 $(LUPBIN)
	@echo "lupus installed → $(LUPBIN)"
	@mkdir -p $(LUPMOD)/ai/providers \
	           $(LUPMOD)/app \
	           $(LUPMOD)/ext \
	           $(LUPMOD)/loop \
	           $(LUPMOD)/tools \
	           $(LUPMOD)/tui/components \
	           $(LUPMOD)/util
	cp -p lupus/*.lua        $(LUPMOD)/
	cp -p lupus/ai/*.lua     $(LUPMOD)/ai/
	cp -p lupus/ai/providers/*.lua $(LUPMOD)/ai/providers/
	cp -p lupus/app/*.lua    $(LUPMOD)/app/
	cp -p lupus/ext/*.lua    $(LUPMOD)/ext/
	cp -p lupus/loop/*.lua   $(LUPMOD)/loop/
	cp -p lupus/tools/*.lua  $(LUPMOD)/tools/
	cp -p lupus/tui/*.lua    $(LUPMOD)/tui/
	cp -p lupus/tui/components/*.lua $(LUPMOD)/tui/components/
	cp -p lupus/util/*.lua   $(LUPMOD)/util/
	@echo "lupus modules installed → $(LUPMOD)/"

uninstall:
	rm -f $(LUPBIN)
	rm -rf $(LUPMOD)
	@echo "lupus removed from $(LIB)"

reinstall: uninstall install
