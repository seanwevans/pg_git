-- Path: /sql/functions/015-admin.sql
-- pg_git admin functions

CREATE OR REPLACE FUNCTION pg_git.gc(
    p_repo_id INTEGER
) RETURNS TABLE (
    object_type TEXT,
    objects_removed INTEGER,
    space_reclaimed BIGINT
) AS $$
DECLARE
    v_reachable_objects TEXT[];
BEGIN
    -- Collect all reachable objects
    WITH RECURSIVE reachable(object_type, hash) AS (
        -- Start from refs
        SELECT 'commit', commit_hash FROM refs WHERE repo_id = p_repo_id
        UNION
        -- Walk parent commits
        SELECT 'commit', c.parent_hash
        FROM commits c
        JOIN reachable r
          ON r.object_type = 'commit' AND c.repo_id = p_repo_id AND c.hash = r.hash
        WHERE c.parent_hash IS NOT NULL
        UNION
        -- Commits reference trees
        SELECT 'tree', c.tree_hash
        FROM commits c
        JOIN reachable r
          ON r.object_type = 'commit' AND c.repo_id = p_repo_id AND c.hash = r.hash
        UNION
        -- Trees reference blobs and subtrees
        SELECT (e->>'type')::TEXT, e->>'hash'
        FROM trees t
        JOIN reachable r
          ON r.object_type = 'tree' AND t.repo_id = p_repo_id AND t.hash = r.hash
        CROSS JOIN LATERAL jsonb_array_elements(t.entries) AS e
    )
    SELECT array_agg(DISTINCT hash) INTO v_reachable_objects FROM reachable;

    v_reachable_objects := COALESCE(v_reachable_objects, ARRAY[]::TEXT[]);

    -- Remove unreachable objects
    RETURN QUERY
    WITH deleted_blobs AS (
        DELETE FROM blobs
        WHERE repo_id = p_repo_id AND hash <> ALL(v_reachable_objects)
        RETURNING octet_length(content) AS size
    ), deleted_trees AS (
        DELETE FROM trees
        WHERE repo_id = p_repo_id AND hash <> ALL(v_reachable_objects)
        RETURNING octet_length(entries::TEXT) AS size
    ), deleted_commits AS (
        DELETE FROM commits
        WHERE repo_id = p_repo_id AND hash <> ALL(v_reachable_objects)
        RETURNING octet_length(message) AS size
    )
    SELECT 'blobs'::TEXT,
           count(*)::INTEGER,
           COALESCE(sum(size),0)::BIGINT FROM deleted_blobs
    UNION ALL
    SELECT 'trees'::TEXT,
           count(*)::INTEGER,
           COALESCE(sum(size),0)::BIGINT FROM deleted_trees
    UNION ALL
    SELECT 'commits'::TEXT,
           count(*)::INTEGER,
           COALESCE(sum(size),0)::BIGINT FROM deleted_commits;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.verify_integrity(
    p_repo_id INTEGER
) RETURNS TABLE (
    check_type TEXT,
    status TEXT,
    details TEXT
) AS $$
BEGIN
    -- Check dangling commits
    RETURN QUERY
    SELECT 'dangling_commits'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warning' END,
           count(*) || ' dangling commits found'
    FROM commits c
    WHERE c.repo_id = p_repo_id
      AND NOT EXISTS (SELECT 1 FROM refs r WHERE r.repo_id = p_repo_id AND r.commit_hash = c.hash);

    -- Check broken parent links
    RETURN QUERY
    SELECT 'broken_parents'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'error' END,
           count(*) || ' commits with invalid parent references'
    FROM commits c
    WHERE c.repo_id = p_repo_id
      AND c.parent_hash IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM commits p WHERE p.repo_id = p_repo_id AND p.hash = c.parent_hash);
    
    -- Check broken tree references
    RETURN QUERY
    SELECT 'broken_trees'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'error' END,
           count(*) || ' commits with invalid tree references'
    FROM commits c
    WHERE c.repo_id = p_repo_id
      AND NOT EXISTS (SELECT 1 FROM trees t WHERE t.repo_id = p_repo_id AND t.hash = c.tree_hash);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.optimize_indexes(
    p_repo_id INTEGER
) RETURNS TABLE (
    table_name TEXT,
    index_name TEXT,
    operation TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT t.tablename::TEXT,
           i.indexname::TEXT,
           'REINDEX'::TEXT
    FROM pg_tables t
    JOIN pg_indexes i ON i.tablename = t.tablename
    WHERE t.schemaname = 'pg_git'
    ORDER BY t.tablename, i.indexname;
    
    -- Actually perform the reindex
    FOR table_name, index_name, operation IN
        SELECT t.tablename::TEXT,
               i.indexname::TEXT,
               'REINDEX'::TEXT
        FROM pg_tables t
        JOIN pg_indexes i ON i.tablename = t.tablename
        WHERE t.schemaname = 'pg_git'
    LOOP
        EXECUTE format('REINDEX INDEX %I', index_name);
    END LOOP;
END;$$ LANGUAGE plpgsql;
