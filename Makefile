DIR := $(shell dirname $(lastword $(MAKEFILE_LIST)))

NODE_MODS  := $(DIR)/node_modules
PUG        := $(NODE_MODS)/.bin/pug
STYLUS     := $(NODE_MODS)/.bin/stylus

TARGET_DIR := build/http
HTML       := index
HTML       := $(patsubst %,$(TARGET_DIR)/%.html,$(HTML))
RESOURCES  := $(shell find src/resources -type f)
RESOURCES  := $(patsubst src/resources/%,$(TARGET_DIR)/%,$(RESOURCES))
TEMPLS     := $(wildcard src/pug/templates/*.pug)

AVR_FIRMWARE := src/avr/bbctrl-avr-firmware.hex
GPLAN_MOD    := rpi-share/camotics/gplan.so
GPLAN_TARGET := src/py/camotics/gplan.so
GPLAN_IMG    := gplan-dev.img

RSYNC_EXCLUDE := \*.pyc __pycache__ \*.egg-info \\\#* \*~ .\\\#\*
RSYNC_EXCLUDE := $(patsubst %,--exclude %,$(RSYNC_EXCLUDE))
RSYNC_OPTS    := $(RSYNC_EXCLUDE) -rv --no-g --delete --force

VERSION  := $(shell sed -n 's/^.*"version": "\([^"]*\)",.*$$/\1/p' package.json)
# Canonical package name (audit Scripts-7): README, this Makefile,
# package.json/setup.py and upgrade-bbctrl all agree that release
# packages are named onefinity-<version>.tar.bz2.
PKG_NAME := onefinity-$(VERSION)

SUBPROJECTS := avr boot pwr jig

ifndef HOST
HOST=onefinity.local
endif

# Dev-update credentials and TLS (audit Scripts-12): the admin
# password is NEVER kept in source.  Pass it in the environment:
#   BBCTRL_PASSWORD=... make update
# The update is sent over HTTPS.  If the controller's certificate is
# not in the system trust store, point BBCTRL_CACERT at its CA/cert;
# BBCTRL_INSECURE=1 (--insecure) exists only as an explicit opt-in.
BBCTRL_CURL_OPTS :=
ifdef BBCTRL_CACERT
BBCTRL_CURL_OPTS += --cacert $(BBCTRL_CACERT)
endif
ifeq ($(BBCTRL_INSECURE),1)
BBCTRL_CURL_OPTS += --insecure
endif

all: $(HTML) $(RESOURCES)
	@for SUB in $(SUBPROJECTS); do $(MAKE) -C src/$$SUB; done

pkg: all $(AVR_FIRMWARE) bbserial
	./setup.py sdist
	# Inject an integrity manifest into the package (audit
	# Scripts-1): SHA256SUMS covers every file in the package and is
	# verified by update-bbctrl after extraction, before any package
	# code runs.  When UPDATE_SIGN_KEY points at an Ed25519 private
	# key, the manifest is also signed (SHA256SUMS.sig); controllers
	# with the matching public key baked in then *require* a valid
	# signature.  Without a key the manifest proves the package was
	# not corrupted or modified after it was built -- it does not by
	# itself prove authorship.
	rm -rf build/pkg-manifest
	mkdir -p build/pkg-manifest
	tar -xjf dist/$(PKG_NAME).tar.bz2 -C build/pkg-manifest
	cd build/pkg-manifest/$(PKG_NAME) && \
	  find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -print0 \
	    | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS
ifdef UPDATE_SIGN_KEY
	openssl pkeyutl -sign -inkey $(UPDATE_SIGN_KEY) -rawin \
	  -in build/pkg-manifest/$(PKG_NAME)/SHA256SUMS \
	  -out build/pkg-manifest/$(PKG_NAME)/SHA256SUMS.sig
endif
	tar -cjf dist/$(PKG_NAME).tar.bz2 -C build/pkg-manifest $(PKG_NAME)
	rm -rf build/pkg-manifest

bbserial:
	$(MAKE) -C src/bbserial

gplan: $(GPLAN_TARGET)

$(GPLAN_TARGET): $(GPLAN_MOD)
	cp $< $@

$(GPLAN_MOD): $(GPLAN_IMG)
	./scripts/gplan-init-build.sh
	cp ./scripts/gplan-build.sh rpi-share/
	chmod +x rpi-share/gplan-build.sh
	sudo ./scripts/rpi-chroot.sh $(GPLAN_IMG) /mnt/host/gplan-build.sh

$(GPLAN_IMG):
	./scripts/gplan-init-build.sh

.PHONY: $(AVR_FIRMWARE)
$(AVR_FIRMWARE):
	$(MAKE) -C src/avr

update: pkg
	@test -n "$(BBCTRL_PASSWORD)" || { \
	  echo "BBCTRL_PASSWORD is not set; refusing to send an update" \
	    "with a default or empty password (Scripts-12)." >&2; exit 1; }
	http_proxy= https_proxy= curl --fail -i -X PUT \
	  -H "Content-Type: multipart/form-data" $(BBCTRL_CURL_OPTS) \
	  -F "firmware=@dist/$(PKG_NAME).tar.bz2" \
	  -F "password=$(BBCTRL_PASSWORD)" \
	  https://$(HOST)/api/firmware/update
	@-tput sgr0 && echo # Fix terminal output

build/templates.pug: $(TEMPLS)
	mkdir -p build
	cat $(TEMPLS) >$@

node_modules: package.json package-lock.json
	npm ci && touch node_modules

$(TARGET_DIR)/%: src/resources/%
	install -D $< $@

# The Svelte bundle is a real target of its sources (audit
# Scripts-20): it is rebuilt only when a source changes, and the
# previous bundle is kept until the new build succeeds -- a failed
# build no longer deletes the last good dist/.
SVELTE_SRCS := $(shell find src/svelte-components/src \
    src/svelte-components/public -type f 2>/dev/null) \
    src/svelte-components/package.json \
    $(wildcard src/svelte-components/rollup.config.js \
      src/svelte-components/svelte.config.js)

src/svelte-components/dist: $(SVELTE_SRCS)
	@if [ -d $@ ]; then rm -rf $@.prev; mv $@ $@.prev; fi; \
	cd src/svelte-components && npm run build; \
	RC=$$?; cd ../..; \
	if [ $$RC -ne 0 ]; then \
	  rm -rf src/svelte-components/dist; \
	  if [ -d src/svelte-components/dist.prev ]; then \
	    mv src/svelte-components/dist.prev src/svelte-components/dist; \
	  fi; \
	  echo "Svelte build failed; previous bundle restored" >&2; \
	  exit $$RC; \
	fi; \
	rm -rf src/svelte-components/dist.prev; \
	touch $@

$(TARGET_DIR)/index.html: build/templates.pug
$(TARGET_DIR)/index.html: $(wildcard src/static/js/*)
$(TARGET_DIR)/index.html: $(wildcard src/static/css/*)
$(TARGET_DIR)/index.html: $(wildcard src/pug/templates/*)
$(TARGET_DIR)/index.html: $(wildcard src/js/*)
$(TARGET_DIR)/index.html: $(wildcard src/stylus/*)
$(TARGET_DIR)/index.html: src/resources/config-template.json
$(TARGET_DIR)/index.html: $(wildcard src/resources/onefinity*defaults.json)
$(TARGET_DIR)/index.html: $(wildcard src/svelte-components/dist/*)

$(TARGET_DIR)/%.html: src/pug/%.pug node_modules src/svelte-components/dist
	@mkdir -p $(TARGET_DIR)/svelte-components
	cp src/svelte-components/dist/* $(TARGET_DIR)/svelte-components/

	@mkdir -p $(TARGET_DIR)
	$(PUG) -O pug-opts.js -P $< -o $(TARGET_DIR) || (rm -f $@; exit 1)

# Clean only known build outputs (audit Scripts-18).  The previous
# `git clean -fxd` deleted every untracked and ignored file in the
# tree -- local configs, downloaded images, uncommitted work -- as a
# side effect of a routine build clean.  For a full preview of what
# git would remove, run `git clean -ndx` yourself.
clean:
	rm -rf build dist node_modules rpi-share src/svelte-components/dist

.PHONY: all install clean tidy pkg gplan lint pylint jshint bbserial