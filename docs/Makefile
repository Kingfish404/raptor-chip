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

.PHONY: help doctor check-ruby install serve build clean

help:
	@echo "Raptor docs — local preview (native Ruby + Bundler)"
	@echo ""
	@echo "  make install  Install gem dependencies into $(BUNDLE_PATH_DIR)/"
	@echo "  make serve    Start live-reload preview at http://$(HOST):$(PORT)"
	@echo "  make build    Build static site into _site/"
	@echo "  make clean    Remove _site/, vendor/, caches"
	@echo "  make doctor   Print the Ruby/Bundler actually used"
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

serve: install
	$(BUNDLE) exec jekyll serve --host $(HOST) --port $(PORT) --livereload --incremental

build: install
	$(BUNDLE) exec jekyll build

clean:
	rm -rf _site .jekyll-cache .sass-cache vendor Gemfile.lock .bundle
