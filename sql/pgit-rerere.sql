-- Path: /sql/functions/023-rerere.sql
-- Reuse recorded resolution

CREATE TABLE pg_git.rerere_cache (
    repo_id INTEGER REFERENCES repositories(id),
    conflict_hash TEXT NOT NULL,
    path TEXT NOT NULL,
    resolution_blob_hash TEXT REFERENCES blobs(hash),
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    used_count INTEGER DEFAULT 0,
    last_used TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (repo_id, conflict_hash, path)
);

CREATE OR REPLACE FUNCTION pg_git.hash_conflict(
    p_our_blob TEXT,
    p_their_blob TEXT
) RETURNS TEXT AS $$
    SELECT encode(sha256(
        COALESCE(o.content, ''::BYTEA) || 
        COALESCE(t.content, ''::BYTEA)
    ), 'hex')
    FROM blobs o
    FULL OUTER JOIN blobs t ON TRUE
    WHERE o.hash = p_our_blob
    AND t.hash = p_their_blob;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_git.record_resolution(
    p_repo_id INTEGER,
    p_path TEXT,
    p_our_blob TEXT,
    p_their_blob TEXT,
    p_resolution_blob TEXT
) RETURNS VOID AS $$
DECLARE
    v_conflict_hash TEXT;
BEGIN
    v_conflict_hash := pg_git.hash_conflict(p_our_blob, p_their_blob);
    
    INSERT INTO pg_git.rerere_cache (
        repo_id, conflict_hash, path, resolution_blob_hash
    ) VALUES (
        p_repo_id, v_conflict_hash, p_path, p_resolution_blob
    )
    ON CONFLICT (repo_id, conflict_hash, path) 
    DO UPDATE SET 
        resolution_blob_hash = p_resolution_blob,
        recorded_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.find_resolution(
    p_repo_id INTEGER,
    p_path TEXT,
    p_our_blob TEXT,
    p_their_blob TEXT
) RETURNS TEXT AS $$
DECLARE
    v_conflict_hash TEXT;
    v_resolution_hash TEXT;
BEGIN
    v_conflict_hash := pg_git.hash_conflict(p_our_blob, p_their_blob);
    
    UPDATE pg_git.rerere_cache
    SET used_count = used_count + 1,
        last_used = CURRENT_TIMESTAMP
    WHERE repo_id = p_repo_id
    AND conflict_hash = v_conflict_hash
    AND path = p_path
    RETURNING resolution_blob_hash INTO v_resolution_hash;
    
    RETURN v_resolution_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.clear_rerere_cache(
    p_repo_id INTEGER,
    p_older_than INTERVAL DEFAULT NULL
) RETURNS INTEGER AS $$
    DELETE FROM pg_git.rerere_cache
    WHERE repo_id = p_repo_id
    AND (
        p_older_than IS NULL OR
        recorded_at < (CURRENT_TIMESTAMP - p_older_than)
    )
    RETURNING 1;
$$ LANGUAGE sql;