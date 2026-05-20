EXTENSION = pg_git
EXTVERSION = 0.4.0

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

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
