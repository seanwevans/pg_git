-- Path: /sql/functions/009-reset.sql
-- pg_git reset operations

CREATE OR REPLACE FUNCTION pggit.reset_soft(
    p_repo_id INTEGER,
    p_commit TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    -- Move HEAD to specified commit
    UPDATE pggit.refs
    SET commit_hash = p_commit
    WHERE repo_id = p_repo_id AND name = 'HEAD';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.reset_mixed(
    p_repo_id INTEGER,
    p_commit TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    -- Move HEAD and clear index
    PERFORM pggit.reset_soft(p_repo_id, p_commit);
    DELETE FROM index_entries WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.reset_file(
    p_repo_id INTEGER,
    p_path TEXT,
    p_commit TEXT DEFAULT 'HEAD'
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
    v_tree_hash TEXT;
    v_blob_hash TEXT;
BEGIN
    -- Resolve p_commit: a ref name (e.g. the default 'HEAD' or a branch) maps to
    -- its commit hash; otherwise it is already a commit hash. Without this the
    -- default 'HEAD' is looked up as a literal commit hash, finds nothing, and
    -- the file is wrongly dropped from the index instead of restored.
    SELECT commit_hash INTO v_commit_hash
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_commit;
    v_commit_hash := COALESCE(v_commit_hash, p_commit);

    -- Get tree from commit
    SELECT tree_hash INTO v_tree_hash
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = v_commit_hash;
    
    -- Get blob hash from tree
    SELECT (e->>'hash')::TEXT INTO v_blob_hash
    FROM pggit.trees t,
    jsonb_array_elements(t.entries) e
    WHERE t.repo_id = p_repo_id AND t.hash = v_tree_hash
    AND e->>'name' = p_path;
    
    IF v_blob_hash IS NULL THEN
        -- File doesn't exist in commit, remove from index
        DELETE FROM index_entries 
        WHERE repo_id = p_repo_id AND path = p_path;
    ELSE
        -- Update index with blob from commit
        INSERT INTO index_entries (repo_id, path, blob_hash)
        VALUES (p_repo_id, p_path, v_blob_hash)
        ON CONFLICT (repo_id, path) 
        DO UPDATE SET blob_hash = v_blob_hash;
    END IF;
END;$$ LANGUAGE plpgsql;
