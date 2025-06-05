EXTENSION = pg_git
EXTVERSION = 0.4.0

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

DATA = sql/$(EXTENSION)--$(EXTVERSION).sql \
       $(filter-out sql/$(EXTENSION)--$(EXTVERSION).sql,$(wildcard sql/*.sql)) \
       $(wildcard sql/schema/*.sql) \
       $(wildcard sql/functions/*.sql)

TESTS := $(wildcard test/sql/*.sql)
REGRESS = $(patsubst test/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=test

include $(PGXS)

.PHONY: test
test:
	pg_prove -d postgres $(TESTS)

