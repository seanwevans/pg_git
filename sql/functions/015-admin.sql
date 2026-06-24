-- Path: /sql/functions/015-admin.sql
-- pg_git admin functions

CREATE OR REPLACE FUNCTION pggit.gc(
    p_repo_id INTEGER
) RETURNS TABLE (
    object_type TEXT,
    objects_removed INTEGER,
    space_reclaimed BIGINT
) SET search_path = pggit, public AS $$
BEGIN
    -- Ensure temporary table does not exist from prior runs
    DROP TABLE IF EXISTS tmp_reachable_objects;

    -- Collect all reachable objects into a temporary table
    CREATE TEMP TABLE tmp_reachable_objects(hash TEXT PRIMARY KEY) ON COMMIT DROP;

    -- PostgreSQL recursive CTEs allow only a single self-reference in the
    -- recursive term, so the different edge types (commit->parent, commit->tree,
    -- tree->entries) are expanded in one LATERAL branch off the working row.
    WITH RECURSIVE reachable(object_type, hash) AS (
        -- Start from pggit.refs
        SELECT 'commit'::TEXT, commit_hash FROM pggit.refs WHERE repo_id = p_repo_id
        UNION
        SELECT nxt.object_type, nxt.hash
        FROM reachable r
        CROSS JOIN LATERAL (
            -- Walk parent commits
            SELECT 'commit'::TEXT AS object_type, c.parent_hash AS hash
            FROM pggit.commits c
            WHERE r.object_type = 'commit' AND c.repo_id = p_repo_id
              AND c.hash = r.hash AND c.parent_hash IS NOT NULL
            UNION ALL
            -- Commits reference trees
            SELECT 'tree'::TEXT, c.tree_hash
            FROM pggit.commits c
            WHERE r.object_type = 'commit' AND c.repo_id = p_repo_id AND c.hash = r.hash
            UNION ALL
            -- Trees reference blobs and subtrees
            SELECT (e->>'type')::TEXT, e->>'hash'
            FROM pggit.trees t
            CROSS JOIN LATERAL jsonb_array_elements(t.entries) AS e
            WHERE r.object_type = 'tree' AND t.repo_id = p_repo_id AND t.hash = r.hash
        ) nxt
        WHERE nxt.hash IS NOT NULL
    )
    INSERT INTO tmp_reachable_objects
    SELECT DISTINCT hash FROM reachable;

    -- Remove unreachable objects
    RETURN QUERY
    WITH deleted_blobs AS (
        DELETE FROM pggit.blobs b
        WHERE b.repo_id = p_repo_id AND NOT EXISTS (
            SELECT 1 FROM tmp_reachable_objects r WHERE r.hash = b.hash
        )
        RETURNING octet_length(content) AS size
    ), deleted_trees AS (
        DELETE FROM pggit.trees t
        WHERE t.repo_id = p_repo_id AND NOT EXISTS (
            SELECT 1 FROM tmp_reachable_objects r WHERE r.hash = t.hash
        )
        RETURNING octet_length(entries::TEXT) AS size
    ), deleted_commits AS (
        DELETE FROM pggit.commits c
        WHERE c.repo_id = p_repo_id AND NOT EXISTS (
            SELECT 1 FROM tmp_reachable_objects r WHERE r.hash = c.hash
        )
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

    -- Explicitly drop temporary table
    DROP TABLE IF EXISTS tmp_reachable_objects;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_integrity(
    p_repo_id INTEGER
) RETURNS TABLE (
    check_type TEXT,
    status TEXT,
    details TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Check dangling pggit.commits
    RETURN QUERY
    SELECT 'dangling_commits'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warning' END,
           count(*) || ' dangling pggit.commits found'
    FROM pggit.commits c
    WHERE c.repo_id = p_repo_id
      AND NOT EXISTS (SELECT 1 FROM pggit.refs r WHERE r.repo_id = p_repo_id AND r.commit_hash = c.hash);

    -- Check broken parent links
    RETURN QUERY
    SELECT 'broken_parents'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'error' END,
           count(*) || ' pggit.commits with invalid parent references'
    FROM pggit.commits c
    WHERE c.repo_id = p_repo_id
      AND c.parent_hash IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM pggit.commits p WHERE p.repo_id = p_repo_id AND p.hash = c.parent_hash);
    
    -- Check broken tree references
    RETURN QUERY
    SELECT 'broken_trees'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'error' END,
           count(*) || ' pggit.commits with invalid tree references'
    FROM pggit.commits c
    WHERE c.repo_id = p_repo_id
      AND NOT EXISTS (SELECT 1 FROM pggit.trees t WHERE t.repo_id = p_repo_id AND t.hash = c.tree_hash);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.optimize_indexes(
    p_repo_id INTEGER
) RETURNS TABLE (
    table_name TEXT,
    index_name TEXT,
    operation TEXT,
    success BOOLEAN
) SET search_path = pggit, public AS $$
DECLARE
    v_table TEXT;
    v_index TEXT;
BEGIN
    -- Reindex each index in the pggit schema, capturing per-index success.
    -- Results are emitted with RETURN NEXT (no temp table) so the function makes
    -- no catalog writes of its own and can run in a read-only transaction.
    FOR v_table, v_index IN
        SELECT t.tablename::TEXT,
               i.indexname::TEXT
        FROM pg_tables t
        JOIN pg_indexes i ON i.schemaname = t.schemaname AND i.tablename = t.tablename
        WHERE t.schemaname = 'pggit'
        ORDER BY t.tablename, i.indexname
    LOOP
        table_name := v_table;
        index_name := v_index;
        operation := 'REINDEX';
        BEGIN
            EXECUTE format('REINDEX INDEX pggit.%I', v_index);
            success := TRUE;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Reindex failed for %: %', v_index, SQLERRM;
            success := FALSE;
        END;
        RETURN NEXT;
    END LOOP;
END;$$ LANGUAGE plpgsql;
