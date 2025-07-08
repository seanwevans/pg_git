-- Path: /sql/functions/007-merge.sql
-- pg_git merge operations

CREATE OR REPLACE FUNCTION pg_git.find_merge_base(
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT AS $$
WITH RECURSIVE commit_ancestors AS (
    -- Get all ancestors of commit1
    SELECT hash, parent_hash, 1 AS source
    FROM commits 
    WHERE hash = p_commit1
    UNION ALL
    SELECT c.hash, c.parent_hash, 1
    FROM commits c
    JOIN commit_ancestors ca ON ca.parent_hash = c.hash
    WHERE ca.source = 1

    UNION ALL

    -- Get all ancestors of commit2
    SELECT hash, parent_hash, 2 AS source
    FROM commits 
    WHERE hash = p_commit2
    UNION ALL
    SELECT c.hash, c.parent_hash, 2
    FROM commits c
    JOIN commit_ancestors ca ON ca.parent_hash = c.hash
    WHERE ca.source = 2
)
SELECT hash
FROM (
    SELECT hash, array_agg(DISTINCT source) as sources
    FROM commit_ancestors
    GROUP BY hash
) a
WHERE array_length(sources, 1) > 1
ORDER BY (SELECT timestamp FROM commits WHERE hash = a.hash) DESC
LIMIT 1;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_git.can_fast_forward(
    p_source TEXT,
    p_target TEXT
) RETURNS BOOLEAN AS $$
WITH RECURSIVE ancestor_chain AS (
    SELECT hash, parent_hash
    FROM commits
    WHERE hash = p_target
    UNION ALL
    SELECT c.hash, c.parent_hash
    FROM commits c
    JOIN ancestor_chain ac ON ac.parent_hash = c.hash
)
SELECT EXISTS (
    SELECT 1 FROM ancestor_chain WHERE hash = p_source
);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_git.merge_branches(
    p_repo_id INTEGER,
    p_source_branch TEXT,
    p_target_branch TEXT DEFAULT 'HEAD'
) RETURNS TEXT AS $$
DECLARE
    v_source_commit TEXT;
    v_target_commit TEXT;
    v_merge_base TEXT;
BEGIN
    -- Get commit hashes
    SELECT commit_hash INTO v_source_commit
    FROM refs WHERE repo_id = p_repo_id AND name = p_source_branch;
    
    SELECT commit_hash INTO v_target_commit
    FROM refs WHERE repo_id = p_repo_id AND name = p_target_branch;
    
    -- Check if fast-forward is possible
    IF pg_git.can_fast_forward(v_source_commit, v_target_commit) THEN
        -- Fast-forward merge
        UPDATE refs
        SET commit_hash = v_source_commit
        WHERE repo_id = p_repo_id AND name = p_target_branch;
        
        RETURN v_source_commit;
    END IF;
    
    -- For now, only support fast-forward merges
    RAISE EXCEPTION 'Only fast-forward merges are currently supported';
END;$$ LANGUAGE plpgsql;
