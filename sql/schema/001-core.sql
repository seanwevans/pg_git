-- Core tables
CREATE TABLE pggit.repositories (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pggit.blobs (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    hash TEXT,
    content BYTEA NOT NULL,
    PRIMARY KEY (repo_id, hash)
);

CREATE TABLE pggit.trees (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    hash TEXT,
    entries JSONB NOT NULL,  -- [{mode, type, hash, name}]
    PRIMARY KEY (repo_id, hash)
);

CREATE TABLE pggit.commits (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    hash TEXT,
    tree_hash TEXT NOT NULL,
    parent_hash TEXT,
    author TEXT NOT NULL,
    message TEXT NOT NULL,
    -- clock_timestamp() (not CURRENT_TIMESTAMP) so commits created within a single
    -- transaction receive distinct, monotonically increasing timestamps and can be
    -- ordered relative to one another.
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT clock_timestamp(),
    PRIMARY KEY (repo_id, hash),
    FOREIGN KEY (repo_id, tree_hash) REFERENCES pggit.trees(repo_id, hash),
    FOREIGN KEY (repo_id, parent_hash) REFERENCES pggit.commits(repo_id, hash)
);

-- A ref is either "direct" (commit_hash set) or "symbolic" (symbolic_target set,
-- naming another ref). HEAD is normally symbolic, pointing at the current branch
-- (e.g. 'master'); a detached HEAD is direct. Exactly one of the two columns is
-- populated. This mirrors Git, where committing advances the branch HEAD points
-- at rather than every branch that happens to share the old commit.
CREATE TABLE pggit.refs (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    name TEXT,
    commit_hash TEXT,
    symbolic_target TEXT,
    PRIMARY KEY (repo_id, name),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash),
    CONSTRAINT refs_direct_xor_symbolic
        CHECK ((commit_hash IS NOT NULL)::int + (symbolic_target IS NOT NULL)::int = 1)
);

