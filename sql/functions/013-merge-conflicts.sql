-- Path: /sql/functions/013-merge-conflicts.sql
-- pg_git merge conflict resolution

CREATE TABLE pggit.merge_conflicts (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    path TEXT NOT NULL,
    our_blob_hash TEXT,
    their_blob_hash TEXT,
    base_blob_hash TEXT,
    resolution_blob_hash TEXT,
    status TEXT CHECK (status IN ('unresolved', 'resolved', 'ignored')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path),
    FOREIGN KEY (repo_id, our_blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    FOREIGN KEY (repo_id, their_blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    FOREIGN KEY (repo_id, base_blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    FOREIGN KEY (repo_id, resolution_blob_hash) REFERENCES pggit.blobs(repo_id, hash)
);

-- A three-way merge of a single path needs no manual resolution when either
-- side is unchanged from the base (take the other side) or both sides resolve
-- to the same blob. Anything else is a genuine conflict. NULL means the file is
-- absent on that side (added or deleted), so IS [NOT] DISTINCT FROM is used to
-- compare hashes without tripping over NULL semantics.
CREATE OR REPLACE FUNCTION pggit.can_auto_merge(
    p_our_hash TEXT,
    p_their_hash TEXT,
    p_base_hash TEXT
) RETURNS BOOLEAN IMMUTABLE SET search_path = pggit, public AS $$
    SELECT p_our_hash IS NOT DISTINCT FROM p_their_hash   -- both sides agree
        OR p_our_hash IS NOT DISTINCT FROM p_base_hash    -- we didn't change it
        OR p_their_hash IS NOT DISTINCT FROM p_base_hash; -- they didn't change it
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.detect_conflicts(
    p_repo_id INTEGER,
    p_our_commit TEXT,
    p_their_commit TEXT
) RETURNS TABLE (
    path TEXT,
    conflict_type TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_base_commit TEXT;
    v_our_tree TEXT;
    v_their_tree TEXT;
    v_base_tree TEXT;
BEGIN
    -- Find merge base (find_merge_base identifies the repo from the commits).
    v_base_commit := pggit.find_merge_base(p_our_commit, p_their_commit);

    -- Resolve each commit to its tree. get_tree_files expects a tree hash, not
    -- a commit hash. A missing/NULL commit yields a NULL tree, i.e. no files.
    SELECT tree_hash INTO v_our_tree
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = p_our_commit;
    SELECT tree_hash INTO v_their_tree
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = p_their_commit;
    SELECT tree_hash INTO v_base_tree
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = v_base_commit;

    RETURN QUERY
    -- Columns are qualified via the function alias: the RETURNS TABLE OUT
    -- parameter "path" would otherwise shadow the unqualified column name.
    WITH our_files AS (
        SELECT gtf.path, gtf.blob_hash
        FROM pggit.get_tree_files(p_repo_id, v_our_tree) gtf
    ),
    their_files AS (
        SELECT gtf.path, gtf.blob_hash
        FROM pggit.get_tree_files(p_repo_id, v_their_tree) gtf
    ),
    base_files AS (
        SELECT gtf.path, gtf.blob_hash
        FROM pggit.get_tree_files(p_repo_id, v_base_tree) gtf
    )
    SELECT DISTINCT f.path,
           CASE
               WHEN o.blob_hash IS NULL AND t.blob_hash IS NOT NULL THEN 'deleted_modified'
               WHEN t.blob_hash IS NULL AND o.blob_hash IS NOT NULL THEN 'modified_deleted'
               WHEN b.blob_hash IS NULL THEN 'add_add'
               ELSE 'content'
           END as conflict_type
    FROM (SELECT our_files.path FROM our_files
          UNION SELECT their_files.path FROM their_files) f
    LEFT JOIN our_files o ON f.path = o.path
    LEFT JOIN their_files t ON f.path = t.path
    LEFT JOIN base_files b ON f.path = b.path
    WHERE NOT pggit.can_auto_merge(o.blob_hash, t.blob_hash, b.blob_hash);
END;$$ LANGUAGE plpgsql;
