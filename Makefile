#
# SPDX-License-Identifier: GPL-3.0-or-later

_PROJECT=grub-tools
PREFIX ?= /usr/local
BIN_DIR=$(DESTDIR)$(PREFIX)/bin
DOC_DIR=$(DESTDIR)$(PREFIX)/share/doc/$(_PROJECT)
LIB_DIR=$(DESTDIR)$(PREFIX)/lib

DOC_FILES=$(wildcard *.rst)
SCRIPT_FILES=$(wildcard grub-tools/*)

all:

check: shellcheck

shellcheck:
	shellcheck -s bash $(SCRIPT_FILES)

install: install-scripts install-doc

install-scripts:

	install -vDm 755 grub-tools/mkgrub "$(BIN_DIR)/mkgrub"
	install -vDm 755 grub-tools/mkgrubcfg "$(BIN_DIR)/mkgrubcfg"
	install -vDm 644 configs/grub-embed.cfg "$(LIB_DIR)/mkgrub/configs/grub-embed.cfg"

install-doc:
	install -vDm 644 $(DOC_FILES) -t $(DOC_DIR)

.PHONY: check install install-doc install-scripts shellcheck