-- Function to create a blob
CREATE OR REPLACE FUNCTION create_blob(
    p_repo_id INTEGER,
    p_content BYTEA
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_hash TEXT;
BEGIN
    v_hash := encode(sha256(p_content), 'hex');
    INSERT INTO pggit.blobs (repo_id, hash, content)
    VALUES (p_repo_id, v_hash, p_content)
    ON CONFLICT DO NOTHING;
    RETURN v_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to create a tree
CREATE OR REPLACE FUNCTION create_tree(
    p_repo_id INTEGER,
    p_entries JSONB
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_hash TEXT;
BEGIN
    v_hash := encode(sha256(p_entries::text::bytea), 'hex');
    INSERT INTO pggit.trees (repo_id, hash, entries)
    VALUES (p_repo_id, v_hash, p_entries)
    ON CONFLICT DO NOTHING;
    RETURN v_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to create a commit
CREATE OR REPLACE FUNCTION create_commit(
    p_repo_id INTEGER,
    p_tree_hash TEXT,
    p_parent_hash TEXT,
    p_author TEXT,
    p_message TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_hash TEXT;
    v_commit_data TEXT;
BEGIN
    v_commit_data := concat_ws(
        '',
        COALESCE(p_tree_hash, ''),
        COALESCE(p_parent_hash, ''),
        COALESCE(p_author, ''),
        COALESCE(p_message, '')
    );
    v_hash := encode(sha256(v_commit_data::bytea), 'hex');

    IF v_hash IS NULL THEN
        RAISE EXCEPTION 'Commit hash calculation returned NULL';
    END IF;

    INSERT INTO pggit.commits (repo_id, hash, tree_hash, parent_hash, author, message)
    VALUES (p_repo_id, v_hash, p_tree_hash, p_parent_hash, p_author, p_message);
    
    RETURN v_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to create/update a direct ref (a branch or detached HEAD). Always
-- clears symbolic_target so a previously symbolic ref becomes direct.
CREATE OR REPLACE FUNCTION update_ref(
    p_repo_id INTEGER,
    p_name TEXT,
    p_commit_hash TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.refs (repo_id, name, commit_hash, symbolic_target)
    VALUES (p_repo_id, p_name, p_commit_hash, NULL)
    ON CONFLICT (repo_id, name) DO UPDATE
    SET commit_hash = EXCLUDED.commit_hash, symbolic_target = NULL;
END;
$$ LANGUAGE plpgsql;

-- Resolve a ref name to a commit hash, following symbolic refs (e.g.
-- HEAD -> 'master' -> <commit>). Returns NULL if the ref does not exist.
CREATE OR REPLACE FUNCTION resolve_ref(
    p_repo_id INTEGER,
    p_name TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_name TEXT := p_name;
    v_commit TEXT;
    v_target TEXT;
    v_depth INTEGER := 0;
BEGIN
    LOOP
        SELECT commit_hash, symbolic_target INTO v_commit, v_target
        FROM pggit.refs
        WHERE repo_id = p_repo_id AND name = v_name;

        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
        IF v_target IS NULL THEN
            RETURN v_commit;
        END IF;

        v_name := v_target;
        v_depth := v_depth + 1;
        IF v_depth > 20 THEN
            RAISE EXCEPTION 'symbolic ref chain too deep (cycle?) starting at %', p_name;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE;

-- The branch HEAD currently points at, or NULL when HEAD is detached.
CREATE OR REPLACE FUNCTION current_branch(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
    SELECT symbolic_target
    FROM pggit.refs
    WHERE repo_id = p_repo_id AND name = 'HEAD';
$$ LANGUAGE sql STABLE;

-- Point HEAD symbolically at a branch (the normal, attached state).
CREATE OR REPLACE FUNCTION set_head_symbolic(
    p_repo_id INTEGER,
    p_branch TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.refs (repo_id, name, commit_hash, symbolic_target)
    VALUES (p_repo_id, 'HEAD', NULL, p_branch)
    ON CONFLICT (repo_id, name) DO UPDATE
    SET commit_hash = NULL, symbolic_target = EXCLUDED.symbolic_target;
END;
$$ LANGUAGE plpgsql;

-- Point HEAD directly at a commit (detached HEAD).
CREATE OR REPLACE FUNCTION set_head_detached(
    p_repo_id INTEGER,
    p_commit_hash TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.refs (repo_id, name, commit_hash, symbolic_target)
    VALUES (p_repo_id, 'HEAD', p_commit_hash, NULL)
    ON CONFLICT (repo_id, name) DO UPDATE
    SET commit_hash = EXCLUDED.commit_hash, symbolic_target = NULL;
END;
$$ LANGUAGE plpgsql;

-- Advance "where HEAD is" to a new commit: move the branch HEAD points at, or
-- HEAD itself when detached. This is what commit/reset/merge use so that only
-- the current branch moves, not every branch sharing the old commit.
CREATE OR REPLACE FUNCTION advance_head(
    p_repo_id INTEGER,
    p_commit_hash TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_branch TEXT;
BEGIN
    v_branch := pggit.current_branch(p_repo_id);
    IF v_branch IS NULL THEN
        -- Detached HEAD: move HEAD itself.
        UPDATE pggit.refs
        SET commit_hash = p_commit_hash, symbolic_target = NULL
        WHERE repo_id = p_repo_id AND name = 'HEAD';
    ELSE
        -- Attached: move the branch HEAD points at (creating it if needed).
        INSERT INTO pggit.refs (repo_id, name, commit_hash, symbolic_target)
        VALUES (p_repo_id, v_branch, p_commit_hash, NULL)
        ON CONFLICT (repo_id, name) DO UPDATE
        SET commit_hash = EXCLUDED.commit_hash, symbolic_target = NULL;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Function to get commit history
CREATE OR REPLACE FUNCTION get_commit_history(
    p_repo_id INTEGER,
    p_start_commit TEXT
) RETURNS TABLE (
    hash TEXT,
    tree_hash TEXT,
    parent_hash TEXT,
    author TEXT,
    message TEXT,
    "timestamp" TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
WITH RECURSIVE commit_history AS (
    SELECT * FROM pggit.commits WHERE repo_id = p_repo_id AND hash = p_start_commit
    UNION ALL
    SELECT c.*
    FROM pggit.commits c
    INNER JOIN commit_history ch ON c.repo_id = p_repo_id AND c.hash = ch.parent_hash
)
SELECT hash, tree_hash, parent_hash, author, message, "timestamp" FROM commit_history;
$$ LANGUAGE sql;

-- Function to diff two pggit.trees
CREATE OR REPLACE FUNCTION diff_trees(
    p_repo_id INTEGER,
    p_old_tree_hash TEXT,
    p_new_tree_hash TEXT
) RETURNS TABLE (
    change_type TEXT,
    path TEXT,
    old_hash TEXT,
    new_hash TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_old_entries JSONB;
    v_new_entries JSONB;
BEGIN
    -- Get tree entries
    SELECT entries INTO v_old_entries FROM pggit.trees WHERE repo_id = p_repo_id AND hash = p_old_tree_hash;
    SELECT entries INTO v_new_entries FROM pggit.trees WHERE repo_id = p_repo_id AND hash = p_new_tree_hash;
    
    -- Added files
    RETURN QUERY
    SELECT 'added' as change_type,
           e->>'name' as path,
           NULL as old_hash,
           e->>'hash' as new_hash
    FROM jsonb_array_elements(v_new_entries) e
    WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_old_entries) oe
        WHERE (oe->>'name') = (e->>'name')
    );
    
    -- Deleted files
    RETURN QUERY
    SELECT 'deleted' as change_type,
           e->>'name' as path,
           e->>'hash' as old_hash,
           NULL as new_hash
    FROM jsonb_array_elements(v_old_entries) e
    WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_new_entries) ne
        WHERE (ne->>'name') = (e->>'name')
    );
    
    -- Modified files
    RETURN QUERY
    SELECT 'modified' as change_type,
           ne->>'name' as path,
           oe->>'hash' as old_hash,
           ne->>'hash' as new_hash
    FROM jsonb_array_elements(v_old_entries) oe
    JOIN jsonb_array_elements(v_new_entries) ne
    ON (oe->>'name') = (ne->>'name')
    WHERE (oe->>'hash') != (ne->>'hash');
END;
$$ LANGUAGE plpgsql;
