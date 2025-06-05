-- Path: /sql/functions/017-plumbing.sql
-- Git plumbing commands implementation

CREATE OR REPLACE FUNCTION pg_git.cat_file(
    p_repo_id INTEGER,
    p_hash TEXT,
    p_type TEXT DEFAULT NULL
) RETURNS TABLE (
    object_type TEXT,
    size BIGINT,
    content TEXT
) AS $$
BEGIN
    -- Try blobs
    RETURN QUERY
    SELECT 'blob'::TEXT,
           octet_length(content)::BIGINT,
           encode(content, 'escape')
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

CREATE OR REPLACE FUNCTION pg_git.hash_object(
    p_repo_id INTEGER,
    p_content BYTEA,
    p_type TEXT DEFAULT 'blob'
) RETURNS TEXT AS $$
BEGIN
    CASE p_type
        WHEN 'blob' THEN
            RETURN pg_git.create_blob(p_repo_id, p_content);
        WHEN 'tree' THEN
            RETURN pg_git.create_tree(p_repo_id, p_content::TEXT::jsonb);
        ELSE
            RAISE EXCEPTION 'Unsupported object type: %', p_type;
    END CASE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.ls_tree(
    p_repo_id INTEGER,
    p_tree_hash TEXT,
    p_recursive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    mode TEXT,
    type TEXT,
    hash TEXT,
    path TEXT
) AS $$
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
        SELECT mode, type, hash, path
        FROM tree_entries
        ORDER BY path;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.merge_base(
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT AS $$
    -- Reuse existing merge base finding function
    SELECT pg_git.find_merge_base(p_commit1, p_commit2);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_git.rev_list(
    p_repo_id INTEGER,
    p_start_commit TEXT,
    p_exclude_commits TEXT[] DEFAULT ARRAY[]::TEXT[]
) RETURNS TABLE (
    hash TEXT,
    commit_data JSONB
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE commit_list AS (
        -- Start commit
        SELECT hash,
               jsonb_build_object(
                   'tree', tree_hash,
                   'parent', parent_hash,
                   'author', author,
                   'message', message,
                   'timestamp', timestamp
               ) as commit_data
        FROM commits
        WHERE repo_id = p_repo_id AND hash = p_start_commit
        
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