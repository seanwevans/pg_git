CREATE OR REPLACE FUNCTION init_repository(
    p_name TEXT,
    p_path TEXT
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_repo_id INTEGER;
    v_initial_tree TEXT;
    v_initial_commit TEXT;
BEGIN
    -- Create repository record
    INSERT INTO pggit.repositories (name, path)
    VALUES (p_name, p_path)
    RETURNING id INTO v_repo_id;
    
    -- Create empty initial tree
    v_initial_tree := create_tree(v_repo_id, '[]'::jsonb);
    
    -- Create initial commit
    v_initial_commit := create_commit(
        v_repo_id,
        v_initial_tree,
        NULL,
        'system',
        'Initial commit'
    );
    
    -- Create master branch pointing at the initial commit
    PERFORM update_ref(v_repo_id, 'master', v_initial_commit);

    -- HEAD symbolically tracks master (the current branch)
    PERFORM set_head_symbolic(v_repo_id, 'master');
    
    RETURN v_repo_id;
END;
$$ LANGUAGE plpgsql;
