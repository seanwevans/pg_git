-- Path: /sql/functions/006-branch.sql
-- pg_git branch operations

CREATE OR REPLACE FUNCTION pggit.create_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_start_point TEXT DEFAULT NULL
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get commit hash from start point or HEAD
    IF p_start_point IS NULL THEN
        SELECT commit_hash INTO v_commit_hash
        FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD';
    ELSE
        v_commit_hash := p_start_point;
    END IF;

    -- Create branch reference
    INSERT INTO pggit.refs (repo_id, name, commit_hash)
    VALUES (p_repo_id, p_branch_name, v_commit_hash);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.list_branches(
    p_repo_id INTEGER
) RETURNS TABLE (
    name TEXT,
    commit_hash TEXT,
    is_current BOOLEAN
) SET search_path = pggit, public AS $$
SELECT 
    r.name,
    r.commit_hash,
    r.commit_hash = head.commit_hash AS is_current
FROM pggit.refs r
CROSS JOIN (SELECT commit_hash FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD') head
WHERE r.repo_id = p_repo_id AND r.name != 'HEAD'
ORDER BY r.name;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.checkout_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_create BOOLEAN DEFAULT FALSE
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get branch commit
    SELECT commit_hash INTO v_commit_hash
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_branch_name;
    
    IF NOT FOUND AND p_create THEN
        -- Create new branch from HEAD
        SELECT commit_hash INTO v_commit_hash
        FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD';
        
        INSERT INTO pggit.refs (repo_id, name, commit_hash)
        VALUES (p_repo_id, p_branch_name, v_commit_hash);
    ELSIF NOT FOUND THEN
        RAISE EXCEPTION 'Branch % does not exist', p_branch_name;
    END IF;

    -- Update HEAD
    UPDATE pggit.refs SET commit_hash = v_commit_hash
    WHERE repo_id = p_repo_id AND name = 'HEAD';

    RETURN v_commit_hash;
END;$$ LANGUAGE plpgsql;
