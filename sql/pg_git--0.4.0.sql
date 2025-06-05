-- pg_git extension version 0.4.0

CREATE SCHEMA pg_git;

-- Core schema
\ir schema/001-core.sql
\ir schema/pgit-schema.sql

-- Core functions
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

-- Additional features
\ir functions/012-migrations.sql
\ir functions/013-merge-conflicts.sql
\ir functions/014-https.sql
\ir functions/015-admin.sql
\ir pgit-advanced-commands.sql
\ir pgit-plumbing.sql
\ir pgit-extras.sql

-- Version 0.4 additions
\ir pgit-archive.sql
\ir pgit-submodule.sql
\ir pgit-sparse.sql
\ir pgit-merge-tree.sql
\ir pgit-rerere.sql
\ir pgit-diagnose.sql
\ir pgit-verify-commit.sql
\ir pgit-verify-tag.sql
\ir pgit-whatchanged.sql
\ir pgit-instaweb.sql
\ir pgit-pack-refs.sql
\ir pgit-repack.sql
\ir pgit-replace.sql

