# Local preview for the Raptor documentation site.
#
# The site is rendered by GitHub Pages using Jekyll (see _config.yml).
# This Makefile drives the same Jekyll stack natively via Ruby + Bundler.
#
# Usage:
#   make install       # install gem dependencies into ./vendor/bundle
#   make serve         # start live-reload preview at http://localhost:4000
#   make build         # build static site into _site/
#   make clean         # remove _site/ and caches
#   make doctor        # show which Ruby/Bundler is being used
#   make agent-test    # check the built agent-facing site (after make install)
#
# Agent-facing documentation uses only built-in Liquid and the Pages plugins:
#   - <name>.txt selects a Markdown source, .html.md permalink, title, description,
#     and nav_order; llms.txt and sitemap.xml use these routes as their catalog.
#   - <name>.md.txt provides the conventional .md alias from that same source.
#   - _layouts/markdown.txt includes the source at build time, removes front
#     matter, adds the index directive, and makes documentation links absolute.
#   - index.md is the homepage's text equivalent; explore.md is its explorer guide.
# Add both route files when adding a manual page, then run agent-test. The check
# builds into a temporary directory and covers project, root, and nested baseurls.
#
# Check a published site with: npx afdocs check <site-url> --format scorecard
# For a preview, add --canonical-origin <published-site-url> to rewrite links.
# GitHub Pages cannot negotiate Accept: text/markdown; clients should use the
# advertised Markdown URLs. That check needs a server/proxy supporting Accept
# and Vary headers to pass. No client-side redirect can implement it for agents.
#
# Requirements (Ruby >= 3.0 is needed by recent Jekyll & Bundler):
#   macOS:  brew install ruby
#   Ubuntu: sudo apt install ruby-full build-essential zlib1g-dev
#
# The macOS system Ruby (2.6) is too old and is automatically bypassed if a
# newer Homebrew Ruby is detected.

PORT ?= 4000
HOST ?= 0.0.0.0

# -----------------------------------------------------------------------------
# Toolchain discovery
#
# Prefer, in order:
#   1. $RUBY_BIN_DIR (user override)
#   2. Homebrew Ruby   /opt/homebrew/opt/ruby/bin (Apple Silicon)
#   3. Homebrew Ruby   /usr/local/opt/ruby/bin    (Intel macOS)
#   4. rbenv shims     $HOME/.rbenv/shims
#   5. whatever `ruby` / `bundle` is on PATH
# -----------------------------------------------------------------------------

RUBY_BIN_DIR ?= $(firstword \
  $(wildcard /opt/homebrew/opt/ruby/bin) \
  $(wildcard /usr/local/opt/ruby/bin) \
  $(wildcard $(HOME)/.rbenv/shims))

ifeq ($(RUBY_BIN_DIR),)
RUBY   ?= ruby
BUNDLE ?= bundle
else
RUBY   ?= $(RUBY_BIN_DIR)/ruby
BUNDLE ?= $(RUBY_BIN_DIR)/bundle
export PATH := $(RUBY_BIN_DIR):$(PATH)
endif

BUNDLE_PATH_DIR := vendor/bundle

.PHONY: help doctor check-ruby install serve build clean portal-data portal-test agent-test

help:
	@echo "Raptor docs — product portal + manual (native Ruby + Bundler)"
	@echo ""
	@echo "  make install  Install gem dependencies into $(BUNDLE_PATH_DIR)/"
	@echo "  make serve    Start live-reload preview at http://$(HOST):$(PORT)/raptor-chip/"
	@echo "  make build    Build static site into _site/"
	@echo "  make clean    Remove _site/, vendor/, caches"
	@echo "  make doctor   Print the Ruby/Bundler actually used"
	@echo "  make portal-data  Extract RTL/Makefile JSON for the homepage explorer"
	@echo "  make portal-test  Run portal data and diagram checks (Python + Node.js)"
	@echo "  make agent-test   Build and check llms.txt, Markdown, links, and sitemap"
	@echo ""
	@echo "Variables: PORT=$(PORT) HOST=$(HOST) RUBY_BIN_DIR=$(RUBY_BIN_DIR)"

doctor:
	@echo "RUBY_BIN_DIR = $(RUBY_BIN_DIR)"
	@echo "RUBY         = $(RUBY)"
	@echo "BUNDLE       = $(BUNDLE)"
	@echo "--"
	@$(RUBY)   -v    || echo "  -> ruby not found"
	@$(BUNDLE) -v    || echo "  -> bundler not found"

# Fail fast with a helpful message if Ruby is too old.
check-ruby:
	@$(RUBY) -e 'require "rubygems"; \
	  v=Gem::Version.new(RUBY_VERSION); \
	  min=Gem::Version.new("3.0.0"); \
	  if v < min; \
	    warn "ERROR: Ruby #{RUBY_VERSION} is too old (need >= 3.0)."; \
	    warn "       macOS:  brew install ruby"; \
	    warn "       Ubuntu: sudo apt install ruby-full build-essential zlib1g-dev"; \
	    warn "       Then re-run this Makefile; it auto-detects Homebrew Ruby,"; \
	    warn "       or pass RUBY_BIN_DIR=/path/to/ruby/bin explicitly."; \
	    exit 1; \
	  end' >/dev/null
	@command -v $(BUNDLE) >/dev/null 2>&1 || { \
	  echo "ERROR: bundler not found at $(BUNDLE)"; \
	  echo "  Install with: $(RUBY_BIN_DIR)/gem install bundler"; \
	  exit 1; }

install: check-ruby Gemfile
	$(BUNDLE) config set --local path '$(BUNDLE_PATH_DIR)'
	$(BUNDLE) install

serve: install portal-data
	$(BUNDLE) exec jekyll serve --host $(HOST) --port $(PORT) --livereload --incremental

PYTHON ?= python3
NODE ?= node

portal-data:
	$(PYTHON) scripts/extract_portal_data.py

portal-test:
	$(PYTHON) scripts/test_pipeline_model.py
	$(PYTHON) scripts/test_extract_portal_data.py
	$(PYTHON) scripts/test_uarch_view_2d.py
	$(NODE) scripts/test_architecture_model.mjs

agent-test: check-ruby
	BUNDLE="$(BUNDLE)" $(PYTHON) scripts/test_agent_docs.py

build: install portal-data
	$(BUNDLE) exec jekyll build

clean:
	rm -rf _site .jekyll-cache .sass-cache vendor Gemfile.lock .bundle
