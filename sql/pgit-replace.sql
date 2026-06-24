-- Path: /sql/functions/031-replace.sql
-- Replace object references

CREATE TABLE pggit.replacements (
    repo_id INTEGER REFERENCES repositories(id),
    original_hash TEXT NOT NULL,
    replacement_hash TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('commit', 'tree', 'blob')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, original_hash)
);

CREATE OR REPLACE FUNCTION pggit.replace(
    p_repo_id INTEGER,
    p_original TEXT,
    p_replacement TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_type TEXT;
BEGIN
    -- Determine object type
    IF EXISTS (SELECT 1 FROM commits WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'commit';
    ELSIF EXISTS (SELECT 1 FROM trees WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'tree';
    ELSIF EXISTS (SELECT 1 FROM blobs WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'blob';
    ELSE
        RAISE EXCEPTION 'Original object not found';
    END IF;

    -- Verify replacement exists and is the same object type
    IF NOT EXISTS (
        SELECT 1 FROM commits WHERE v_type = 'commit' AND repo_id = p_repo_id AND hash = p_replacement
        UNION ALL
        SELECT 1 FROM trees   WHERE v_type = 'tree'   AND repo_id = p_repo_id AND hash = p_replacement
        UNION ALL
        SELECT 1 FROM blobs   WHERE v_type = 'blob'   AND repo_id = p_repo_id AND hash = p_replacement
    ) THEN
        RAISE EXCEPTION 'Replacement object not found or wrong type';
    END IF;

    INSERT INTO pggit.replacements (repo_id, original_hash, replacement_hash, type)
    VALUES (p_repo_id, p_original, p_replacement, v_type)
    ON CONFLICT (repo_id, original_hash) 
    DO UPDATE SET replacement_hash = p_replacement;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.get_replaced_hash(
    p_repo_id INTEGER,
    p_hash TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    SELECT COALESCE(replacement_hash, p_hash)
    FROM pggit.replacements
    WHERE repo_id = p_repo_id
    AND original_hash = p_hash;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.remove_replace(
    p_repo_id INTEGER,
    p_original TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
    WITH deleted AS (
        DELETE FROM pggit.replacements
        WHERE repo_id = p_repo_id
        AND original_hash = p_original
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM deleted);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.list_replace(
    p_repo_id INTEGER
) RETURNS TABLE (
    original_hash TEXT,
    replacement_hash TEXT,
    type TEXT,
    created_at TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
    SELECT original_hash, replacement_hash, type, created_at
    FROM pggit.replacements
    WHERE repo_id = p_repo_id
    ORDER BY created_at DESC;
$$ LANGUAGE sql;
