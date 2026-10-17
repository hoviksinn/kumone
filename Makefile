# Kumone — macOS 26+ / Apple Silicon developer entry points.

.DEFAULT_GOAL := help
.PHONY: help build test app clean

help: ## Show this help
	@echo "Kumone make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the macOS arm64 app with SwiftPM
	@swift build --triple arm64-apple-macosx26.0

test: ## Build all tests, prepare Metal kernels and run the full arm64 suite
	@swift build --build-tests --triple arm64-apple-macosx26.0
	@set -eu; BIN_PATH="$$(swift build --triple arm64-apple-macosx26.0 --show-bin-path)"; \
	  Scripts/fetch-mlx-metallib.sh "$$BIN_PATH"; \
	  find "$$BIN_PATH" -type d -path '*.xctest/Contents/MacOS' -exec cp "$$BIN_PATH/mlx.metallib" {} \;
	@swift test --skip-build --triple arm64-apple-macosx26.0

app: ## Build and bundle the macOS arm64 .app (Scripts/build-app.sh)
	@Scripts/build-app.sh $(CONFIG)

clean: ## Remove SwiftPM build artifacts
	@swift package clean
	@rm -rf .build
