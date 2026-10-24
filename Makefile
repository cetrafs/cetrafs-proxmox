PACKAGE := pve-storage-cetrafs
VERSION := $(shell dpkg-parsechangelog -S Version 2>/dev/null)

DESTDIR ?=
PERLDIR := /usr/share/perl5
PLUGINDIR := $(PERLDIR)/PVE/Storage/Custom
UIJSDIR := /usr/share/pve-manager/js
UISHAREDIR := /usr/share/$(PACKAGE)-ui

PERL_SOURCES := $(shell find src -name '*.pm')

.PHONY: all
all:

.PHONY: check
check: test

.PHONY: test
test:
	for f in $(PERL_SOURCES); do perl -Isrc -wc $$f || exit 1; done
	if command -v node >/dev/null; then node --check ui/cetrafs-ui.js; fi
	prove -Isrc -v t/

.PHONY: install
install:
	install -d $(DESTDIR)$(PLUGINDIR)
	install -m 0644 src/PVE/Storage/Custom/CetraFSPlugin.pm $(DESTDIR)$(PLUGINDIR)/
	install -d $(DESTDIR)$(UIJSDIR) $(DESTDIR)$(UISHAREDIR)
	install -m 0644 ui/cetrafs-ui.js $(DESTDIR)$(UIJSDIR)/
	install -m 0755 ui/cetrafs-ui-index $(DESTDIR)$(UISHAREDIR)/

.PHONY: deb
deb:
	dpkg-buildpackage -b -us -uc
	mkdir -p dist
	mv ../$(PACKAGE)_$(VERSION)_*.deb ../$(PACKAGE)-ui_$(VERSION)_*.deb \
	   ../$(PACKAGE)_$(VERSION)_*.buildinfo \
	   ../$(PACKAGE)_$(VERSION)_*.changes dist/

.PHONY: clean
clean:
	rm -rf dist debian/$(PACKAGE) debian/$(PACKAGE)-ui debian/tmp debian/.debhelper debian/files \
	       debian/*.substvars debian/*.debhelper.log debian/debhelper-build-stamp
