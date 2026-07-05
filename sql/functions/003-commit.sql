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
    -- Resolve the current HEAD commit (through the symbolic ref) to use as parent.
    v_parent_hash := pggit.resolve_ref(p_repo_id, 'HEAD');

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

    -- Advance only the current branch (or the detached HEAD). Other branches
    -- that happened to share the old commit are left untouched.
    PERFORM pggit.advance_head(p_repo_id, v_commit_hash);

    -- Clear index
    DELETE FROM index_entries WHERE repo_id = p_repo_id;

    RETURN v_commit_hash;
END;$$ LANGUAGE plpgsql;
