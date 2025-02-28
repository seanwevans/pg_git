-- Core tables
CREATE TABLE blobs (
    hash TEXT PRIMARY KEY,
    content BYTEA NOT NULL
);

CREATE TABLE trees (
    hash TEXT PRIMARY KEY,
    entries JSONB NOT NULL  -- [{mode, type, hash, name}]
);

CREATE TABLE commits (
    hash TEXT PRIMARY KEY,
    tree_hash TEXT NOT NULL REFERENCES trees(hash),
    parent_hash TEXT REFERENCES commits(hash),
    author TEXT NOT NULL,
    message TEXT NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE refs (
    name TEXT PRIMARY KEY,
    commit_hash TEXT NOT NULL REFERENCES commits(hash)
);

-- Function to create a blob
CREATE OR REPLACE FUNCTION create_blob(
    p_content BYTEA
) RETURNS TEXT AS $$
DECLARE
    v_hash TEXT;
BEGIN
    v_hash := encode(sha256(p_content), 'hex');
    INSERT INTO blobs (hash, content)
    VALUES (v_hash, p_content)
    ON CONFLICT DO NOTHING;
    RETURN v_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to create a tree
CREATE OR REPLACE FUNCTION create_tree(
    p_entries JSONB
) RETURNS TEXT AS $$
DECLARE
    v_hash TEXT;
BEGIN
    v_hash := encode(sha256(p_entries::text::bytea), 'hex');
    INSERT INTO trees (hash, entries)
    VALUES (v_hash, p_entries)
    ON CONFLICT DO NOTHING;
    RETURN v_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to create a commit
CREATE OR REPLACE FUNCTION create_commit(
    p_tree_hash TEXT,
    p_parent_hash TEXT,
    p_author TEXT,
    p_message TEXT
) RETURNS TEXT AS $$
DECLARE
    v_hash TEXT;
    v_commit_data TEXT;
BEGIN
    v_commit_data := p_tree_hash || p_parent_hash || p_author || p_message;
    v_hash := encode(sha256(v_commit_data::bytea), 'hex');
    
    INSERT INTO commits (hash, tree_hash, parent_hash, author, message)
    VALUES (v_hash, p_tree_hash, p_parent_hash, p_author, p_message);
    
    RETURN v_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to create/update a branch
CREATE OR REPLACE FUNCTION update_ref(
    p_name TEXT,
    p_commit_hash TEXT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO refs (name, commit_hash)
    VALUES (p_name, p_commit_hash)
    ON CONFLICT (name) DO UPDATE
    SET commit_hash = p_commit_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to get commit history
CREATE OR REPLACE FUNCTION get_commit_history(
    p_start_commit TEXT
) RETURNS TABLE (
    hash TEXT,
    tree_hash TEXT,
    parent_hash TEXT,
    author TEXT,
    message TEXT,
    timestamp TIMESTAMP WITH TIME ZONE
) AS $$
WITH RECURSIVE commit_history AS (
    SELECT * FROM commits WHERE hash = p_start_commit
    UNION ALL
    SELECT c.*
    FROM commits c
    INNER JOIN commit_history ch ON c.hash = ch.parent_hash
)
SELECT * FROM commit_history;
$$ LANGUAGE sql;

-- Function to diff two trees
CREATE OR REPLACE FUNCTION diff_trees(
    p_old_tree_hash TEXT,
    p_new_tree_hash TEXT
) RETURNS TABLE (
    change_type TEXT,
    path TEXT,
    old_hash TEXT,
    new_hash TEXT
) AS $$
DECLARE
    v_old_entries JSONB;
    v_new_entries JSONB;
BEGIN
    -- Get tree entries
    SELECT entries INTO v_old_entries FROM trees WHERE hash = p_old_tree_hash;
    SELECT entries INTO v_new_entries FROM trees WHERE hash = p_new_tree_hash;
    
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
