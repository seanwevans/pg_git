SHELL := /bin/bash

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

# Authoritative test order lives in test/sql/manifest.txt.
TEST_MANIFEST := test/sql/manifest.txt
TESTS := $(shell sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$$/d' $(TEST_MANIFEST))

# Derive the target names from the TESTS list to keep them in sync.
REGRESS := $(notdir $(basename $(TESTS)))
REGRESS_OPTS = --inputdir=test

include $(PGXS)

.PHONY: test check-test-manifest
test: check-test-manifest
	pg_prove -d postgres $(TESTS)

check-test-manifest:
	@missing=$$(comm -23 \
		<(find test/sql -maxdepth 1 -type f -name '*_test.sql' | sort) \
		<(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$$/d' $(TEST_MANIFEST) | sort)); \
	if [ -n "$$missing" ]; then \
		echo "ERROR: test files missing from $(TEST_MANIFEST):"; \
		echo "$$missing"; \
		exit 1; \
	fi
