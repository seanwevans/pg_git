-- Path: /sql/functions/007-merge.sql
-- pg_git merge operations

-- Most recent common ancestor of two commits. Commit hashes are globally unique,
-- so the repository is implied by the commits themselves. A recursive CTE allows
-- only one non-recursive and one recursive term, so each ancestor walk is its own
-- recursive CTE and the two are intersected.
CREATE OR REPLACE FUNCTION pggit.find_merge_base(
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
WITH RECURSIVE ancestors1 AS (
    SELECT hash, parent_hash, repo_id
    FROM pggit.commits
    WHERE hash = p_commit1
    UNION ALL
    SELECT c.hash, c.parent_hash, c.repo_id
    FROM pggit.commits c
    JOIN ancestors1 a ON a.repo_id = c.repo_id AND a.parent_hash = c.hash
),
ancestors2 AS (
    SELECT hash, parent_hash, repo_id
    FROM pggit.commits
    WHERE hash = p_commit2
    UNION ALL
    SELECT c.hash, c.parent_hash, c.repo_id
    FROM pggit.commits c
    JOIN ancestors2 a ON a.repo_id = c.repo_id AND a.parent_hash = c.hash
)
SELECT c.hash
FROM ancestors1 a1
JOIN ancestors2 a2 ON a1.repo_id = a2.repo_id AND a1.hash = a2.hash
JOIN pggit.commits c ON c.repo_id = a1.repo_id AND c.hash = a1.hash
ORDER BY c.timestamp DESC
LIMIT 1;
$$ LANGUAGE sql;

-- True when p_source is an ancestor of p_target, i.e. p_target can be
-- fast-forwarded onto p_source's history (p_source is reachable from p_target).
CREATE OR REPLACE FUNCTION pggit.can_fast_forward(
    p_source TEXT,
    p_target TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
WITH RECURSIVE ancestor_chain AS (
    SELECT hash, parent_hash, repo_id
    FROM pggit.commits
    WHERE hash = p_target
    UNION ALL
    SELECT c.hash, c.parent_hash, c.repo_id
    FROM pggit.commits c
    JOIN ancestor_chain ac ON ac.repo_id = c.repo_id AND ac.parent_hash = c.hash
)
SELECT EXISTS (
    SELECT 1 FROM ancestor_chain WHERE hash = p_source
);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.merge_branches(
    p_repo_id INTEGER,
    p_source_branch TEXT,
    p_target_branch TEXT DEFAULT 'HEAD'
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_source_commit TEXT;
    v_target_commit TEXT;
BEGIN
    -- Resolve both branches, failing clearly if either is missing.
    SELECT commit_hash INTO v_source_commit
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_source_branch;
    IF v_source_commit IS NULL THEN
        RAISE EXCEPTION 'Branch % does not exist', p_source_branch;
    END IF;

    SELECT commit_hash INTO v_target_commit
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_target_branch;
    IF v_target_commit IS NULL THEN
        RAISE EXCEPTION 'Branch % does not exist', p_target_branch;
    END IF;

    -- Fast-forward is possible when the target commit is an ancestor of the
    -- source commit; advance the target ref to the source commit.
    IF pggit.can_fast_forward(v_target_commit, v_source_commit) THEN
        UPDATE pggit.refs
        SET commit_hash = v_source_commit
        WHERE repo_id = p_repo_id AND name = p_target_branch;

        RETURN v_source_commit;
    END IF;

    -- For now, only support fast-forward merges
    RAISE EXCEPTION 'Only fast-forward merges are currently supported';
END;$$ LANGUAGE plpgsql;
