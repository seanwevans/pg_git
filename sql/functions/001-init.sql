CREATE TABLE repositories (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION init_repository(
    p_name TEXT,
    p_path TEXT
) RETURNS INTEGER AS $$
DECLARE
    v_repo_id INTEGER;
    v_initial_tree TEXT;
    v_initial_commit TEXT;
BEGIN
    -- Create repository record
    INSERT INTO repositories (name, path)
    VALUES (p_name, p_path)
    RETURNING id INTO v_repo_id;
    
    -- Create empty initial tree
    v_initial_tree := create_tree('[]'::jsonb);
    
    -- Create initial commit
    v_initial_commit := create_commit(
        v_initial_tree,
        NULL,
        'system',
        'Initial commit'
    );
    
    -- Create master branch
    PERFORM update_ref('master', v_initial_commit);
    
    RETURN v_repo_id;
END;
$$ LANGUAGE plpgsql;
