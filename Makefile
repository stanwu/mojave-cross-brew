SHELL := /bin/bash
TOOLS := tmux tree htop bash nano vim screen rsync socat jq nvim

.PHONY: help setup list all clean clean-all deploy $(TOOLS)

help: ## Show this help
	@echo "Cross-compile tools for macOS Mojave (10.14 x86_64)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "  make <tool>       Build a single tool ($(TOOLS))"
	@echo "  make all          Build all tools"
	@echo ""

setup: ## Install build dependencies (needs sudo)
	./install-env.sh

list: ## List available tools
	./build.sh list

all: ## Build all tools
	./build.sh all

$(TOOLS): ## Build a specific tool
	./build.sh $@

clean: ## Remove build artifacts (keep toolchain)
	rm -rf sources/ output/ cross-sysroot/

clean-all: clean ## Remove everything (including osxcross)
	rm -rf osxcross/

deploy: ## Deploy all binaries in output/ to nboph2
	@test -d output/ || { echo "No output/ directory. Run 'make all' first."; exit 1; }
	@echo "Deploying to nboph2..."
	@for f in output/*; do \
		[ -f "$$f" ] && scp "$$f" nboph2:~/$$(basename "$$f") && echo "  ✓ $$(basename $$f)"; \
	done
	@[ -d output/nvim-macos ] && scp -r output/nvim-macos nboph2:~/ && echo "  ✓ nvim-macos/"; true
	@echo "Done. Run install-tmux-macos-mojave.sh on nboph2 to finalize."
