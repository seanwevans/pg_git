-- Path: /sql/functions/027-whatchanged.sql
-- Whatchanged command implementation

CREATE OR REPLACE FUNCTION pg_git.whatchanged(
    p_repo_id INTEGER,
    p_since TEXT DEFAULT NULL,
    p_until TEXT DEFAULT 'HEAD',
    p_paths TEXT[] DEFAULT NULL
) RETURNS TABLE (
    commit_hash TEXT,
    author TEXT,
    timestamp TIMESTAMP WITH TIME ZONE,
    message TEXT,
    path TEXT,
    change_type TEXT,
    old_mode TEXT,
    new_mode TEXT,
    old_hash TEXT,
    new_hash TEXT
) AS $$
DECLARE
    v_since_hash TEXT;
    v_until_hash TEXT;
BEGIN
    -- Resolve commit references
    IF p_until = 'HEAD' THEN
        SELECT commit_hash INTO v_until_hash
        FROM refs WHERE name = 'HEAD';
    ELSE
        v_until_hash := p_until;
    END IF;

    -- Get commit history with changes
    RETURN QUERY
    WITH RECURSIVE commit_history AS (
        -- Start from until commit
        SELECT hash, parent_hash, author, timestamp, message, tree_hash
        FROM commits
        WHERE hash = v_until_hash
        
        UNION ALL
        
        -- Walk back through parents
        SELECT c.hash, c.parent_hash, c.author, c.timestamp, c.message, c.tree_hash
        FROM commits c
        JOIN commit_history ch ON c.hash = ch.parent_hash
        WHERE (p_since IS NULL OR c.hash != p_since)
    ),
    file_changes AS (
        SELECT 
            ch.hash as commit_hash,
            ch.author,
            ch.timestamp,
            ch.message,
            dt.path,
            dt.change_type,
            dt.old_mode,
            dt.new_mode,
            dt.old_hash,
            dt.new_hash
        FROM commit_history ch
        CROSS JOIN LATERAL (
            SELECT d.path,
                   CASE 
                       WHEN d.old_hash IS NULL THEN 'A'  -- Added
                       WHEN d.new_hash IS NULL THEN 'D'  -- Deleted
                       ELSE 'M'                          -- Modified
                   END as change_type,
                   t1.mode as old_mode,
                   t2.mode as new_mode,
                   d.old_hash,
                   d.new_hash
            FROM pg_git.diff_trees(
                (SELECT tree_hash FROM commits WHERE hash = ch.parent_hash),
                ch.tree_hash
            ) d
            LEFT JOIN pg_git.get_tree_entry(
                (SELECT tree_hash FROM commits WHERE hash = ch.parent_hash),
                d.path
            ) t1 ON TRUE
            LEFT JOIN pg_git.get_tree_entry(ch.tree_hash, d.path) t2 ON TRUE
            WHERE p_paths IS NULL OR d.path = ANY(p_paths)
        ) dt
    )
    SELECT *
    FROM file_changes
    ORDER BY timestamp DESC, commit_hash, path;
END;
$$ LANGUAGE plpgsql;

-- Helper function to get a single tree entry
CREATE OR REPLACE FUNCTION pg_git.get_tree_entry(
    p_tree_hash TEXT,
    p_path TEXT
) RETURNS TABLE (
    mode TEXT,
    type TEXT,
    hash TEXT
) AS $$
    SELECT (e->>'mode')::TEXT,
           (e->>'type')::TEXT,
           (e->>'hash')::TEXT
    FROM trees,
    jsonb_array_elements(entries) e
    WHERE hash = p_tree_hash
    AND e->>'name' = p_path;
$$ LANGUAGE sql;
