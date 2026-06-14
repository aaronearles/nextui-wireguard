WG_VERSION ?= 1.0.20210914
WG_URL = https://github.com/WireGuard/wireguard-tools/archive/refs/tags/v$(WG_VERSION).tar.gz
WG_DIR  = wireguard-tools-$(WG_VERSION)
TRIPLE  = aarch64-linux-musl
CC      = $(TRIPLE)-gcc
OUTDIR  = bin/tg5040

.PHONY: all clean fetch package

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

clean:
	rm -rf $(WG_DIR) $(OUTDIR)/wg build/

package: all
	mkdir -p build
	zip -r build/WireGuard.pak.zip \
	  launch.sh \
	  pak.json \
	  bin/tg5040/wg
	@echo "Package: build/WireGuard.pak.zip"
