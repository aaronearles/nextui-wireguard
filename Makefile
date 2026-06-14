WG_VERSION ?= 1.0.20210914
WG_URL = https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-$(WG_VERSION).tar.xz
TRIPLE  = aarch64-linux-musl
CC      = $(TRIPLE)-gcc
OUTDIR  = bin/tg5040

.PHONY: all clean fetch package

all: fetch
	cd wireguard-tools-$(WG_VERSION)/src && \
	  $(MAKE) CC=$(CC) LDFLAGS="-static" WITH_WGQUICK=no WITH_SYSTEMDUNITS=no WITH_BASHCOMPLETION=no
	mkdir -p $(OUTDIR)
	cp wireguard-tools-$(WG_VERSION)/src/wg $(OUTDIR)/wg
	$(TRIPLE)-strip $(OUTDIR)/wg
	@echo "Built: $(OUTDIR)/wg ($$(file $(OUTDIR)/wg))"

fetch:
	@if [ ! -d wireguard-tools-$(WG_VERSION) ]; then \
	  curl -L $(WG_URL) | tar -xJ; \
	fi

clean:
	rm -rf wireguard-tools-$(WG_VERSION) $(OUTDIR)/wg build/

package: all
	mkdir -p build
	zip -r build/WireGuard.pak.zip \
	  launch.sh \
	  pak.json \
	  bin/tg5040/wg
	@echo "Package: build/WireGuard.pak.zip"
