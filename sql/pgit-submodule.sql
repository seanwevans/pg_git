-- Path: /sql/functions/020-submodule.sql
-- Submodule support

CREATE TABLE pg_git.submodules (
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    url TEXT NOT NULL,
    branch TEXT DEFAULT 'main',
    commit_hash TEXT,
    PRIMARY KEY (repo_id, path)
);

CREATE OR REPLACE FUNCTION pg_git.submodule_add(
    p_repo_id INTEGER,
    p_repository_url TEXT,
    p_path TEXT,
    p_name TEXT DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    v_name TEXT;
    v_commit_hash TEXT;
BEGIN
    -- Generate name if not provided
    v_name := COALESCE(p_name, regexp_replace(p_path, '.*/', ''));
    
    -- Clone submodule
    v_commit_hash := pg_git.clone(p_repository_url, v_name, p_path);
    
    -- Register submodule
    INSERT INTO pg_git.submodules (repo_id, name, path, url, commit_hash)
    VALUES (p_repo_id, v_name, p_path, p_repository_url, v_commit_hash);
    
    RETURN v_commit_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.submodule_update(
    p_repo_id INTEGER,
    p_path TEXT DEFAULT NULL,
    p_recursive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    submodule_path TEXT,
    old_commit TEXT,
    new_commit TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH updated AS (
        SELECT s.path,
               s.commit_hash as old_commit,
               pg_git.pull(s.repo_id, 'origin', s.branch) as new_commit
        FROM pg_git.submodules s
        WHERE s.repo_id = p_repo_id
        AND (p_path IS NULL OR s.path = p_path)
        RETURNING *
    )
    UPDATE pg_git.submodules s
    SET commit_hash = u.new_commit
    FROM updated u
    WHERE s.repo_id = p_repo_id AND s.path = u.path
    RETURNING s.path, u.old_commit, u.new_commit;
    
    -- Handle recursive update
    IF p_recursive THEN
        RETURN QUERY
        SELECT * FROM pg_git.submodule_update_recursive(p_repo_id, p_path);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.submodule_update_recursive(
    p_repo_id INTEGER,
    p_path TEXT DEFAULT NULL
) RETURNS TABLE (
    submodule_path TEXT,
    old_commit TEXT,
    new_commit TEXT
) AS $$
DECLARE
    v_submodule RECORD;
BEGIN
    FOR v_submodule IN
        SELECT s.* 
        FROM pg_git.submodules s
        WHERE s.repo_id = p_repo_id
        AND (p_path IS NULL OR s.path = p_path)
    LOOP
        RETURN QUERY
        SELECT * FROM pg_git.submodule_update(v_submodule.repo_id, NULL, TRUE);
    END LOOP;
END;
$$ LANGUAGE plpgsql;