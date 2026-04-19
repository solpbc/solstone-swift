# solstone-swift — Makefile
#
# Universal sol pbc product targets. Wave 1 hopper lode replaces this with the
# full adapted extro-phone Makefile (sim, test, deploy, logs, crash, etc.).

.PHONY: install test ci format clean help

help:
	@echo "solstone-swift"
	@echo ""
	@echo "Wave 1 bootstrap placeholder. The Wave 1 hopper lode imports"
	@echo "extro-phone's Makefile and adapts it for solstone-swift."
	@echo ""
	@echo "Once Wave 1 ships, full target list lives here and includes:"
	@echo "  install, sim, sim-json, sim-launch, deploy, cycle, logs,"
	@echo "  test, test-build, test-fast, screenshot, crash, clean"

install:
	@echo "Wave 1 bootstrap: extro-phone source not yet imported — make install is a no-op until the shell lands."

test:
	@echo "Wave 1 bootstrap: no tests yet."

ci:
	@echo "Wave 1 bootstrap: no CI yet."

format:
	@echo "Wave 1 bootstrap: no source to format yet."

clean:
	rm -rf DerivedData/
	@echo "Cleaned DerivedData/ (will not exist until first build)."
