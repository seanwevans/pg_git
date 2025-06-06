-- Path: /sql/functions/005-status.sql
-- pg_git status functions

CREATE OR REPLACE FUNCTION pg_git.get_status(
    p_repo_id INTEGER
) RETURNS TABLE (
    path TEXT,
    status TEXT,
    staged BOOLEAN
) AS $$
DECLARE
    v_head_commit TEXT;
    v_head_tree TEXT;
BEGIN
    -- Get HEAD commit and tree
    SELECT c.hash, c.tree_hash INTO v_head_commit, v_head_tree
    FROM refs r
    JOIN commits c ON r.repo_id = p_repo_id AND c.repo_id = r.repo_id AND r.commit_hash = c.hash
    WHERE r.repo_id = p_repo_id AND r.name = 'HEAD';

    RETURN QUERY
    -- Staged changes
    SELECT 
        i.path,
        CASE 
            WHEN NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(t.entries) e
                WHERE e->>'name' = i.path
            ) THEN 'new file'
            WHEN i.blob_hash != (
                SELECT e->>'hash'
                FROM jsonb_array_elements(t.entries) e
                WHERE e->>'name' = i.path
            ) THEN 'modified'
        END,
        TRUE
    FROM index_entries i
    LEFT JOIN trees t ON t.repo_id = p_repo_id AND t.hash = v_head_tree
    WHERE i.repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- Pretty format version
CREATE OR REPLACE FUNCTION pg_git.get_formatted_status(
    p_repo_id INTEGER
) RETURNS TEXT AS $$
DECLARE
    v_output TEXT;
BEGIN
    SELECT string_agg(
        CASE 
            WHEN staged THEN
                format('  %s: %s', status, path)
        END,
        E'\n'
    ) INTO v_output
    FROM pg_git.get_status(p_repo_id)
    WHERE status IS NOT NULL;

    RETURN format(
        'Changes to be committed:%s%s',
        E'\n',
        COALESCE(v_output, '  (no changes)')
    );
END;
$$ LANGUAGE plpgsql;