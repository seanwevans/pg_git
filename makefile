EXTENSION = pg_git
EXTVERSION = 0.2.0

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

DATA = $(wildcard sql/schema/*.sql) \
       $(wildcard sql/functions/*.sql) \
       $(wildcard sql/updates/*.sql)

TESTS := $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
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
