-- Path: /sql/functions/004-log.sql
-- pg_git log functions

CREATE OR REPLACE FUNCTION pggit.get_log(
    p_repo_id INTEGER,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    hash TEXT,
    tree_hash TEXT,
    parent_hash TEXT,
    author TEXT,
    message TEXT,
    "timestamp" TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
DECLARE
    v_head_commit TEXT;
BEGIN
    -- Get HEAD commit (following the symbolic ref to the current branch tip)
    v_head_commit := pggit.resolve_ref(p_repo_id, 'HEAD');

    RETURN QUERY
    WITH RECURSIVE commit_log AS (
        SELECT c.*
        FROM pggit.commits c
        WHERE c.repo_id = p_repo_id AND c.hash = v_head_commit

        UNION ALL

        SELECT c.*
        FROM pggit.commits c
        INNER JOIN commit_log cl ON c.repo_id = p_repo_id AND c.hash = cl.parent_hash
    )
    SELECT commit_log.hash, commit_log.tree_hash, commit_log.parent_hash,
           commit_log.author, commit_log.message, commit_log."timestamp"
    FROM commit_log
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Pretty format version with commit decoration
CREATE OR REPLACE FUNCTION pggit.get_decorated_log(
    p_repo_id INTEGER,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    commit_line TEXT,
    refs TEXT[]
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH commit_refs AS (
        SELECT c.hash,
               c.message,
               c.author,
               c.timestamp,
               array_agg(r.name) FILTER (WHERE r.name <> 'HEAD') as ref_names
        FROM pggit.get_log(p_repo_id, p_limit) c
        LEFT JOIN pggit.refs r ON r.repo_id = p_repo_id AND c.hash = r.commit_hash
        GROUP BY c.hash, c.message, c.author, c.timestamp
    )
    SELECT 
        format('commit %s%sAuthor: %s%sDate: %s%s%s%s',
            substr(hash, 1, 8),
            E'\n',
            author,
            E'\n',
            "timestamp",
            E'\n',
            E'\n    ',
            message
        ) as commit_line,
        ref_names
    FROM commit_refs
    ORDER BY "timestamp" DESC;
END;$$ LANGUAGE plpgsql;
