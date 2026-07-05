SHELL := /bin/bash

EXTENSION = pg_git
EXTVERSION = 0.4.0

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
HAVE_PGXS := $(if $(wildcard $(PGXS)),1,0)

# PostgreSQL connection defaults for local development/testing.
PGDATABASE ?= postgres
PGHOST ?= localhost
PGPORT ?= 5432
PGUSER ?= postgres

# Shared psql command for test/preflight checks.
PSQL := psql -v ON_ERROR_STOP=1 -X -w -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE)

# Shared pg_prove command honoring connection defaults/overrides. The extension
# installs into the pggit schema; tests reference its objects unqualified, so the
# session search_path includes pggit (public keeps pgtap and contrib visible).
# Tests that must prove search_path independence override this with SET LOCAL.
PG_PROVE := PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) PGOPTIONS='-c search_path=pggit,public' pg_prove

# Single-file install entrypoint loaded by CREATE EXTENSION. Because the
# CREATE EXTENSION machinery cannot process psql \i/\ir includes, this script
# is assembled from the modular SQL fragments below (see the rule near the end
# of this file). It is a generated artifact: edit the fragments, not this file.
EXT_SQL = sql/$(EXTENSION)--$(EXTVERSION).sql

# Fragments composing the install script, in load order:
#   1. schema    - base tables (repositories must precede its referencing tables)
#   2. functions - callable API, numbered to fix ordering
#   3. features  - advanced command modules
# CI/control fragments and version-upgrade scripts are intentionally excluded
# from a fresh install.
SCHEMA_PARTS = \
       sql/schema/001-core.sql \
       sql/schema/pgit-schema.sql
FUNCTION_PARTS = $(sort $(wildcard sql/functions/*.sql))
FEATURE_PARTS = $(sort $(filter-out \
       sql/pgit-ci.sql \
       sql/pgit-control.sql \
       sql/pgit-update.sql \
       sql/pgit-version.sql \
       sql/pgit-version-updates.sql \
       sql/pgit-version-updates-0.2.0--0.3.0.sql, \
       $(wildcard sql/pgit-*.sql)))
INSTALL_PARTS = $(SCHEMA_PARTS) $(FUNCTION_PARTS) $(FEATURE_PARTS)

# Only the assembled entrypoint is installed into the extension directory.
DATA = $(EXT_SQL)

# Deterministic, fast SQL tests that run on every change.
CORE_TESTS := \
       test/sql/init.sql \
       test/sql/add_test.sql \
       test/sql/branch_test.sql \
       test/sql/commit_test.sql \
       test/sql/diff_test.sql \
       test/sql/merge_test.sql \
       test/sql/merge_conflicts_test.sql \
       test/sql/remote_test.sql \
       test/sql/advanced_test.sql \
       test/sql/diagnose_test.sql \
       test/sql/revert_test.sql \
       test/sql/reset_test.sql \
       test/sql/ambiguous_column_regression_test.sql \
       test/sql/plumbing_test.sql \
       test/sql/search_path_qualification_test.sql \
       test/sql/gc_test.sql \
       test/sql/optimize_indexes_test.sql

# Slower/less deterministic suites are opt-in.
INTEGRATION_TESTS := \
       test/sql/https_fetch_test.sql

PERFORMANCE_TESTS := \
       test/sql/gc_performance_test.sql

# Backward-compatible aggregate for PGXS regress helpers.
TESTS := $(CORE_TESTS) $(INTEGRATION_TESTS) $(PERFORMANCE_TESTS)

# Derive the target names from the TESTS list to keep them in sync.
REGRESS := $(notdir $(basename $(TESTS)))
REGRESS_OPTS = --inputdir=test

ifeq ($(HAVE_PGXS),1)
include $(PGXS)
else
$(warning PGXS makefile not found at $(PGXS); build/install targets are unavailable in this environment.)
endif

# Assemble the single-file install script from the modular fragments. Plain
# concatenation in dependency order; the fragments contain no psql meta-commands.
$(EXT_SQL): $(INSTALL_PARTS)
	@printf '%s\n' \
	  '-- pg_git $(EXTVERSION)' \
	  '-- GENERATED FILE -- DO NOT EDIT.' \
	  '-- Assembled from sql/schema/*.sql, sql/functions/*.sql and sql/pgit-*.sql.' \
	  '-- Regenerate with: make $(EXT_SQL)' > $@
	@for f in $(INSTALL_PARTS); do \
	  printf '\n-- ===== %s =====\n' "$$f" >> $@; \
	  cat "$$f" >> $@; \
	done
	@echo "Generated $@ from $(words $(INSTALL_PARTS)) fragments."

# Ensure the entrypoint is (re)assembled as part of the default build.
all: $(EXT_SQL)

.PHONY: test test-core test-integration test-performance test-all test-one test-one-verbose check-pg_prove

check-pg_prove:
	@command -v pg_prove >/dev/null 2>&1 || { \
		echo "pg_prove not found. Install pgTAP test runner (e.g., apt install libtap-parser-sourcehandler-pgtap-perl)."; \
		exit 127; \
	}

# Keep `make test` as fast default.
test: test-core

test-core: check-pg_prove
	$(PG_PROVE) $(CORE_TESTS)

test-integration: check-pg_prove
	@if [ "$(RUN_INTEGRATION)" != "1" ]; then \
		echo "Skipping integration tests. Set RUN_INTEGRATION=1 to run them."; \
		exit 0; \
	fi
	$(PG_PROVE) $(INTEGRATION_TESTS)

test-performance: check-pg_prove
	@if [ "$(RUN_PERF)" != "1" ]; then \
		echo "Skipping performance tests. Set RUN_PERF=1 to run them."; \
		exit 0; \
	fi
	$(PG_PROVE) $(PERFORMANCE_TESTS)

test-all: test-core test-integration test-performance


# Run a single SQL test file (e.g., make test-one TEST=test/sql/merge_test.sql).
test-one: check-pg_prove
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-one TEST=test/sql/<name>.sql"; \
		exit 2; \
	fi
	$(PG_PROVE) $(TEST)

# Verbose single-test execution for local triage/debugging.
test-one-verbose: check-pg_prove
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-one-verbose TEST=test/sql/<name>.sql"; \
		exit 2; \
	fi
	$(PG_PROVE) --verbose $(TEST)
