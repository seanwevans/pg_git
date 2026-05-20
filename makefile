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

# Register new SQL tests here in execution order (add matching test/sql/*.sql files to this list).
TESTS := \
       test/sql/init.sql \
       test/sql/add_test.sql \
       test/sql/branch_test.sql \
       test/sql/commit_test.sql \
       test/sql/diff_test.sql \
       test/sql/merge_test.sql \
       test/sql/remote_test.sql \
       test/sql/advanced_test.sql \
       test/sql/gc_test.sql \
       test/sql/https_fetch_test.sql \
       test/sql/optimize_indexes_test.sql \
       test/sql/gc_performance_test.sql



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
