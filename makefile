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

# Authoritative test order lives in test/sql/manifest.txt.
TEST_MANIFEST := test/sql/manifest.txt
TESTS := $(shell sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$$/d' $(TEST_MANIFEST))

# Derive the target names from the TESTS list to keep them in sync.
REGRESS := $(notdir $(basename $(TESTS)))
REGRESS_OPTS = --inputdir=test

include $(PGXS)

.PHONY: test test-preflight

test-preflight:
	@command -v pg_prove >/dev/null 2>&1 || { \
		echo "ERROR: pg_prove is not installed or not on PATH."; \
		echo "Install it via your package manager (often in postgresql-test/perl-Test-Harness-TAP packages)."; \
		exit 1; \
	}
	@$(PSQL) -c 'SELECT 1;' >/dev/null || { \
		echo "ERROR: unable to connect to PostgreSQL using PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE)."; \
		echo "Check credentials, host reachability, and that the database exists."; \
		exit 1; \
	}
	@$(PSQL) -tA -c "SELECT string_agg(e, ', ') FROM (VALUES ('pgcrypto'),('pg_trgm'),('plpython3u')) AS req(e) WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = req.e);" | \
		awk 'NF { printf "ERROR: missing required extensions: %s\n", $$0; print "Install with: CREATE EXTENSION <name>;"; exit 1 }'
	@echo "Preflight checks passed for PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE)."

test: test-preflight
	pg_prove -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE) $(TESTS)

.PHONY: test test-one test-one-verbose test-list
test:
	pg_prove -d postgres $(TESTS)

# Focused rerun for a single SQL test file: make test-one TEST=test/sql/merge_test.sql
test-one:
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-one TEST=test/sql/<file>.sql"; \
		exit 1; \
	fi
	pg_prove -d postgres $(TEST)

# Verbose focused rerun for richer diagnostics
test-one-verbose:
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-one-verbose TEST=test/sql/<file>.sql"; \
		exit 1; \
	fi
	pg_prove -v -d postgres $(TEST)

# Print registered SQL test files in execution order
test-list:
	@printf "%s\n" $(TESTS)
