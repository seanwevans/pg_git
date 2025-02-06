-- Path: /sql/functions/006-branch.sql
-- pg_git branch operations

CREATE OR REPLACE FUNCTION pg_git.create_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_start_point TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get commit hash from start point or HEAD
    IF p_start_point IS NULL THEN
        SELECT commit_hash INTO v_commit_hash
        FROM refs WHERE name = 'HEAD';
    ELSE
        v_commit_hash := p_start_point;
    END IF;

    -- Create branch reference
    INSERT INTO refs (name, commit_hash)
    VALUES (p_branch_name, v_commit_hash);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.list_branches(
    p_repo_id INTEGER
) RETURNS TABLE (
    name TEXT,
    commit_hash TEXT,
    is_current BOOLEAN
) AS $$
SELECT 
    r.name,
    r.commit_hash,
    r.commit_hash = head.commit_hash AS is_current
FROM refs r
CROSS JOIN (SELECT commit_hash FROM refs WHERE name = 'HEAD') head
WHERE r.name != 'HEAD'
ORDER BY r.name;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_git.checkout_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_create BOOLEAN DEFAULT FALSE
) RETURNS TEXT AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get branch commit
    SELECT commit_hash INTO v_commit_hash
    FROM refs WHERE name = p_branch_name;
    
    IF NOT FOUND AND p_create THEN
        -- Create new branch from HEAD
        SELECT commit_hash INTO v_commit_hash
        FROM refs WHERE name = 'HEAD';
        
        INSERT INTO refs (name, commit_hash)
        VALUES (p_branch_name, v_commit_hash);
    ELSIF NOT FOUND THEN
        RAISE EXCEPTION 'Branch % does not exist', p_branch_name;
    END IF;

    -- Update HEAD
    UPDATE refs SET commit_hash = v_commit_hash
    WHERE name = 'HEAD';

    RETURN v_commit_hash;
END;
$$ LANGUAGE plpgsql;