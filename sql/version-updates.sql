-- Path: /sql/updates/pg_git--0.2.0--0.3.0.sql

-- Update version
ALTER EXTENSION pg_git UPDATE TO '0.3.0';

-- Add new features
\i ../functions/012-migrations.sql
\i ../functions/013-merge-conflicts.sql
\i ../functions/014-https.sql
\i ../functions/015-admin.sql
\i ../functions/016-advanced-commands.sql
\i ../functions/017-plumbing.sql
\i ../functions/018-extras.sql

COMMENT ON EXTENSION pg_git IS 'Git implementation in PostgreSQL - version 0.3.0';
