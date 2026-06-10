PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin

.PHONY: help build test install uninstall app release-patch release-minor release-major metrics metrics-push clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

build: ## Build the package + CLI (debug)
	swift build

test: ## Run the EngramCore tests
	swift test

install: ## Build the release CLI and install it to $(BINDIR)/engram
	swift build -c release --product engram
	install -d "$(BINDIR)"
	install -m 0755 .build/release/engram "$(BINDIR)/engram"
	@echo "installed $(BINDIR)/engram"

uninstall: ## Remove the installed CLI
	rm -f "$(BINDIR)/engram"

app: ## Build the macOS app
	xcodebuild -project Engram/Engram.xcodeproj -scheme Engram -configuration Debug -destination 'platform=macOS' build

release-patch: ## Cut a patch release: bump, tag, push (CI builds, notarizes & publishes)
	@scripts/release.sh patch

release-minor: ## Cut a minor release: bump, tag, push (CI builds, notarizes & publishes)
	@scripts/release.sh minor

release-major: ## Cut a major release: bump, tag, push (CI builds, notarizes & publishes)
	@scripts/release.sh major

metrics: ## Compute code quality metrics → metrics/quality.json (used by /deslop)
	@uv run --with lizard scripts/metrics.py

metrics-push: ## Compute metrics and push to wandb (requires $PRIVATE_WANDB_API_KEY)
	@uv run --with lizard --with wandb scripts/metrics.py --use-wandb

clean: ## Remove build artifacts
	swift package clean
	rm -rf .build
