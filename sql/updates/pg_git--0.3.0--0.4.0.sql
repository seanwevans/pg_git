-- pg_git extension update from version 0.3.0 to 0.4.0

ALTER EXTENSION pg_git UPDATE TO '0.4.0';

-- Add new features for 0.4.0
\i ../pgit-archive.sql
\i ../pgit-submodule.sql
\i ../pgit-sparse.sql
\i ../pgit-merge-tree.sql
\i ../pgit-rerere.sql
\i ../pgit-diagnose.sql
\i ../pgit-verify-commit.sql
\i ../pgit-verify-tag.sql
\i ../pgit-whatchanged.sql
\i ../pgit-instaweb.sql
\i ../pgit-pack-refs.sql
\i ../pgit-repack.sql
\i ../pgit-replace.sql

COMMENT ON EXTENSION pg_git IS 'Git implementation in PostgreSQL - version 0.4.0';
