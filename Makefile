WG_VERSION     ?= 1.0.20210914
WG_URL          = https://github.com/WireGuard/wireguard-tools/archive/refs/tags/v$(WG_VERSION).tar.gz
WG_DIR          = wireguard-tools-$(WG_VERSION)
TRIPLE          = aarch64-linux-musl
CC              = $(TRIPLE)-gcc
OUTDIR          = bin/tg5040
PAKMAN_VERSION ?= 0.24.17
PAKMAN_ZIP      = /tmp/Pakman-nextui.zip
PAKMAN_URL      = https://github.com/josegonzalez/pakman/releases/download/$(PAKMAN_VERSION)/Pakman-nextui.zip

.PHONY: all clean fetch tools package

all: fetch
	cd $(WG_DIR)/src && \
	  $(MAKE) CC=$(CC) LDFLAGS="-static" WITH_WGQUICK=no WITH_SYSTEMDUNITS=no WITH_BASHCOMPLETION=no
	mkdir -p $(OUTDIR)
	cp $(WG_DIR)/src/wg $(OUTDIR)/wg
	$(TRIPLE)-strip $(OUTDIR)/wg
	@echo "Built: $(OUTDIR)/wg ($$(file $(OUTDIR)/wg))"

fetch:
	@if [ ! -d $(WG_DIR) ]; then \
	  curl -fsSL $(WG_URL) | tar -xz; \
	fi

$(PAKMAN_ZIP):
	curl -fsSL -o $@ "$(PAKMAN_URL)"

tools: $(OUTDIR)/minui-list $(OUTDIR)/minui-presenter $(OUTDIR)/jq

$(OUTDIR)/minui-list: $(PAKMAN_ZIP)
	mkdir -p $(OUTDIR)
	unzip -j -o $< 'Pakman/Tools/tg5040/SSH Server.pak/bin/tg5040/minui-list' -d $(OUTDIR)/
	chmod +x $@

$(OUTDIR)/minui-presenter: $(PAKMAN_ZIP)
	mkdir -p $(OUTDIR)
	unzip -j -o $< 'Pakman/Tools/tg5040/SSH Server.pak/bin/tg5040/minui-presenter' -d $(OUTDIR)/
	chmod +x $@

$(OUTDIR)/jq: $(PAKMAN_ZIP)
	mkdir -p $(OUTDIR)
	unzip -j -o $< 'Pakman/Tools/tg5040/Search.pak/bin/arm64/jq' -d $(OUTDIR)/
	chmod +x $@

clean:
	rm -rf $(WG_DIR) $(OUTDIR)/wg build/

package: all tools
	mkdir -p build
	zip -r build/WireGuard.pak.zip \
	  launch.sh \
	  pak.json \
	  bin/tg5040/wg \
	  bin/tg5040/wireguard-go \
	  bin/tg5040/minui-list \
	  bin/tg5040/minui-presenter \
	  bin/tg5040/jq
	@echo "Package: build/WireGuard.pak.zip"
