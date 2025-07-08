-- Schema for staging area (index)

-- Function to stage a file
CREATE OR REPLACE FUNCTION stage_file(
    p_repo_id INTEGER,
    p_path TEXT,
    p_content BYTEA,
    p_mode TEXT DEFAULT '100644'
) RETURNS TEXT AS $$
DECLARE
    v_blob_hash TEXT;
BEGIN
    -- Create blob from file content
    v_blob_hash := create_blob(p_repo_id, p_content);
    
    -- Update index
    INSERT INTO index_entries (repo_id, path, blob_hash, mode)
    VALUES (p_repo_id, p_path, v_blob_hash, p_mode)
    ON CONFLICT (repo_id, path) 
    DO UPDATE SET blob_hash = v_blob_hash, staged_at = CURRENT_TIMESTAMP;
    
    RETURN v_blob_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to unstage a file
CREATE OR REPLACE FUNCTION unstage_file(
    p_repo_id INTEGER,
    p_path TEXT
) RETURNS VOID AS $$
BEGIN
    DELETE FROM index_entries 
    WHERE repo_id = p_repo_id AND path = p_path;
END;$$ LANGUAGE plpgsql;
