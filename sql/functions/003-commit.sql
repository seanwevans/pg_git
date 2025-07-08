-- Path: /sql/functions/003-commit.sql
-- pg_git commit functions

CREATE OR REPLACE FUNCTION pg_git.create_tree_from_index(
    p_repo_id INTEGER
) RETURNS TEXT AS $$
DECLARE
    v_entries JSONB;
BEGIN
    SELECT jsonb_agg(
        jsonb_build_object(
            'mode', mode,
            'type', 'blob',
            'hash', blob_hash,
            'name', path
        )
    ) INTO v_entries
    FROM index_entries
    WHERE repo_id = p_repo_id;

    RETURN pg_git.create_tree(p_repo_id, COALESCE(v_entries, '[]'::jsonb));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.commit_index(
    p_repo_id INTEGER,
    p_author TEXT,
    p_message TEXT
) RETURNS TEXT AS $$
DECLARE
    v_tree_hash TEXT;
    v_parent_hash TEXT;
    v_commit_hash TEXT;
BEGIN
    -- Get current HEAD
    SELECT commit_hash INTO v_parent_hash
    FROM refs
    WHERE repo_id = p_repo_id AND name = 'HEAD';

    -- Create tree from index
    v_tree_hash := pg_git.create_tree_from_index(p_repo_id);

    -- Create commit
    v_commit_hash := pg_git.create_commit(
        p_repo_id,
        v_tree_hash,
        v_parent_hash,
        p_author,
        p_message
    );

    -- Update HEAD and current branch
    UPDATE refs SET commit_hash = v_commit_hash WHERE repo_id = p_repo_id AND name = 'HEAD';

    -- Clear index
    DELETE FROM index_entries WHERE repo_id = p_repo_id;

    RETURN v_commit_hash;
END;$$ LANGUAGE plpgsql;
