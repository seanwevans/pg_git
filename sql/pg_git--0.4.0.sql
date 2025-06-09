-- pg_git extension load script
CREATE SCHEMA IF NOT EXISTS pg_git;
\ir schema/001-core.sql
\ir schema/pgit-schema.sql

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

\ir functions/012-migrations.sql
\ir functions/013-merge-conflicts.sql
\ir functions/014-https.sql
\ir functions/015-admin.sql

\i pgit-archive.sql
\i pgit-advanced-commands.sql
\i pgit-bundle.sql
\i pgit-ci.sql
\i pgit-diagnose.sql
\i pgit-extras.sql
\i pgit-instaweb.sql
\i pgit-merge-tree.sql
\i pgit-pack-refs.sql
\i pgit-plumbing.sql
\i pgit-repack.sql
\i pgit-replace.sql
\i pgit-rerere.sql
\i pgit-sparse.sql
\i pgit-submodule.sql
\i pgit-update.sql
\i pgit-verify-commit.sql
\i pgit-verify-tag.sql
\i pgit-version.sql
\i pgit-version-updates.sql
\i pgit-whatchanged.sql
\i version-updates.sql
