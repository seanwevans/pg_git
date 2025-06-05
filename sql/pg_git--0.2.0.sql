-- pg_git extension initial installation for version 0.2.0

CREATE SCHEMA pg_git;

-- Load core schema
\ir schema/001-core.sql
\ir schema/pgit-schema.sql

-- Load functions
\ir functions/001-init.sql
\ir functions/002-add.sql
\ir functions/003-commit.sql
\ir functions/004-log.sql
\ir functions/005-status.sql
\ir functions/006-branch.sql
\ir functions/007-merge.sql
\ir functions/008-diff.sql
\ir functions/009-reset.sql
\ir functions/010-tag.sql
\ir functions/011-remote.sql

COMMENT ON EXTENSION pg_git IS 'Git implementation in PostgreSQL - version 0.2.0';
