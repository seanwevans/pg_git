EXTENSION = pg_git
EXTVERSION = 0.4.0

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

DATA = $(wildcard sql/schema/*.sql) \
       $(wildcard sql/functions/*.sql) \
       $(wildcard sql/updates/*.sql)

TESTS := \
       test/sql/init.sql \
       test/sql/add_test.sql \
       test/sql/branch_test.sql \
       test/sql/commit_test.sql \
       test/sql/merge_test.sql \
       test/sql/remote_test.sql \
       test/sql/advanced_test.sql
REGRESS = init add_test branch_test commit_test merge_test remote_test advanced_test
REGRESS_OPTS = --inputdir=test

MODULES = $(wildcard src/*.c)

PG_CPPFLAGS = -I$(libpq_srcdir)
SHLIB_LINK = $(libpq)

include $(PGXS)

.PHONY: test
test:
	pg_prove -d postgres $(TESTS)

.PHONY: install
install: all
	$(MAKE) -C sql/schema install
	$(MAKE) -C sql/functions install
	$(MAKE) -C sql/updates install

.PHONY: clean
clean:
	rm -f $(OBJS) $(PROGRAM) $(PROGRAM).o
	rm -rf results/
