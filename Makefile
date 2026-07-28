# Thin task runner over scripts/. Not a build system: no compilation rules, no flags. CMake +
# Ninja own incremental correctness, the scripts own idempotency; this just gives developers
# and CI the same entry points so they cannot drift.

.DEFAULT_GOAL := help
SHELL := /bin/sh

.PHONY: help submodule toolchain deps build test all fixtures goldens bench check-upstream \
        update-deps patch unpatch clean distclean

help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	    | sort \
	    | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-15s\033[0m %s\n", $$1, $$2}'

submodule: ## check out the poppler submodule at its pinned commit
	@git submodule update --init --depth 1 third_party/poppler \
	    || git submodule update --init third_party/poppler

toolchain: ## download the pinned wasi-sdk into toolchain/
	@scripts/fetch-wasi-sdk.sh

deps: ## download the pinned zlib and freetype sources
	@scripts/fetch-deps.sh

build: submodule toolchain deps ## cross-compile everything into dist/
	@scripts/build.sh

test: ## run the golden and smoke tests against dist/
	@tests/run-tests.sh

all: build test ## build then test

fixtures: ## regenerate the test PDFs from the generator
	@python3 tests/fixtures/make_fixtures.py

goldens: ## regenerate expected outputs using a NATIVE poppler (manual; never run in CI)
	@tests/make-goldens.sh

bench: ## compare native pdftotext against the wasm module
	@tests/bench.sh

check-upstream: ## print the newest stable upstream poppler tag
	@scripts/check-upstream.sh

update-deps: ## repin freetype and zlib in versions.env to newest stable
	@scripts/update-deps.sh

patch: ## apply patches/poppler/*.patch to the submodule
	@scripts/apply-patches.sh

unpatch: ## restore a pristine poppler checkout
	@scripts/apply-patches.sh --reset

clean: ## remove build/ and dist/
	@rm -rf build dist

distclean: clean ## also remove the downloaded toolchain
	@rm -rf toolchain
