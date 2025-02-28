-- Path: /sql/functions/021-sparse-checkout.sql
-- Sparse checkout functionality

CREATE TABLE pg_git.sparse_patterns (
    repo_id INTEGER REFERENCES repositories(id),
    pattern TEXT NOT NULL,
    is_negative BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, pattern)
);

CREATE OR REPLACE FUNCTION pg_git.sparse_checkout_set(
    p_repo_id INTEGER,
    p_patterns TEXT[]
) RETURNS VOID AS $$
BEGIN
    -- Clear existing patterns
    DELETE FROM pg_git.sparse_patterns
    WHERE repo_id = p_repo_id;
    
    -- Add new patterns
    INSERT INTO pg_git.sparse_patterns (repo_id, pattern, is_negative)
    SELECT p_repo_id,
           pattern,
           pattern LIKE '!%'
    FROM unnest(p_patterns) pattern;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.sparse_checkout_add(
    p_repo_id INTEGER,
    p_patterns TEXT[]
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pg_git.sparse_patterns (repo_id, pattern, is_negative)
    SELECT p_repo_id,
           pattern,
           pattern LIKE '!%'
    FROM unnest(p_patterns) pattern
    ON CONFLICT (repo_id, pattern) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.is_path_in_sparse_checkout(
    p_repo_id INTEGER,
    p_path TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    WITH matched_patterns AS (
        SELECT pattern, is_negative,
               p_path LIKE replace(
                   replace(pattern, '!', ''),
                   '*', '%'
               ) as matches
        FROM pg_git.sparse_patterns
        WHERE repo_id = p_repo_id
        ORDER BY is_negative, length(pattern) DESC
    )
    SELECT COALESCE(
        bool_or(
            CASE 
                WHEN is_negative THEN NOT matches
                ELSE matches
            END
        ),
        TRUE  -- If no patterns, include everything
    )
    INTO v_result
    FROM matched_patterns
    WHERE matches;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- Override tree functions to respect sparse checkout
CREATE OR REPLACE FUNCTION pg_git.get_tree_files(
    p_repo_id INTEGER,
    p_tree_hash TEXT
) RETURNS TABLE (
    path TEXT,
    blob_hash TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE tree_files AS (
        SELECT e->>'name' as path,
               e->>'hash' as hash,
               e->>'type' as type
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = p_tree_hash
        
        UNION ALL
        
        SELECT tf.path || '/' || e->>'name',
               e->>'hash',
               e->>'type'
        FROM tree_files tf
        JOIN trees t ON tf.hash = t.hash,
        jsonb_array_elements(t.entries) e
        WHERE tf.type = 'tree'
    )
    SELECT tf.path, tf.hash
    FROM tree_files tf
    WHERE tf.type = 'blob'
    AND pg_git.is_path_in_sparse_checkout(p_repo_id, tf.path);
END;
$$ LANGUAGE plpgsql;