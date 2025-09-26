-- Central schema definitions for PGit

CREATE TABLE index_entries (
    repo_id INTEGER REFERENCES repositories(id),
    path TEXT NOT NULL,
    blob_hash TEXT NOT NULL,
    mode TEXT NOT NULL DEFAULT '100644',
    staged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (repo_id, blob_hash) REFERENCES pg_git.blobs(repo_id, hash),
    PRIMARY KEY (repo_id, path));
