-- Path: /sql/updates/pg_git--0.1.0--0.2.0.sql
-- pg_git update from version 0.1.0 to 0.2.0

-- Create schema if not exists
CREATE SCHEMA IF NOT EXISTS pg_git;

-- Create extension update path
ALTER EXTENSION pg_git UPDATE TO '0.2.0';

-- Add tags support
CREATE TABLE pg_git.tags (
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    target_hash TEXT NOT NULL,
    tagger TEXT NOT NULL,
    message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, name)
);

-- Add remote support
CREATE TABLE pg_git.remotes (
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, name)
);

CREATE TABLE pg_git.remote_refs (
    repo_id INTEGER,
    remote_name TEXT,
    ref_name TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    last_fetch TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, remote_name, ref_name),
    FOREIGN KEY (repo_id, remote_name) REFERENCES pg_git.remotes(repo_id, name)
);

-- Path: /sql/updates/pg_git--0.2.0.sql
-- pg_git initial installation

-- Create schema
CREATE SCHEMA pg_git;

-- Load core schema
\ir ../schema/001-core.sql
\ir ../schema/pgit-schema.sql

-- Load all functions in order
\ir ../functions/001-init.sql
\ir ../functions/002-add.sql
\ir ../functions/003-commit.sql
\ir ../functions/004-log.sql
\ir ../functions/005-status.sql
\ir ../functions/006-branch.sql
\ir ../functions/007-merge.sql
\ir ../functions/008-diff.sql
\ir ../functions/009-reset.sql
\ir ../functions/010-tag.sql
\ir ../functions/011-remote.sql