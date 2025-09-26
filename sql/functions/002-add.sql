
-- Schema for staging area (index)

-- Helper function to normalize file paths and prevent traversal
CREATE OR REPLACE FUNCTION normalize_path(p_path TEXT)
RETURNS TEXT AS $$
DECLARE
    v_parts TEXT[];
    v_stack TEXT[] := ARRAY[]::TEXT[];
    v_part TEXT;
BEGIN
    -- Reject absolute paths
    IF p_path LIKE '/%' THEN
        RAISE EXCEPTION 'Absolute paths are not allowed: %', p_path;
    END IF;

    -- Split and process path components
    v_parts := regexp_split_to_array(p_path, '/+');
    FOREACH v_part IN ARRAY v_parts LOOP
        IF v_part = '' OR v_part = '.' THEN
            CONTINUE;
        ELSIF v_part = '..' THEN
            -- Prevent traversing above repository root
            IF array_length(v_stack, 1) IS NULL THEN
                RAISE EXCEPTION 'Path traversal is not allowed: %', p_path;
            END IF;
            v_stack := v_stack[1:array_length(v_stack,1)-1];
        ELSE
            v_stack := v_stack || v_part;
        END IF;
    END LOOP;

    RETURN array_to_string(v_stack, '/');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to stage a file
CREATE OR REPLACE FUNCTION stage_file(
    p_repo_id INTEGER,
    p_path TEXT,
    p_content BYTEA,
    p_mode TEXT DEFAULT '100644'
) RETURNS TEXT AS $$
DECLARE
    v_blob_hash TEXT;
    v_norm_path TEXT;
BEGIN
    -- Normalize and validate path
    v_norm_path := normalize_path(p_path);

    -- Create blob from file content
    v_blob_hash := create_blob(p_repo_id, p_content);

    -- Update index
    INSERT INTO index_entries (repo_id, path, blob_hash, mode)
    VALUES (p_repo_id, v_norm_path, v_blob_hash, p_mode)
    ON CONFLICT (repo_id, path)
    DO UPDATE SET blob_hash = v_blob_hash, path = EXCLUDED.path, staged_at = CURRENT_TIMESTAMP;

    RETURN v_blob_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to unstage a file
CREATE OR REPLACE FUNCTION unstage_file(
    p_repo_id INTEGER,
    p_path TEXT
) RETURNS VOID AS $$
DECLARE
    v_norm_path TEXT;
BEGIN
    v_norm_path := normalize_path(p_path);

    DELETE FROM index_entries
    WHERE repo_id = p_repo_id AND path = v_norm_path;
END;$$ LANGUAGE plpgsql;
