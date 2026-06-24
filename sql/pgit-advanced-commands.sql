-- Path: /sql/functions/016-advanced-commands.sql
-- Additional Git commands implementation

-- Notes support
CREATE TABLE pggit.notes (
    repo_id INTEGER REFERENCES repositories(id),
    object_hash TEXT NOT NULL,
    note TEXT NOT NULL,
    author TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, object_hash)
);

-- Stash support
CREATE TABLE pggit.stash (
    repo_id INTEGER REFERENCES repositories(id),
    stash_id SERIAL,
    tree_hash TEXT NOT NULL,
    parent_hash TEXT,
    message TEXT NOT NULL,
    author TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, stash_id),
    FOREIGN KEY (repo_id, tree_hash) REFERENCES pggit.trees(repo_id, hash),
    FOREIGN KEY (repo_id, parent_hash) REFERENCES pggit.commits(repo_id, hash)
);

-- Worktree support
CREATE TABLE pggit.worktrees (
    repo_id INTEGER REFERENCES repositories(id),
    path TEXT NOT NULL,
    branch TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    locked BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash)
);

-- Command implementations

CREATE OR REPLACE FUNCTION pggit.add_note(
    p_repo_id INTEGER,
    p_object_hash TEXT,
    p_note TEXT,
    p_author TEXT DEFAULT current_user
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.notes (repo_id, object_hash, note, author)
    VALUES (p_repo_id, p_object_hash, p_note, p_author)
    ON CONFLICT (repo_id, object_hash) 
    DO UPDATE SET note = p_note, author = p_author;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.stash_save(
    p_repo_id INTEGER,
    p_message TEXT DEFAULT '',
    p_author TEXT DEFAULT current_user
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_tree_hash TEXT;
    v_stash_id INTEGER;
BEGIN
    -- Create tree from current index
    v_tree_hash := pggit.create_tree_from_index(p_repo_id);
    
    INSERT INTO pggit.stash (repo_id, tree_hash, parent_hash, message, author)
    VALUES (p_repo_id, v_tree_hash, 
            (SELECT commit_hash FROM refs WHERE name = 'HEAD'),
            p_message, p_author)
    RETURNING stash_id INTO v_stash_id;
    
    -- Clear index
    DELETE FROM index_entries WHERE repo_id = p_repo_id;
    
    RETURN v_stash_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.stash_pop(
    p_repo_id INTEGER,
    p_stash_id INTEGER DEFAULT NULL
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_stash RECORD;
BEGIN
    -- Get most recent stash if no id provided
    IF p_stash_id IS NULL THEN
        SELECT * INTO v_stash
        FROM pggit.stash
        WHERE repo_id = p_repo_id
        ORDER BY stash_id DESC
        LIMIT 1;
    ELSE
        SELECT * INTO v_stash
        FROM pggit.stash
        WHERE repo_id = p_repo_id AND stash_id = p_stash_id;
    END IF;
    
    -- Apply stash to index
    INSERT INTO index_entries (repo_id, path, blob_hash)
    SELECT p_repo_id, e->>'name', e->>'hash'
    FROM trees, jsonb_array_elements(entries) e
    WHERE hash = v_stash.tree_hash;
    
    -- Remove stash
    DELETE FROM pggit.stash
    WHERE repo_id = p_repo_id AND stash_id = v_stash.stash_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.add_worktree(
    p_repo_id INTEGER,
    p_path TEXT,
    p_branch TEXT,
    p_create_branch BOOLEAN DEFAULT FALSE
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get or create branch
    IF p_create_branch THEN
        PERFORM pggit.create_branch(p_repo_id, p_branch);
    END IF;
    
    SELECT commit_hash INTO v_commit_hash
    FROM refs WHERE name = p_branch;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Branch % not found', p_branch;
    END IF;
    
    INSERT INTO pggit.worktrees (repo_id, path, branch, commit_hash)
    VALUES (p_repo_id, p_path, p_branch, v_commit_hash);
END;
$$ LANGUAGE plpgsql;

-- Blame implementation
CREATE OR REPLACE FUNCTION pggit.blame(
    p_repo_id INTEGER,
    p_path TEXT,
    p_commit TEXT DEFAULT 'HEAD'
) RETURNS TABLE (
    line_number INTEGER,
    commit_hash TEXT,
    author TEXT,
    "timestamp" TIMESTAMP WITH TIME ZONE,
    line_content TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
    v_blob_hash TEXT;
BEGIN
    -- Resolve commit (qualify commit_hash to avoid clash with the OUT column)
    IF p_commit = 'HEAD' THEN
        SELECT r.commit_hash INTO v_commit_hash
        FROM refs r WHERE r.repo_id = p_repo_id AND r.name = 'HEAD';
    ELSE
        v_commit_hash := p_commit;
    END IF;
    
    -- Get blob hash for file
    SELECT e->>'hash' INTO v_blob_hash
    FROM commits c
    JOIN trees t ON c.tree_hash = t.hash,
    jsonb_array_elements(t.entries) e
    WHERE c.hash = v_commit_hash
    AND e->>'name' = p_path;
    
    -- Return blame data
    RETURN QUERY
    WITH RECURSIVE file_history AS (
        SELECT c.hash, c.author, c.timestamp,
               b.content,
               generate_subscripts(regexp_split_to_array(encode(b.content, 'escape'), E'\n'), 1) as line_number,
               regexp_split_to_array(encode(b.content, 'escape'), E'\n') as lines
        FROM commits c
        JOIN trees t ON c.tree_hash = t.hash,
        jsonb_array_elements(t.entries) e
        JOIN blobs b ON e->>'hash' = b.hash
        WHERE c.hash = v_commit_hash
        AND e->>'name' = p_path
    )
    SELECT h.line_number,
           h.hash,
           h.author,
           h.timestamp,
           h.lines[h.line_number]
    FROM file_history h
    ORDER BY h.line_number;
END;
$$ LANGUAGE plpgsql;
