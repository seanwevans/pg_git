-- Path: /sql/functions/004-log.sql
-- pg_git log functions

CREATE OR REPLACE FUNCTION pg_git.get_log(
    p_repo_id INTEGER,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    hash TEXT,
    tree_hash TEXT,
    parent_hash TEXT,
    author TEXT,
    message TEXT,
    timestamp TIMESTAMP WITH TIME ZONE
) AS $$
DECLARE
    v_head_commit TEXT;
BEGIN
    -- Get HEAD commit
    SELECT commit_hash INTO v_head_commit
    FROM refs
    WHERE name = 'HEAD';

    RETURN QUERY
    WITH RECURSIVE commit_log AS (
        SELECT c.*
        FROM commits c
        WHERE hash = v_head_commit

        UNION ALL

        SELECT c.*
        FROM commits c
        INNER JOIN commit_log cl ON c.hash = cl.parent_hash
    )
    SELECT *
    FROM commit_log
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Pretty format version with commit decoration
CREATE OR REPLACE FUNCTION pg_git.get_decorated_log(
    p_repo_id INTEGER,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    commit_line TEXT,
    refs TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    WITH commit_refs AS (
        SELECT c.hash,
               c.message,
               c.author,
               c.timestamp,
               array_agg(r.name) as ref_names
        FROM pg_git.get_log(p_repo_id, p_limit) c
        LEFT JOIN refs r ON c.hash = r.commit_hash
        GROUP BY c.hash, c.message, c.author, c.timestamp
    )
    SELECT 
        format('commit %s%sAuthor: %s%sDate: %s%s%s%s',
            substr(hash, 1, 8),
            E'\n',
            author,
            E'\n',
            timestamp,
            E'\n',
            E'\n    ',
            message
        ) as commit_line,
        ref_names
    FROM commit_refs
    ORDER BY timestamp DESC;
END;
$$ LANGUAGE plpgsql;