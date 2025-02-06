-- Path: /sql/schema/001-core.sql
-- Core tables and functions for PGit

CREATE TABLE repositories (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE blobs (
    hash TEXT PRIMARY KEY,
    content BYTEA NOT NULL
);

CREATE TABLE trees (
    hash TEXT PRIMARY KEY,
    entries JSONB NOT NULL  -- [{mode, type, hash, name}]
);

CREATE TABLE commits (
    hash TEXT PRIMARY KEY,
    tree_hash TEXT NOT NULL REFERENCES trees(hash),
    parent_hash TEXT REFERENCES commits(hash),
    author TEXT NOT NULL,
    message TEXT NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE refs (
    name TEXT PRIMARY KEY,
    commit_hash TEXT NOT NULL REFERENCES commits(hash)
);

CREATE TABLE index_entries (
    repo_id INTEGER REFERENCES repositories(id),
    path TEXT NOT NULL,
    blob_hash TEXT NOT NULL REFERENCES blobs(hash),
    mode TEXT NOT NULL DEFAULT '100644',
    staged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path)
);