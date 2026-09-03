SHELL := /bin/bash

EXTNAME = pg_git
EXTVERSION = 0.5.0

# Optional companion extension carrying the HTTPS transport. It is split out
# because it is the only part of the project that needs plpython3u, which is
# untrusted and therefore unavailable on managed PostgreSQL. Its SQL is
# hand-written rather than assembled, so it needs no fragment list.
HTTPS_EXTNAME = pg_git_https
HTTPS_EXTVERSION = 0.1.0
HTTPS_SQL = sql/$(HTTPS_EXTNAME)--$(HTTPS_EXTVERSION).sql

# PGXS installs one <name>.control file per name listed here.
EXTENSION = $(EXTNAME) $(HTTPS_EXTNAME)

# A literal comma cannot be written directly inside a $(call) argument.
comma := ,

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
EXT_SQL = sql/$(EXTNAME)--$(EXTVERSION).sql

# Fragments composing the install script, in load order:
#   1. schema    - base tables (repositories must precede its referencing tables)
#   2. functions - callable API, numbered to fix ordering
#   3. features  - advanced command modules
# CI/control fragments are intentionally excluded from a fresh install.
SCHEMA_PARTS = \
       sql/schema/001-core.sql \
       sql/schema/pgit-schema.sql
FUNCTION_PARTS = $(sort $(wildcard sql/functions/*.sql))
FEATURE_PARTS = $(sort $(filter-out \
       sql/pgit-ci.sql \
       sql/pgit-control.sql, \
       $(wildcard sql/pgit-*.sql)))
INSTALL_PARTS = $(SCHEMA_PARTS) $(FUNCTION_PARTS) $(FEATURE_PARTS)

# Fragments attributed to each released version. A fresh install of version N is
# the concatenation of every list up to and including N, so the same fragments
# feed both the install entrypoint and the ALTER EXTENSION ... UPDATE scripts and
# the two can never disagree. `make check-parts` asserts that the union of these
# lists is exactly INSTALL_PARTS.
#
# 0.5.0 adds no fragments -- it only moves the HTTPS transport out of core -- so
# it has no list here.
V0_1_0_PARTS = \
       $(SCHEMA_PARTS) \
       sql/functions/001-init.sql \
       sql/functions/002-add.sql \
       sql/functions/003-commit.sql \
       sql/functions/004-log.sql \
       sql/functions/005-status.sql \
       sql/functions/006-branch.sql \
       sql/functions/007-merge.sql \
       sql/functions/008-diff.sql \
       sql/functions/009-reset.sql
V0_2_0_PARTS = \
       sql/functions/010-tag.sql \
       sql/functions/011-remote.sql
V0_3_0_PARTS = \
       sql/functions/012-migrations.sql \
       sql/functions/013-merge-conflicts.sql \
       sql/functions/015-admin.sql \
       sql/pgit-advanced-commands.sql \
       sql/pgit-extras.sql \
       sql/pgit-plumbing.sql
V0_4_0_PARTS = \
       sql/pgit-archive.sql \
       sql/pgit-bundle.sql \
       sql/pgit-diagnose.sql \
       sql/pgit-instaweb.sql \
       sql/pgit-merge-tree.sql \
       sql/pgit-pack-refs.sql \
       sql/pgit-repack.sql \
       sql/pgit-replace.sql \
       sql/pgit-rerere.sql \
       sql/pgit-sparse.sql \
       sql/pgit-submodule.sql \
       sql/pgit-verify-commit.sql \
       sql/pgit-verify-tag.sql \
       sql/pgit-whatchanged.sql

# ALTER EXTENSION pg_git UPDATE discovers these by filename only: PostgreSQL
# looks for $(EXTNAME)--<from>--<to>.sql in the extension directory and will
# not find a script under any other name.
UPGRADE_0_1_0_TO_0_2_0 = sql/$(EXTNAME)--0.1.0--0.2.0.sql
UPGRADE_0_2_0_TO_0_3_0 = sql/$(EXTNAME)--0.2.0--0.3.0.sql
UPGRADE_0_3_0_TO_0_4_0 = sql/$(EXTNAME)--0.3.0--0.4.0.sql
GENERATED_UPGRADE_SQL = \
       $(UPGRADE_0_1_0_TO_0_2_0) \
       $(UPGRADE_0_2_0_TO_0_3_0) \
       $(UPGRADE_0_3_0_TO_0_4_0)

# 0.4.0 -> 0.5.0 removes objects rather than adding them, so it is hand-written
# instead of assembled from install fragments.
UPGRADE_0_4_0_TO_0_5_0 = sql/$(EXTNAME)--0.4.0--0.5.0.sql
UPGRADE_SQL = $(GENERATED_UPGRADE_SQL) $(UPGRADE_0_4_0_TO_0_5_0)

# The assembled entrypoint plus every upgrade script must land in the extension
# directory; an upgrade script that is not installed is an upgrade path that
# does not exist. The companion extension ships its own control file and script.
DATA = $(EXT_SQL) $(UPGRADE_SQL) $(HTTPS_SQL)

# Deterministic, fast SQL tests that run on every change.
CORE_TESTS := \
       test/sql/init.sql \
       test/sql/add_test.sql \
       test/sql/branch_test.sql \
       test/sql/symbolic_head_test.sql \
       test/sql/commit_test.sql \
       test/sql/diff_test.sql \
       test/sql/merge_test.sql \
       test/sql/merge_conflicts_test.sql \
       test/sql/remote_test.sql \
       test/sql/advanced_test.sql \
       test/sql/archive_test.sql \
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

# Assemble a generated SQL script from the modular fragments. Plain
# concatenation in dependency order; the fragments contain no psql meta-commands
# (CREATE EXTENSION and ALTER EXTENSION ... UPDATE run the script through the
# server, which cannot process psql \i/\ir includes).
#   $(1) output path   $(2) title   $(3) source description   $(4) fragments
define assemble_sql
	@printf '%s\n' \
	  '-- pg_git $(2)' \
	  '-- GENERATED FILE -- DO NOT EDIT.' \
	  '-- $(3)' \
	  '-- Regenerate with: make $(1)' > $(1)
	@for f in $(4); do \
	  printf '\n-- ===== %s =====\n' "$$f" >> $(1); \
	  cat "$$f" >> $(1); \
	done
	@echo "Generated $(1) from $(words $(4)) fragments."
endef

$(EXT_SQL): $(INSTALL_PARTS)
	$(call assemble_sql,$@,$(EXTVERSION),Assembled from sql/schema/*.sql$(comma) sql/functions/*.sql and sql/pgit-*.sql.,$(INSTALL_PARTS))

# Upgrade deltas. Each script carries only the fragments introduced by its
# target version, so applying them in sequence over an older install reaches the
# same object set as a fresh install of the newer version.
$(UPGRADE_0_1_0_TO_0_2_0): $(V0_2_0_PARTS)
	$(call assemble_sql,$@,0.1.0 -> 0.2.0,Objects added in 0.2.0.,$(V0_2_0_PARTS))

$(UPGRADE_0_2_0_TO_0_3_0): $(V0_3_0_PARTS)
	$(call assemble_sql,$@,0.2.0 -> 0.3.0,Objects added in 0.3.0.,$(V0_3_0_PARTS))

$(UPGRADE_0_3_0_TO_0_4_0): $(V0_4_0_PARTS)
	$(call assemble_sql,$@,0.3.0 -> 0.4.0,Objects added in 0.4.0.,$(V0_4_0_PARTS))

# Fail if the committed generated SQL does not match what the fragments produce.
# `make` alone cannot catch this: it decides by timestamp, and in a fresh clone
# every file is written at about the same moment, so an out-of-date artifact can
# look up to date and get silently rebuilt (or not) without anyone noticing. -B
# forces the rebuild so the comparison is against real output.
.PHONY: check-generated
check-generated:
	@$(MAKE) --no-print-directory -B $(EXT_SQL)
	@if ! git diff --exit-code -- $(EXT_SQL); then \
		echo; \
		echo "$(EXT_SQL) is out of sync with the fragments it is generated from."; \
		echo "Run 'make $(EXT_SQL)' and commit the result; do not edit it by hand."; \
		exit 1; \
	fi
	@echo "$(EXT_SQL) matches its fragments."

.PHONY: test test-core test-integration test-performance test-all test-one test-one-verbose check-pg_prove

check-pg_prove:
	@command -v pg_prove >/dev/null 2>&1 || { \
		echo "pg_prove not found. Install pgTAP test runner (e.g., apt install libtap-parser-sourcehandler-pgtap-perl)."; \
		exit 127; \
	}

# Guard the invariant the upgrade scripts rest on: the per-version fragment
# lists must partition INSTALL_PARTS exactly. If a new fragment is added to the
# install without being attributed to a version, upgrading installs would
# silently miss it.
check-parts:
	@if [ "$(sort $(INSTALL_PARTS))" != "$(sort $(V0_1_0_PARTS) $(V0_2_0_PARTS) $(V0_3_0_PARTS) $(V0_4_0_PARTS))" ]; then \
		echo "Fragment lists are out of sync with INSTALL_PARTS."; \
		echo "  install : $(sort $(INSTALL_PARTS))"; \
		echo "  versions: $(sort $(V0_1_0_PARTS) $(V0_2_0_PARTS) $(V0_3_0_PARTS) $(V0_4_0_PARTS))"; \
		echo "Add the new fragment to the V0_x_y_PARTS list for the version that introduces it."; \
		exit 1; \
	fi
	@echo "Fragment lists cover every install fragment exactly once."

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
