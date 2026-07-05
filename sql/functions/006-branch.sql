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
    -- Resolve the start point: HEAD by default, otherwise a ref name (branch/tag)
    -- or a literal commit hash. Creating a branch does not move HEAD.
    IF p_start_point IS NULL THEN
        v_commit_hash := pggit.resolve_ref(p_repo_id, 'HEAD');
    ELSE
        v_commit_hash := COALESCE(pggit.resolve_ref(p_repo_id, p_start_point), p_start_point);
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
-- List direct branches (symbolic refs like HEAD are excluded). A branch is
-- current when HEAD symbolically points at it, so identically-positioned
-- branches are no longer all reported as current.
SELECT
    r.name,
    r.commit_hash,
    r.name = pggit.current_branch(p_repo_id) AS is_current
FROM pggit.refs r
WHERE r.repo_id = p_repo_id
  AND r.name <> 'HEAD'
  AND r.commit_hash IS NOT NULL
ORDER BY r.name;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.checkout_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_create BOOLEAN DEFAULT FALSE
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_exists BOOLEAN;
    v_commit_hash TEXT;
BEGIN
    SELECT TRUE INTO v_exists
    FROM pggit.refs
    WHERE repo_id = p_repo_id AND name = p_branch_name AND commit_hash IS NOT NULL;

    IF NOT FOUND AND p_create THEN
        -- Create the new branch at the current HEAD commit.
        v_commit_hash := pggit.resolve_ref(p_repo_id, 'HEAD');
        INSERT INTO pggit.refs (repo_id, name, commit_hash)
        VALUES (p_repo_id, p_branch_name, v_commit_hash);
    ELSIF NOT FOUND THEN
        RAISE EXCEPTION 'Branch % does not exist', p_branch_name;
    END IF;

    -- Attach HEAD to the branch (symbolic), then report its commit.
    PERFORM pggit.set_head_symbolic(p_repo_id, p_branch_name);

    RETURN pggit.resolve_ref(p_repo_id, p_branch_name);
END;$$ LANGUAGE plpgsql;
