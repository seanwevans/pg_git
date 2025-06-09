-- Path: /sql/functions/009-reset.sql
-- pg_git reset operations

CREATE OR REPLACE FUNCTION pg_git.reset_soft(
    p_repo_id INTEGER,
    p_commit TEXT
) RETURNS VOID AS $$
BEGIN
    -- Move HEAD to specified commit
    UPDATE refs
    SET commit_hash = p_commit
    WHERE repo_id = p_repo_id AND name = 'HEAD';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.reset_mixed(
    p_repo_id INTEGER,
    p_commit TEXT
) RETURNS VOID AS $$
BEGIN
    -- Move HEAD and clear index
    PERFORM pg_git.reset_soft(p_repo_id, p_commit);
    DELETE FROM index_entries WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.reset_file(
    p_repo_id INTEGER,
    p_path TEXT,
    p_commit TEXT DEFAULT 'HEAD'
) RETURNS VOID AS $$
DECLARE
    v_tree_hash TEXT;
    v_blob_hash TEXT;
BEGIN
    -- Get tree from commit
    SELECT tree_hash INTO v_tree_hash
    FROM commits WHERE repo_id = p_repo_id AND hash = p_commit;
    
    -- Get blob hash from tree
    SELECT (e->>'hash')::TEXT INTO v_blob_hash
    FROM trees t,
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
END;
$$ LANGUAGE plpgsql;