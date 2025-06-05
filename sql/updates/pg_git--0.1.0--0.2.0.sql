-- pg_git extension update from version 0.1.0 to 0.2.0

CREATE SCHEMA IF NOT EXISTS pg_git;

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
