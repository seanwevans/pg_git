-- Path: /sql/functions/013-merge-conflicts.sql
-- pg_git merge conflict resolution

CREATE TABLE pg_git.merge_conflicts (
    repo_id INTEGER REFERENCES repositories(id),
    path TEXT NOT NULL,
    our_blob_hash TEXT REFERENCES blobs(hash),
    their_blob_hash TEXT REFERENCES blobs(hash),
    base_blob_hash TEXT REFERENCES blobs(hash),
    resolution_blob_hash TEXT REFERENCES blobs(hash),
    status TEXT CHECK (status IN ('unresolved', 'resolved', 'ignored')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path)
);

CREATE OR REPLACE FUNCTION pg_git.detect_conflicts(
    p_repo_id INTEGER,
    p_our_commit TEXT,
    p_their_commit TEXT
) RETURNS TABLE (
    path TEXT,
    conflict_type TEXT
) AS $$
DECLARE
    v_base_commit TEXT;
BEGIN
    -- Find merge base
    v_base_commit := pg_git.find_merge_base(p_our_commit, p_their_commit);
    
    RETURN QUERY
    WITH our_files AS (
        SELECT path, blob_hash
        FROM pg_git.get_tree_files(p_our_commit)
    ),
    their_files AS (
        SELECT path, blob_hash
        FROM pg_git.get_tree_files(p_their_commit)
    ),
    base_files AS (
        SELECT path, blob_hash
        FROM pg_git.get_tree_files(v_base_commit)
    )
    SELECT DISTINCT f.path,
           CASE
               WHEN o.blob_hash != t.blob_hash 
                    AND b.blob_hash IS NOT NULL THEN 'content'
               WHEN o.blob_hash IS NULL 
                    AND t.blob_hash IS NOT NULL THEN 'deleted_modified'
               ELSE 'add_add'
           END as conflict_type
    FROM (SELECT path FROM our_files 
          UNION SELECT path FROM their_files) f
    LEFT JOIN our_files o ON f.path = o.path
    LEFT JOIN their_files t ON f.path = t.path
    LEFT JOIN base_files b ON f.path = b.path
    WHERE (o.blob_hash != t.blob_hash OR o.blob_hash IS NULL OR t.blob_hash IS NULL)
    AND NOT pg_git.can_auto_merge(o.blob_hash, t.blob_hash, b.blob_hash);
END;
$$ LANGUAGE plpgsql;