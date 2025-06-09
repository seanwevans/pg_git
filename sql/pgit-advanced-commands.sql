-- Path: /sql/functions/016-advanced-commands.sql
-- Additional Git commands implementation

-- Notes support
CREATE TABLE pg_git.notes (
    repo_id INTEGER REFERENCES repositories(id),
    object_hash TEXT NOT NULL,
    note TEXT NOT NULL,
    author TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, object_hash)
);

-- Stash support
CREATE TABLE pg_git.stash (
    repo_id INTEGER REFERENCES repositories(id),
    stash_id SERIAL,
    tree_hash TEXT NOT NULL REFERENCES trees(hash),
    parent_hash TEXT REFERENCES commits(hash),
    message TEXT NOT NULL,
    author TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, stash_id)
);

-- Worktree support
CREATE TABLE pg_git.worktrees (
    repo_id INTEGER REFERENCES repositories(id),
    path TEXT NOT NULL,
    branch TEXT NOT NULL,
    commit_hash TEXT NOT NULL REFERENCES commits(hash),
    locked BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path)
);

-- Command implementations

CREATE OR REPLACE FUNCTION pg_git.add_note(
    p_repo_id INTEGER,
    p_object_hash TEXT,
    p_note TEXT,
    p_author TEXT DEFAULT current_user
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pg_git.notes (repo_id, object_hash, note, author)
    VALUES (p_repo_id, p_object_hash, p_note, p_author)
    ON CONFLICT (repo_id, object_hash) 
    DO UPDATE SET note = p_note, author = p_author;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.stash_save(
    p_repo_id INTEGER,
    p_message TEXT DEFAULT '',
    p_author TEXT DEFAULT current_user
) RETURNS INTEGER AS $$
DECLARE
    v_tree_hash TEXT;
    v_stash_id INTEGER;
BEGIN
    -- Create tree from current index
    v_tree_hash := pg_git.create_tree_from_index(p_repo_id);
    
    INSERT INTO pg_git.stash (repo_id, tree_hash, parent_hash, message, author)
    VALUES (p_repo_id, v_tree_hash, 
            (SELECT commit_hash FROM refs WHERE name = 'HEAD'),
            p_message, p_author)
    RETURNING stash_id INTO v_stash_id;
    
    -- Clear index
    DELETE FROM index_entries WHERE repo_id = p_repo_id;
    
    RETURN v_stash_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.stash_pop(
    p_repo_id INTEGER,
    p_stash_id INTEGER DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_stash RECORD;
BEGIN
    -- Get most recent stash if no id provided
    IF p_stash_id IS NULL THEN
        SELECT * INTO v_stash
        FROM pg_git.stash
        WHERE repo_id = p_repo_id
        ORDER BY stash_id DESC
        LIMIT 1;
    ELSE
        SELECT * INTO v_stash
        FROM pg_git.stash
        WHERE repo_id = p_repo_id AND stash_id = p_stash_id;
    END IF;
    
    -- Apply stash to index
    INSERT INTO index_entries (repo_id, path, blob_hash)
    SELECT p_repo_id, e->>'name', e->>'hash'
    FROM trees, jsonb_array_elements(entries) e
    WHERE hash = v_stash.tree_hash;
    
    -- Remove stash
    DELETE FROM pg_git.stash
    WHERE repo_id = p_repo_id AND stash_id = v_stash.stash_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.add_worktree(
    p_repo_id INTEGER,
    p_path TEXT,
    p_branch TEXT,
    p_create_branch BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get or create branch
    IF p_create_branch THEN
        PERFORM pg_git.create_branch(p_repo_id, p_branch);
    END IF;
    
    SELECT commit_hash INTO v_commit_hash
    FROM refs WHERE name = p_branch;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Branch % not found', p_branch;
    END IF;
    
    INSERT INTO pg_git.worktrees (repo_id, path, branch, commit_hash)
    VALUES (p_repo_id, p_path, p_branch, v_commit_hash);
END;
$$ LANGUAGE plpgsql;

-- Blame implementation
CREATE OR REPLACE FUNCTION pg_git.blame(
    p_repo_id INTEGER,
    p_path TEXT,
    p_commit TEXT DEFAULT 'HEAD'
) RETURNS TABLE (
    line_number INTEGER,
    commit_hash TEXT,
    author TEXT,
    timestamp TIMESTAMP WITH TIME ZONE,
    line_content TEXT
) AS $$
DECLARE
    v_commit_hash TEXT;
    v_blob_hash TEXT;
BEGIN
    -- Resolve commit
    IF p_commit = 'HEAD' THEN
        SELECT commit_hash INTO v_commit_hash
        FROM refs WHERE name = 'HEAD';
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
