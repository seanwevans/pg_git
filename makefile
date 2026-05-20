SHELL := /bin/bash

EXTENSION = pg_git
EXTVERSION = 0.4.0

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

# PostgreSQL connection defaults for local development/testing.
PGDATABASE ?= postgres
PGHOST ?= localhost
PGPORT ?= 5432
PGUSER ?= postgres

# Shared psql command for test/preflight checks.
PSQL := psql -v ON_ERROR_STOP=1 -X -w -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE)

# Installable SQL assets only:
#   - extension install/upgrade entrypoints in sql/*.sql
#   - schema/function fragments loaded by those entrypoints
# Explicitly exclude non-extension artifacts accidentally placed in sql/.
DATA = \
       $(sort $(filter-out sql/pgit-ci.sql sql/pgit-control.sql, \
       $(wildcard sql/*.sql))) \
       $(wildcard sql/schema/*.sql) \
       $(wildcard sql/functions/*.sql)

# Deterministic, fast SQL tests that run on every change.
CORE_TESTS := \
       test/sql/init.sql \
       test/sql/add_test.sql \
       test/sql/branch_test.sql \
       test/sql/commit_test.sql \
       test/sql/diff_test.sql \
       test/sql/merge_test.sql \
       test/sql/remote_test.sql \
       test/sql/advanced_test.sql \
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

include $(PGXS)

.PHONY: test test-core test-integration test-performance test-all

# Keep `make test` as fast default.
test: test-core

test-core:
	pg_prove -d postgres $(CORE_TESTS)

test-integration:
	@if [ "$(RUN_INTEGRATION)" != "1" ]; then \
		echo "Skipping integration tests. Set RUN_INTEGRATION=1 to run them."; \
		exit 0; \
	fi
	pg_prove -d postgres $(INTEGRATION_TESTS)

test-performance:
	@if [ "$(RUN_PERF)" != "1" ]; then \
		echo "Skipping performance tests. Set RUN_PERF=1 to run them."; \
		exit 0; \
	fi
	pg_prove -d postgres $(PERFORMANCE_TESTS)

test-all: test-core test-integration test-performance
