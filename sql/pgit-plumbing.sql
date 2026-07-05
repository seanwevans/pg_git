-- Path: /sql/functions/017-plumbing.sql
-- Git plumbing commands implementation

CREATE OR REPLACE FUNCTION pggit.cat_file(
    p_repo_id INTEGER,
    p_hash TEXT,
    p_type TEXT DEFAULT NULL
) RETURNS TABLE (
    object_type TEXT,
    size BIGINT,
    content TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Try blobs. Columns are table-qualified because the RETURNS TABLE OUT
    -- parameter "content" would otherwise shadow blobs.content.
    RETURN QUERY
    SELECT 'blob'::TEXT,
           octet_length(blobs.content)::BIGINT,
           encode(blobs.content, 'escape')
    FROM blobs WHERE repo_id = p_repo_id AND hash = p_hash
    AND (p_type IS NULL OR p_type = 'blob');
    
    IF FOUND THEN RETURN; END IF;
    
    -- Try trees
    RETURN QUERY
    SELECT 'tree'::TEXT,
           octet_length(entries::TEXT)::BIGINT,
           entries::TEXT
    FROM trees WHERE repo_id = p_repo_id AND hash = p_hash
    AND (p_type IS NULL OR p_type = 'tree');
    
    IF FOUND THEN RETURN; END IF;
    
    -- Try commits
    RETURN QUERY
    SELECT 'commit'::TEXT,
           octet_length(message)::BIGINT,
           message
    FROM commits WHERE repo_id = p_repo_id AND hash = p_hash
    AND (p_type IS NULL OR p_type = 'commit');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.hash_object(
    p_repo_id INTEGER,
    p_content BYTEA,
    p_type TEXT DEFAULT 'blob'
) RETURNS TEXT SET search_path = pggit, public AS $$
BEGIN
    CASE p_type
        WHEN 'blob' THEN
            RETURN pggit.create_blob(p_repo_id, p_content);
        WHEN 'tree' THEN
            RETURN pggit.create_tree(p_repo_id, p_content::TEXT::jsonb);
        ELSE
            RAISE EXCEPTION 'Unsupported object type: %', p_type;
    END CASE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.ls_tree(
    p_repo_id INTEGER,
    p_tree_hash TEXT,
    p_recursive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    mode TEXT,
    type TEXT,
    hash TEXT,
    path TEXT
) SET search_path = pggit, public AS $$
BEGIN
    IF NOT p_recursive THEN
        RETURN QUERY
        SELECT (e->>'mode')::TEXT,
               (e->>'type')::TEXT,
               (e->>'hash')::TEXT,
               (e->>'name')::TEXT
        FROM trees t,
             jsonb_array_elements(t.entries) e
        WHERE t.repo_id = p_repo_id AND t.hash = p_tree_hash;
    ELSE
        RETURN QUERY
        WITH RECURSIVE tree_entries AS (
            -- Base case: direct entries
            SELECT (e->>'mode')::TEXT as mode,
                   (e->>'type')::TEXT as type,
                   (e->>'hash')::TEXT as hash,
                   (e->>'name')::TEXT as path,
                   1 as level
            FROM trees t,
                 jsonb_array_elements(t.entries) e
            WHERE t.repo_id = p_repo_id AND t.hash = p_tree_hash
            
            
            UNION ALL
            
            -- Recursive case: subtrees
            SELECT (se->>'mode')::TEXT,
                   (se->>'type')::TEXT,
                   (se->>'hash')::TEXT,
                   te.path || '/' || (se->>'name')::TEXT,
                   te.level + 1
            FROM tree_entries te
            JOIN trees t ON t.repo_id = p_repo_id AND te.hash = t.hash,
            jsonb_array_elements(t.entries) se
            WHERE te.type = 'tree'
        )
        -- Qualify with the CTE name: mode/type/hash/path are also RETURNS TABLE
        -- OUT parameters and would otherwise be ambiguous.
        SELECT tree_entries.mode, tree_entries.type, tree_entries.hash, tree_entries.path
        FROM tree_entries
        ORDER BY tree_entries.path;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.merge_base(
    p_repo_id INTEGER,
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    -- Reuse existing merge base finding function. find_merge_base identifies the
    -- repository from the commit hashes themselves, so it takes only two args.
    SELECT pggit.find_merge_base(p_commit1, p_commit2);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.rev_list(
    p_repo_id INTEGER,
    p_start_commit TEXT,
    p_exclude_commits TEXT[] DEFAULT ARRAY[]::TEXT[]
) RETURNS TABLE (
    hash TEXT,
    commit_data JSONB
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE commit_list AS (
        -- Start commit. commits.hash is qualified because "hash" is also a
        -- RETURNS TABLE OUT parameter and would otherwise be ambiguous.
        SELECT commits.hash,
               jsonb_build_object(
                   'tree', tree_hash,
                   'parent', parent_hash,
                   'author', author,
                   'message', message,
                   'timestamp', timestamp
               ) as commit_data
        FROM commits
        WHERE repo_id = p_repo_id AND commits.hash = p_start_commit
        
        UNION
        
        -- Parent commits
        SELECT c.hash,
               jsonb_build_object(
                   'tree', c.tree_hash,
                   'parent', c.parent_hash,
                   'author', c.author,
                   'message', c.message,
                   'timestamp', c.timestamp
               ) as commit_data
        FROM commit_list cl
        JOIN commits c ON c.repo_id = p_repo_id AND cl.commit_data->>'parent' = c.hash
        WHERE c.hash <> ALL(p_exclude_commits)
    )
    SELECT * FROM commit_list;
END;
$$ LANGUAGE plpgsql;
