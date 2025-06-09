-- Path: /sql/updates/pg_git--0.3.0--0.4.0.sql

-- Update version
ALTER EXTENSION pg_git UPDATE TO '0.4.0';

-- Add new features
\i ../functions/019-archive.sql
\i ../functions/020-submodule.sql
\i ../functions/021-sparse-checkout.sql
\i ../functions/022-merge-tree.sql
\i ../functions/023-rerere.sql
\i ../functions/024-diagnose.sql
\i ../functions/025-verify-commit.sql
\i ../functions/026-verify-tag.sql
\i ../functions/027-whatchanged.sql
\i ../functions/028-instaweb.sql
\i ../functions/029-pack-refs.sql
\i ../functions/030-repack.sql
\i ../functions/031-replace.sql

COMMENT ON EXTENSION pg_git IS 'Git implementation in PostgreSQL - version 0.4.0';
