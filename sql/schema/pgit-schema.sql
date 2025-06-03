-- Central schema definitions for PGit

CREATE TABLE index_entries (
    repo_id INTEGER REFERENCES repositories(id),
    path TEXT NOT NULL,
    blob_hash TEXT NOT NULL REFERENCES blobs(hash),
    mode TEXT NOT NULL DEFAULT '100644',
    staged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path)
);