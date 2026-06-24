-- Path: /sql/functions/003-commit.sql
-- pg_git commit functions

CREATE OR REPLACE FUNCTION pggit.create_tree_from_index(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
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
    FROM (
        SELECT mode, blob_hash, path
        FROM index_entries
        WHERE repo_id = p_repo_id
        ORDER BY path
    ) ordered_entries;

    RETURN pggit.create_tree(p_repo_id, COALESCE(v_entries, '[]'::jsonb));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.commit_index(
    p_repo_id INTEGER,
    p_author TEXT,
    p_message TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_tree_hash TEXT;
    v_parent_hash TEXT;
    v_commit_hash TEXT;
BEGIN
    -- Get current HEAD
    SELECT commit_hash INTO v_parent_hash
    FROM pggit.refs
    WHERE repo_id = p_repo_id AND name = 'HEAD';

    -- Create tree from index
    v_tree_hash := pggit.create_tree_from_index(p_repo_id);

    -- Create commit
    v_commit_hash := pggit.create_commit(
        p_repo_id,
        v_tree_hash,
        v_parent_hash,
        p_author,
        p_message
    );

    -- Update HEAD and branch reference
    UPDATE pggit.refs SET commit_hash = v_commit_hash WHERE repo_id = p_repo_id AND name = 'HEAD';
    UPDATE pggit.refs
    SET commit_hash = v_commit_hash
    WHERE repo_id = p_repo_id
      AND commit_hash = v_parent_hash
      AND name <> 'HEAD';

    -- Clear index
    DELETE FROM index_entries WHERE repo_id = p_repo_id;

    RETURN v_commit_hash;
END;$$ LANGUAGE plpgsql;
