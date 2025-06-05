-- Path: /sql/functions/029-pack-refs.sql
-- Pack refs for efficient repository access

CREATE TABLE pg_git.packed_refs (
    repo_id INTEGER REFERENCES repositories(id),
    ref_name TEXT NOT NULL,
    commit_hash TEXT NOT NULL REFERENCES commits(hash),
    peeled_hash TEXT REFERENCES commits(hash),
    packed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, ref_name)
);

CREATE OR REPLACE FUNCTION pg_git.pack_refs(
    p_repo_id INTEGER,
    p_all BOOLEAN DEFAULT FALSE
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Pack all refs or just frequently accessed ones
    INSERT INTO pg_git.packed_refs (repo_id, ref_name, commit_hash, peeled_hash)
    SELECT r.repo_id, r.name, r.commit_hash,
           CASE 
               WHEN t.target_hash IS NOT NULL THEN t.target_hash
               ELSE NULL
           END
    FROM refs r
    LEFT JOIN pg_git.tags t ON r.commit_hash = t.target_hash
    WHERE r.repo_id = p_repo_id
    AND (p_all OR r.name IN (
        SELECT name 
        FROM refs 
        WHERE repo_id = p_repo_id
        ORDER BY name DESC 
        LIMIT 100
    ))
    ON CONFLICT (repo_id, ref_name) DO UPDATE
    SET commit_hash = EXCLUDED.commit_hash,
        peeled_hash = EXCLUDED.peeled_hash,
        packed_at = CURRENT_TIMESTAMP;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.unpack_refs(
    p_repo_id INTEGER,
    p_ref_pattern TEXT DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM pg_git.packed_refs
    WHERE repo_id = p_repo_id
    AND (p_ref_pattern IS NULL OR ref_name LIKE p_ref_pattern);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.verify_packed_refs(
    p_repo_id INTEGER
) RETURNS TABLE (
    ref_name TEXT,
    is_valid BOOLEAN,
    error_message TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT pr.ref_name,
           CASE 
               WHEN r.commit_hash != pr.commit_hash THEN FALSE
               WHEN pr.peeled_hash IS NOT NULL AND 
                    NOT EXISTS (SELECT 1 FROM commits WHERE hash = pr.peeled_hash) THEN FALSE
               ELSE TRUE
           END as is_valid,
           CASE 
               WHEN r.commit_hash != pr.commit_hash THEN 'Commit hash mismatch'
               WHEN pr.peeled_hash IS NOT NULL AND 
                    NOT EXISTS (SELECT 1 FROM commits WHERE hash = pr.peeled_hash) THEN 'Invalid peeled hash'
               ELSE 'Valid'
           END as error_message
    FROM pg_git.packed_refs pr
    JOIN refs r ON r.name = pr.ref_name
    WHERE pr.repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;
