-- pg_git 0.4.0
-- GENERATED FILE -- DO NOT EDIT.
-- Assembled from sql/schema/*.sql, sql/functions/*.sql and sql/pgit-*.sql.
-- Regenerate with: make sql/pg_git--0.4.0.sql

-- ===== sql/schema/001-core.sql =====
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

CREATE TABLE pggit.refs (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    name TEXT,
    commit_hash TEXT NOT NULL,
    PRIMARY KEY (repo_id, name),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash)
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

-- Function to create/update a branch
CREATE OR REPLACE FUNCTION update_ref(
    p_repo_id INTEGER,
    p_name TEXT,
    p_commit_hash TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.refs (repo_id, name, commit_hash)
    VALUES (p_repo_id, p_name, p_commit_hash)
    ON CONFLICT (repo_id, name) DO UPDATE
    SET commit_hash = p_commit_hash;
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

-- ===== sql/schema/pgit-schema.sql =====
-- Central schema definitions for PGit

CREATE TABLE index_entries (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    path TEXT NOT NULL,
    blob_hash TEXT NOT NULL,
    mode TEXT NOT NULL DEFAULT '100644',
    staged_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (repo_id, blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    PRIMARY KEY (repo_id, path));

-- ===== sql/functions/001-init.sql =====
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
    
    -- Create master branch
    PERFORM update_ref(v_repo_id, 'master', v_initial_commit);

    -- Set HEAD to initial commit so subsequent commands work
    PERFORM update_ref(v_repo_id, 'HEAD', v_initial_commit);
    
    RETURN v_repo_id;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/functions/002-add.sql =====

-- Schema for staging area (index)

-- Helper function to normalize file paths and prevent traversal
CREATE OR REPLACE FUNCTION normalize_path(p_path TEXT)
RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_parts TEXT[];
    v_stack TEXT[] := ARRAY[]::TEXT[];
    v_part TEXT;
BEGIN
    -- Reject absolute paths
    IF p_path LIKE '/%' THEN
        RAISE EXCEPTION 'Absolute paths are not allowed'
            USING DETAIL = format('path: %s', p_path);
    END IF;

    -- Split and process path components
    v_parts := regexp_split_to_array(p_path, '/+');
    FOREACH v_part IN ARRAY v_parts LOOP
        IF v_part = '' OR v_part = '.' THEN
            CONTINUE;
        ELSIF v_part = '..' THEN
            -- Prevent traversing above repository root
            IF array_length(v_stack, 1) IS NULL THEN
                RAISE EXCEPTION 'Path traversal is not allowed'
                    USING DETAIL = format('path: %s', p_path);
            END IF;
            v_stack := v_stack[1:array_length(v_stack,1)-1];
        ELSE
            v_stack := v_stack || v_part;
        END IF;
    END LOOP;

    RETURN array_to_string(v_stack, '/');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to stage a file
CREATE OR REPLACE FUNCTION stage_file(
    p_repo_id INTEGER,
    p_path TEXT,
    p_content BYTEA,
    p_mode TEXT DEFAULT '100644'
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_blob_hash TEXT;
    v_norm_path TEXT;
BEGIN
    -- Normalize and validate path
    v_norm_path := normalize_path(p_path);

    -- Create blob from file content
    v_blob_hash := create_blob(p_repo_id, p_content);

    -- Update index
    INSERT INTO index_entries (repo_id, path, blob_hash, mode)
    VALUES (p_repo_id, v_norm_path, v_blob_hash, p_mode)
    ON CONFLICT (repo_id, path)
    DO UPDATE SET blob_hash = v_blob_hash, path = EXCLUDED.path, staged_at = CURRENT_TIMESTAMP;

    RETURN v_blob_hash;
END;
$$ LANGUAGE plpgsql;

-- Function to unstage a file
CREATE OR REPLACE FUNCTION unstage_file(
    p_repo_id INTEGER,
    p_path TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_norm_path TEXT;
BEGIN
    v_norm_path := normalize_path(p_path);

    DELETE FROM index_entries
    WHERE repo_id = p_repo_id AND path = v_norm_path;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/003-commit.sql =====
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

-- ===== sql/functions/004-log.sql =====
-- Path: /sql/functions/004-log.sql
-- pg_git log functions

CREATE OR REPLACE FUNCTION pggit.get_log(
    p_repo_id INTEGER,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    hash TEXT,
    tree_hash TEXT,
    parent_hash TEXT,
    author TEXT,
    message TEXT,
    "timestamp" TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
DECLARE
    v_head_commit TEXT;
BEGIN
    -- Get HEAD commit
    SELECT commit_hash INTO v_head_commit
    FROM pggit.refs
    WHERE repo_id = p_repo_id AND name = 'HEAD';

    RETURN QUERY
    WITH RECURSIVE commit_log AS (
        SELECT c.*
        FROM pggit.commits c
        WHERE c.repo_id = p_repo_id AND c.hash = v_head_commit

        UNION ALL

        SELECT c.*
        FROM pggit.commits c
        INNER JOIN commit_log cl ON c.repo_id = p_repo_id AND c.hash = cl.parent_hash
    )
    SELECT commit_log.hash, commit_log.tree_hash, commit_log.parent_hash,
           commit_log.author, commit_log.message, commit_log."timestamp"
    FROM commit_log
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Pretty format version with commit decoration
CREATE OR REPLACE FUNCTION pggit.get_decorated_log(
    p_repo_id INTEGER,
    p_limit INTEGER DEFAULT NULL
) RETURNS TABLE (
    commit_line TEXT,
    refs TEXT[]
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH commit_refs AS (
        SELECT c.hash,
               c.message,
               c.author,
               c.timestamp,
               array_agg(r.name) FILTER (WHERE r.name <> 'HEAD') as ref_names
        FROM pggit.get_log(p_repo_id, p_limit) c
        LEFT JOIN pggit.refs r ON r.repo_id = p_repo_id AND c.hash = r.commit_hash
        GROUP BY c.hash, c.message, c.author, c.timestamp
    )
    SELECT 
        format('commit %s%sAuthor: %s%sDate: %s%s%s%s',
            substr(hash, 1, 8),
            E'\n',
            author,
            E'\n',
            "timestamp",
            E'\n',
            E'\n    ',
            message
        ) as commit_line,
        ref_names
    FROM commit_refs
    ORDER BY "timestamp" DESC;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/005-status.sql =====
-- Path: /sql/functions/005-status.sql
-- pg_git status functions

CREATE OR REPLACE FUNCTION pggit.get_status(
    p_repo_id INTEGER
) RETURNS TABLE (
    path TEXT,
    status TEXT,
    staged BOOLEAN
) SET search_path = pggit, public AS $$
DECLARE
    v_head_commit TEXT;
    v_head_tree TEXT;
BEGIN
    -- Get HEAD commit and tree
    SELECT c.hash, c.tree_hash INTO v_head_commit, v_head_tree
    FROM pggit.refs r
    JOIN pggit.commits c ON r.repo_id = p_repo_id AND c.repo_id = r.repo_id AND r.commit_hash = c.hash
    WHERE r.repo_id = p_repo_id AND r.name = 'HEAD';

    RETURN QUERY
    -- Staged changes
    SELECT 
        i.path,
        CASE 
            WHEN NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(t.entries) e
                WHERE e->>'name' = i.path
            ) THEN 'new file'
            WHEN i.blob_hash != (
                SELECT e->>'hash'
                FROM jsonb_array_elements(t.entries) e
                WHERE e->>'name' = i.path
            ) THEN 'modified'
        END,
        TRUE
    FROM index_entries i
    LEFT JOIN pggit.trees t ON t.repo_id = p_repo_id AND t.hash = v_head_tree
    WHERE i.repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- Pretty format version
CREATE OR REPLACE FUNCTION pggit.get_formatted_status(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_output TEXT;
BEGIN
    SELECT string_agg(
        CASE 
            WHEN staged THEN
                format('  %s: %s', status, path)
        END,
        E'\n'
    ) INTO v_output
    FROM pggit.get_status(p_repo_id)
    WHERE status IS NOT NULL;

    RETURN format(
        'Changes to be committed:%s%s',
        E'\n',
        COALESCE(v_output, '  (no changes)')
    );
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/006-branch.sql =====
-- Path: /sql/functions/006-branch.sql
-- pg_git branch operations

CREATE OR REPLACE FUNCTION pggit.create_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_start_point TEXT DEFAULT NULL
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get commit hash from start point or HEAD
    IF p_start_point IS NULL THEN
        SELECT commit_hash INTO v_commit_hash
        FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD';
    ELSE
        v_commit_hash := p_start_point;
    END IF;

    -- Create branch reference
    INSERT INTO pggit.refs (repo_id, name, commit_hash)
    VALUES (p_repo_id, p_branch_name, v_commit_hash);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.list_branches(
    p_repo_id INTEGER
) RETURNS TABLE (
    name TEXT,
    commit_hash TEXT,
    is_current BOOLEAN
) SET search_path = pggit, public AS $$
SELECT 
    r.name,
    r.commit_hash,
    r.commit_hash = head.commit_hash AS is_current
FROM pggit.refs r
CROSS JOIN (SELECT commit_hash FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD') head
WHERE r.repo_id = p_repo_id AND r.name != 'HEAD'
ORDER BY r.name;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.checkout_branch(
    p_repo_id INTEGER,
    p_branch_name TEXT,
    p_create BOOLEAN DEFAULT FALSE
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Get branch commit
    SELECT commit_hash INTO v_commit_hash
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_branch_name;
    
    IF NOT FOUND AND p_create THEN
        -- Create new branch from HEAD
        SELECT commit_hash INTO v_commit_hash
        FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD';
        
        INSERT INTO pggit.refs (repo_id, name, commit_hash)
        VALUES (p_repo_id, p_branch_name, v_commit_hash);
    ELSIF NOT FOUND THEN
        RAISE EXCEPTION 'Branch % does not exist', p_branch_name;
    END IF;

    -- Update HEAD
    UPDATE pggit.refs SET commit_hash = v_commit_hash
    WHERE repo_id = p_repo_id AND name = 'HEAD';

    RETURN v_commit_hash;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/007-merge.sql =====
-- Path: /sql/functions/007-merge.sql
-- pg_git merge operations

-- Most recent common ancestor of two commits. Commit hashes are globally unique,
-- so the repository is implied by the commits themselves. A recursive CTE allows
-- only one non-recursive and one recursive term, so each ancestor walk is its own
-- recursive CTE and the two are intersected.
CREATE OR REPLACE FUNCTION pggit.find_merge_base(
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
WITH RECURSIVE ancestors1 AS (
    SELECT hash, parent_hash, repo_id
    FROM pggit.commits
    WHERE hash = p_commit1
    UNION ALL
    SELECT c.hash, c.parent_hash, c.repo_id
    FROM pggit.commits c
    JOIN ancestors1 a ON a.repo_id = c.repo_id AND a.parent_hash = c.hash
),
ancestors2 AS (
    SELECT hash, parent_hash, repo_id
    FROM pggit.commits
    WHERE hash = p_commit2
    UNION ALL
    SELECT c.hash, c.parent_hash, c.repo_id
    FROM pggit.commits c
    JOIN ancestors2 a ON a.repo_id = c.repo_id AND a.parent_hash = c.hash
)
SELECT c.hash
FROM ancestors1 a1
JOIN ancestors2 a2 ON a1.repo_id = a2.repo_id AND a1.hash = a2.hash
JOIN pggit.commits c ON c.repo_id = a1.repo_id AND c.hash = a1.hash
ORDER BY c.timestamp DESC
LIMIT 1;
$$ LANGUAGE sql;

-- True when p_source is an ancestor of p_target, i.e. p_target can be
-- fast-forwarded onto p_source's history (p_source is reachable from p_target).
CREATE OR REPLACE FUNCTION pggit.can_fast_forward(
    p_source TEXT,
    p_target TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
WITH RECURSIVE ancestor_chain AS (
    SELECT hash, parent_hash, repo_id
    FROM pggit.commits
    WHERE hash = p_target
    UNION ALL
    SELECT c.hash, c.parent_hash, c.repo_id
    FROM pggit.commits c
    JOIN ancestor_chain ac ON ac.repo_id = c.repo_id AND ac.parent_hash = c.hash
)
SELECT EXISTS (
    SELECT 1 FROM ancestor_chain WHERE hash = p_source
);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.merge_branches(
    p_repo_id INTEGER,
    p_source_branch TEXT,
    p_target_branch TEXT DEFAULT 'HEAD'
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_source_commit TEXT;
    v_target_commit TEXT;
BEGIN
    -- Resolve both branches, failing clearly if either is missing.
    SELECT commit_hash INTO v_source_commit
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_source_branch;
    IF v_source_commit IS NULL THEN
        RAISE EXCEPTION 'Branch % does not exist', p_source_branch;
    END IF;

    SELECT commit_hash INTO v_target_commit
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_target_branch;
    IF v_target_commit IS NULL THEN
        RAISE EXCEPTION 'Branch % does not exist', p_target_branch;
    END IF;

    -- Fast-forward is possible when the target commit is an ancestor of the
    -- source commit; advance the target ref to the source commit.
    IF pggit.can_fast_forward(v_target_commit, v_source_commit) THEN
        UPDATE pggit.refs
        SET commit_hash = v_source_commit
        WHERE repo_id = p_repo_id AND name = p_target_branch;

        RETURN v_source_commit;
    END IF;

    -- For now, only support fast-forward merges
    RAISE EXCEPTION 'Only fast-forward merges are currently supported';
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/008-diff.sql =====
-- Path: /sql/functions/008-diff.sql
-- pg_git diff operations

CREATE OR REPLACE FUNCTION pggit.diff_blobs(
    p_old_hash TEXT,
    p_new_hash TEXT
) RETURNS TABLE (
    line_type TEXT,
    line_content TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_old_content TEXT;
    v_new_content TEXT;
BEGIN
    -- Get content from pggit.blobs
    SELECT encode(content, 'escape') INTO v_old_content
    FROM pggit.blobs WHERE hash = p_old_hash;
    
    SELECT encode(content, 'escape') INTO v_new_content
    FROM pggit.blobs WHERE hash = p_new_hash;
    
    RETURN QUERY
    SELECT *
    FROM pggit.diff_text(v_old_content, v_new_content);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.diff_text(
    p_old_text TEXT,
    p_new_text TEXT
) RETURNS TABLE (
    line_type TEXT,
    line_content TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Split texts into arrays with line numbers using ordinality
    RETURN QUERY
    WITH old_lines AS (
        SELECT line, line_num
        FROM unnest(string_to_array(p_old_text, E'\n')) WITH ORDINALITY AS t(line, line_num)
    ),
    new_lines AS (
        SELECT line, line_num
        FROM unnest(string_to_array(p_new_text, E'\n')) WITH ORDINALITY AS t(line, line_num)
    )
    -- Simple line-by-line diff preserving line order. Columns are qualified with
    -- the subquery alias to avoid ambiguity with the RETURNS TABLE OUT columns.
    SELECT d.line_type, d.line_content
    FROM (
        SELECT line_num, '-' AS line_type, old_lines.line AS line_content
        FROM old_lines
        LEFT JOIN new_lines USING (line_num, line)
        WHERE new_lines.line IS NULL
        UNION ALL
        SELECT line_num, '+' AS line_type, new_lines.line AS line_content
        FROM new_lines
        LEFT JOIN old_lines USING (line_num, line)
        WHERE old_lines.line IS NULL
        UNION ALL
        SELECT line_num, ' ' AS line_type, old_lines.line AS line_content
        FROM old_lines
        JOIN new_lines USING (line_num, line)
    ) d
    ORDER BY d.line_num, CASE d.line_type WHEN '-' THEN 1 WHEN '+' THEN 2 ELSE 3 END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.diff_commits(
    p_old_commit TEXT,
    p_new_commit TEXT
) RETURNS TABLE (
    path TEXT,
    change_type TEXT,
    diff_content TEXT[]
) SET search_path = pggit, public AS $$
DECLARE
    v_repo_id INTEGER;
    v_old_tree TEXT;
    v_new_tree TEXT;
BEGIN
    -- Get tree hashes
    SELECT repo_id, tree_hash INTO v_repo_id, v_old_tree
    FROM pggit.commits WHERE hash = p_old_commit;

    IF v_repo_id IS NULL THEN
        SELECT repo_id INTO v_repo_id
        FROM pggit.commits WHERE hash = p_new_commit;
    END IF;

    SELECT tree_hash INTO v_new_tree
    FROM pggit.commits WHERE hash = p_new_commit AND repo_id = v_repo_id;

    RETURN QUERY
    SELECT
        d.path,
        d.change_type,
        CASE 
            WHEN d.change_type = 'modified' THEN
                ARRAY(
                    SELECT line_type || line_content
                    FROM pggit.diff_blobs(d.old_hash, d.new_hash)
                )
            ELSE
                ARRAY[]::TEXT[]
        END as diff_content
    FROM pggit.diff_trees(v_repo_id, v_old_tree, v_new_tree) d;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/009-reset.sql =====
-- Path: /sql/functions/009-reset.sql
-- pg_git reset operations

CREATE OR REPLACE FUNCTION pggit.reset_soft(
    p_repo_id INTEGER,
    p_commit TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    -- Move HEAD to specified commit
    UPDATE pggit.refs
    SET commit_hash = p_commit
    WHERE repo_id = p_repo_id AND name = 'HEAD';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.reset_mixed(
    p_repo_id INTEGER,
    p_commit TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    -- Move HEAD and clear index
    PERFORM pggit.reset_soft(p_repo_id, p_commit);
    DELETE FROM index_entries WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.reset_file(
    p_repo_id INTEGER,
    p_path TEXT,
    p_commit TEXT DEFAULT 'HEAD'
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
    v_tree_hash TEXT;
    v_blob_hash TEXT;
BEGIN
    -- Resolve p_commit: a ref name (e.g. the default 'HEAD' or a branch) maps to
    -- its commit hash; otherwise it is already a commit hash. Without this the
    -- default 'HEAD' is looked up as a literal commit hash, finds nothing, and
    -- the file is wrongly dropped from the index instead of restored.
    SELECT commit_hash INTO v_commit_hash
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_commit;
    v_commit_hash := COALESCE(v_commit_hash, p_commit);

    -- Get tree from commit
    SELECT tree_hash INTO v_tree_hash
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = v_commit_hash;
    
    -- Get blob hash from tree
    SELECT (e->>'hash')::TEXT INTO v_blob_hash
    FROM pggit.trees t,
    jsonb_array_elements(t.entries) e
    WHERE t.repo_id = p_repo_id AND t.hash = v_tree_hash
    AND e->>'name' = p_path;
    
    IF v_blob_hash IS NULL THEN
        -- File doesn't exist in commit, remove from index
        DELETE FROM index_entries 
        WHERE repo_id = p_repo_id AND path = p_path;
    ELSE
        -- Update index with blob from commit
        INSERT INTO index_entries (repo_id, path, blob_hash)
        VALUES (p_repo_id, p_path, v_blob_hash)
        ON CONFLICT (repo_id, path) 
        DO UPDATE SET blob_hash = v_blob_hash;
    END IF;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/010-tag.sql =====
-- Path: /sql/functions/010-tag.sql
-- pg_git tag operations

CREATE TABLE pggit.tags (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    name TEXT NOT NULL,
    target_hash TEXT NOT NULL,
    tagger TEXT NOT NULL,
    message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, name)
);

CREATE OR REPLACE FUNCTION pggit.create_tag(
    p_repo_id INTEGER,
    p_name TEXT,
    p_target TEXT DEFAULT 'HEAD',
    p_tagger TEXT DEFAULT current_user,
    p_message TEXT DEFAULT NULL
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_target_hash TEXT;
BEGIN
    -- Resolve target to commit hash
    IF p_target = 'HEAD' THEN
        SELECT commit_hash INTO v_target_hash
        FROM pggit.refs WHERE repo_id = p_repo_id AND name = 'HEAD';
    ELSE
        v_target_hash := p_target;
    END IF;

    INSERT INTO pggit.tags (repo_id, name, target_hash, tagger, message)
    VALUES (p_repo_id, p_name, v_target_hash, p_tagger, p_message);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.list_tags(
    p_repo_id INTEGER
) RETURNS TABLE (
    name TEXT,
    target_hash TEXT,
    tagger TEXT,
    message TEXT,
    created_at TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
    SELECT name, target_hash, tagger, message, created_at
    FROM pggit.tags
    WHERE repo_id = p_repo_id
    ORDER BY created_at DESC;$$ LANGUAGE sql;

-- ===== sql/functions/011-remote.sql =====
-- Path: /sql/functions/011-remote.sql
-- pg_git remote operations

CREATE TABLE pggit.remotes (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, name)
);

CREATE TABLE pggit.remote_refs (
    repo_id INTEGER,
    remote_name TEXT,
    ref_name TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    last_fetch TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, remote_name, ref_name),
    FOREIGN KEY (repo_id, remote_name) REFERENCES pggit.remotes(repo_id, name)
);

COMMENT ON TABLE pggit.remote_refs IS
    'Source of truth for fetched remote branch tips. fetch_remote materializes these into refs as <remote>/<branch> tracking refs.';

CREATE OR REPLACE FUNCTION pggit.add_remote(
    p_repo_id INTEGER,
    p_name TEXT,
    p_url TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.remotes (repo_id, name, url)
    VALUES (p_repo_id, p_name, p_url);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.fetch_remote(
    p_repo_id INTEGER,
    p_remote_name TEXT
) RETURNS TABLE (
    ref_name TEXT,
    old_hash TEXT,
    new_hash TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_remote_url TEXT;
BEGIN
    -- Get remote URL
    SELECT url INTO v_remote_url
    FROM pggit.remotes
    WHERE repo_id = p_repo_id AND name = p_remote_name;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Remote % does not exist for repo %', p_remote_name, p_repo_id;
    END IF;

    -- Source of truth: pggit.remote_refs stores fetched remote branch tips.
    -- Materialized remote-tracking refs in refs are derived as <remote>/<branch>.
    RETURN QUERY
    WITH tracking AS (
        SELECT
            rr.ref_name,
            (p_remote_name || '/' || rr.ref_name) AS tracking_ref,
            rr.commit_hash AS remote_hash
        FROM pggit.remote_refs rr
        WHERE rr.repo_id = p_repo_id
          AND rr.remote_name = p_remote_name
    ),
    existing AS (
        SELECT name, commit_hash
        FROM refs
        WHERE repo_id = p_repo_id
    ),
    upserted AS (
        INSERT INTO refs (repo_id, name, commit_hash)
        SELECT p_repo_id, tracking_ref, remote_hash
        FROM tracking
        ON CONFLICT (repo_id, name)
        DO UPDATE SET commit_hash = EXCLUDED.commit_hash
        RETURNING name, commit_hash
    )
    SELECT
        t.ref_name,
        e.commit_hash AS old_hash,
        u.commit_hash AS new_hash
    FROM upserted u
    JOIN tracking t ON t.tracking_ref = u.name
    LEFT JOIN existing e ON e.name = t.tracking_ref;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.push(
    p_repo_id INTEGER,
    p_remote_name TEXT,
    p_ref_name TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_remote_url TEXT;
    v_commit_hash TEXT;
BEGIN
    -- Get remote URL
    SELECT url INTO v_remote_url
    FROM pggit.remotes
    WHERE repo_id = p_repo_id AND name = p_remote_name;

    -- Get local ref
    SELECT commit_hash INTO v_commit_hash
    FROM pggit.refs WHERE repo_id = p_repo_id AND name = p_ref_name;

    -- In a real implementation, this would:
    -- 1. Connect to remote database
    -- 2. Push missing objects
    -- 3. Update remote ref
    RAISE NOTICE 'Would push % to %/%', v_commit_hash, v_remote_url, p_ref_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.pull(
    p_repo_id INTEGER,
    p_remote_name TEXT,
    p_ref_name TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_tracking_ref TEXT;
BEGIN
    -- Fetch from remote
    PERFORM pggit.fetch_remote(p_repo_id, p_remote_name);

    v_tracking_ref := p_remote_name || '/' || p_ref_name;

    IF NOT EXISTS (
        SELECT 1
        FROM refs
        WHERE repo_id = p_repo_id
          AND name = v_tracking_ref
    ) THEN
        RAISE EXCEPTION 'Remote-tracking ref % does not exist for repo %', v_tracking_ref, p_repo_id;
    END IF;

    -- Merge verified remote-tracking ref into local branch
    RETURN pggit.merge_branches(
        p_repo_id,
        v_tracking_ref,
        p_ref_name
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.clone(
    p_url TEXT,
    p_name TEXT,
    p_path TEXT
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    -- Create new repo
    v_repo_id := pggit.init_repository(p_name, p_path);
    
    -- Add remote
    PERFORM pggit.add_remote(v_repo_id, 'origin', p_url);
    
    -- Fetch everything
    PERFORM pggit.fetch_remote(v_repo_id, 'origin');
    
    -- Checkout main branch
    PERFORM pggit.checkout_branch(v_repo_id, 'main', TRUE);
    
    RETURN v_repo_id;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/012-migrations.sql =====
-- Path: /sql/functions/012-migrations.sql
-- pg_git schema migrations

CREATE TABLE pggit.schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.get_current_schema_version()
RETURNS INTEGER SET search_path = pggit, public AS $$
    SELECT COALESCE(MAX(version), 0) FROM pggit.schema_migrations;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.run_migration(
    p_version INTEGER,
    p_up TEXT,
    p_down TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    IF p_version > pggit.get_current_schema_version() THEN
        EXECUTE p_up;
        INSERT INTO pggit.schema_migrations (version) VALUES (p_version);
    END IF;
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/013-merge-conflicts.sql =====
-- Path: /sql/functions/013-merge-conflicts.sql
-- pg_git merge conflict resolution

CREATE TABLE pggit.merge_conflicts (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    path TEXT NOT NULL,
    our_blob_hash TEXT,
    their_blob_hash TEXT,
    base_blob_hash TEXT,
    resolution_blob_hash TEXT,
    status TEXT CHECK (status IN ('unresolved', 'resolved', 'ignored')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, path),
    FOREIGN KEY (repo_id, our_blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    FOREIGN KEY (repo_id, their_blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    FOREIGN KEY (repo_id, base_blob_hash) REFERENCES pggit.blobs(repo_id, hash),
    FOREIGN KEY (repo_id, resolution_blob_hash) REFERENCES pggit.blobs(repo_id, hash)
);

-- A three-way merge of a single path needs no manual resolution when either
-- side is unchanged from the base (take the other side) or both sides resolve
-- to the same blob. Anything else is a genuine conflict. NULL means the file is
-- absent on that side (added or deleted), so IS [NOT] DISTINCT FROM is used to
-- compare hashes without tripping over NULL semantics.
CREATE OR REPLACE FUNCTION pggit.can_auto_merge(
    p_our_hash TEXT,
    p_their_hash TEXT,
    p_base_hash TEXT
) RETURNS BOOLEAN IMMUTABLE SET search_path = pggit, public AS $$
    SELECT p_our_hash IS NOT DISTINCT FROM p_their_hash   -- both sides agree
        OR p_our_hash IS NOT DISTINCT FROM p_base_hash    -- we didn't change it
        OR p_their_hash IS NOT DISTINCT FROM p_base_hash; -- they didn't change it
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.detect_conflicts(
    p_repo_id INTEGER,
    p_our_commit TEXT,
    p_their_commit TEXT
) RETURNS TABLE (
    path TEXT,
    conflict_type TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_base_commit TEXT;
    v_our_tree TEXT;
    v_their_tree TEXT;
    v_base_tree TEXT;
BEGIN
    -- Find merge base (find_merge_base identifies the repo from the commits).
    v_base_commit := pggit.find_merge_base(p_our_commit, p_their_commit);

    -- Resolve each commit to its tree. get_tree_files expects a tree hash, not
    -- a commit hash. A missing/NULL commit yields a NULL tree, i.e. no files.
    SELECT tree_hash INTO v_our_tree
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = p_our_commit;
    SELECT tree_hash INTO v_their_tree
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = p_their_commit;
    SELECT tree_hash INTO v_base_tree
    FROM pggit.commits WHERE repo_id = p_repo_id AND hash = v_base_commit;

    RETURN QUERY
    -- Columns are qualified via the function alias: the RETURNS TABLE OUT
    -- parameter "path" would otherwise shadow the unqualified column name.
    WITH our_files AS (
        SELECT gtf.path, gtf.blob_hash
        FROM pggit.get_tree_files(p_repo_id, v_our_tree) gtf
    ),
    their_files AS (
        SELECT gtf.path, gtf.blob_hash
        FROM pggit.get_tree_files(p_repo_id, v_their_tree) gtf
    ),
    base_files AS (
        SELECT gtf.path, gtf.blob_hash
        FROM pggit.get_tree_files(p_repo_id, v_base_tree) gtf
    )
    SELECT DISTINCT f.path,
           CASE
               WHEN o.blob_hash IS NULL AND t.blob_hash IS NOT NULL THEN 'deleted_modified'
               WHEN t.blob_hash IS NULL AND o.blob_hash IS NOT NULL THEN 'modified_deleted'
               WHEN b.blob_hash IS NULL THEN 'add_add'
               ELSE 'content'
           END as conflict_type
    FROM (SELECT our_files.path FROM our_files
          UNION SELECT their_files.path FROM their_files) f
    LEFT JOIN our_files o ON f.path = o.path
    LEFT JOIN their_files t ON f.path = t.path
    LEFT JOIN base_files b ON f.path = b.path
    WHERE NOT pggit.can_auto_merge(o.blob_hash, t.blob_hash, b.blob_hash);
END;$$ LANGUAGE plpgsql;

-- ===== sql/functions/014-https.sql =====
-- Path: /sql/functions/014-https.sql
-- pg_git HTTPS transport

CREATE TABLE pggit.credentials (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    host TEXT NOT NULL,
    username TEXT NOT NULL,
    password BYTEA NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, host)
);

CREATE OR REPLACE FUNCTION pggit.store_credentials(
    p_repo_id INTEGER,
    p_host TEXT,
    p_username TEXT,
    p_password TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_key TEXT := current_setting('pggit.credential_key', true);
BEGIN
    INSERT INTO pggit.credentials (repo_id, host, username, password)
    VALUES (
        p_repo_id,
        p_host,
        p_username,
        pgp_sym_encrypt(p_password, coalesce(v_key, 'pg_git_default_key'))
    )
    ON CONFLICT (repo_id, host) DO UPDATE
    SET username = EXCLUDED.username,
        password = pgp_sym_encrypt(p_password, coalesce(v_key, 'pg_git_default_key'));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.http_fetch(
    p_repo_id INTEGER,
    p_url TEXT
) RETURNS BYTEA SET search_path = pggit, public AS $$import base64
import ssl
from urllib.parse import urlparse
import urllib.request
import urllib.error

host = urlparse(p_url).hostname
key = plpy.execute("SELECT current_setting('pggit.credential_key', true) AS k")[0]['k'] or 'pg_git_default_key'
# Parameterized queries require a prepared plan; plpy.execute(query, x) treats x
# as a row limit, not bind parameters.
cred_plan = plpy.prepare(
    "SELECT username, pgp_sym_decrypt(password, $1) AS pw FROM pggit.credentials WHERE repo_id = $2 AND host = $3",
    ["text", "integer", "text"]
)
cred = plpy.execute(cred_plan, [key, p_repo_id, host])

context = ssl.create_default_context()

username = None
password = None
if len(cred) > 0:
    username = cred[0]['username']
    password = cred[0]['pw']

req = urllib.request.Request(p_url)
if username:
    token = f"{username}:{password}".encode('utf-8')
    req.add_header('Authorization', 'Basic ' + base64.b64encode(token).decode('ascii'))

try:
    with urllib.request.urlopen(req, context=context, timeout=10) as resp:
        data = resp.read()
except urllib.error.HTTPError as e:
    raise plpy.Error(f"Failed to fetch {p_url}: HTTP {e.code} {e.reason}")
except urllib.error.URLError as e:
    raise plpy.Error(f"Failed to fetch {p_url}: {e.reason}")

return data
$$ LANGUAGE plpython3u;

-- ===== sql/functions/015-admin.sql =====
-- Path: /sql/functions/015-admin.sql
-- pg_git admin functions

CREATE OR REPLACE FUNCTION pggit.gc(
    p_repo_id INTEGER
) RETURNS TABLE (
    object_type TEXT,
    objects_removed INTEGER,
    space_reclaimed BIGINT
) SET search_path = pggit, public AS $$
BEGIN
    -- Ensure temporary table does not exist from prior runs
    DROP TABLE IF EXISTS tmp_reachable_objects;

    -- Collect all reachable objects into a temporary table
    CREATE TEMP TABLE tmp_reachable_objects(hash TEXT PRIMARY KEY) ON COMMIT DROP;

    -- PostgreSQL recursive CTEs allow only a single self-reference in the
    -- recursive term, so the different edge types (commit->parent, commit->tree,
    -- tree->entries) are expanded in one LATERAL branch off the working row.
    WITH RECURSIVE reachable(object_type, hash) AS (
        -- Start from pggit.refs
        SELECT 'commit'::TEXT, commit_hash FROM pggit.refs WHERE repo_id = p_repo_id
        UNION
        SELECT nxt.object_type, nxt.hash
        FROM reachable r
        CROSS JOIN LATERAL (
            -- Walk parent commits
            SELECT 'commit'::TEXT AS object_type, c.parent_hash AS hash
            FROM pggit.commits c
            WHERE r.object_type = 'commit' AND c.repo_id = p_repo_id
              AND c.hash = r.hash AND c.parent_hash IS NOT NULL
            UNION ALL
            -- Commits reference trees
            SELECT 'tree'::TEXT, c.tree_hash
            FROM pggit.commits c
            WHERE r.object_type = 'commit' AND c.repo_id = p_repo_id AND c.hash = r.hash
            UNION ALL
            -- Trees reference blobs and subtrees
            SELECT (e->>'type')::TEXT, e->>'hash'
            FROM pggit.trees t
            CROSS JOIN LATERAL jsonb_array_elements(t.entries) AS e
            WHERE r.object_type = 'tree' AND t.repo_id = p_repo_id AND t.hash = r.hash
        ) nxt
        WHERE nxt.hash IS NOT NULL
    )
    INSERT INTO tmp_reachable_objects
    SELECT DISTINCT hash FROM reachable;

    -- Remove unreachable objects
    RETURN QUERY
    WITH deleted_blobs AS (
        DELETE FROM pggit.blobs b
        WHERE b.repo_id = p_repo_id AND NOT EXISTS (
            SELECT 1 FROM tmp_reachable_objects r WHERE r.hash = b.hash
        )
        RETURNING octet_length(content) AS size
    ), deleted_trees AS (
        DELETE FROM pggit.trees t
        WHERE t.repo_id = p_repo_id AND NOT EXISTS (
            SELECT 1 FROM tmp_reachable_objects r WHERE r.hash = t.hash
        )
        RETURNING octet_length(entries::TEXT) AS size
    ), deleted_commits AS (
        DELETE FROM pggit.commits c
        WHERE c.repo_id = p_repo_id AND NOT EXISTS (
            SELECT 1 FROM tmp_reachable_objects r WHERE r.hash = c.hash
        )
        RETURNING octet_length(message) AS size
    )
    SELECT 'blobs'::TEXT,
           count(*)::INTEGER,
           COALESCE(sum(size),0)::BIGINT FROM deleted_blobs
    UNION ALL
    SELECT 'trees'::TEXT,
           count(*)::INTEGER,
           COALESCE(sum(size),0)::BIGINT FROM deleted_trees
    UNION ALL
    SELECT 'commits'::TEXT,
           count(*)::INTEGER,
           COALESCE(sum(size),0)::BIGINT FROM deleted_commits;

    -- Explicitly drop temporary table
    DROP TABLE IF EXISTS tmp_reachable_objects;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_integrity(
    p_repo_id INTEGER
) RETURNS TABLE (
    check_type TEXT,
    status TEXT,
    details TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Check dangling pggit.commits
    RETURN QUERY
    SELECT 'dangling_commits'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warning' END,
           count(*) || ' dangling pggit.commits found'
    FROM pggit.commits c
    WHERE c.repo_id = p_repo_id
      AND NOT EXISTS (SELECT 1 FROM pggit.refs r WHERE r.repo_id = p_repo_id AND r.commit_hash = c.hash);

    -- Check broken parent links
    RETURN QUERY
    SELECT 'broken_parents'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'error' END,
           count(*) || ' pggit.commits with invalid parent references'
    FROM pggit.commits c
    WHERE c.repo_id = p_repo_id
      AND c.parent_hash IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM pggit.commits p WHERE p.repo_id = p_repo_id AND p.hash = c.parent_hash);
    
    -- Check broken tree references
    RETURN QUERY
    SELECT 'broken_trees'::TEXT,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'error' END,
           count(*) || ' pggit.commits with invalid tree references'
    FROM pggit.commits c
    WHERE c.repo_id = p_repo_id
      AND NOT EXISTS (SELECT 1 FROM pggit.trees t WHERE t.repo_id = p_repo_id AND t.hash = c.tree_hash);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.optimize_indexes(
    p_repo_id INTEGER
) RETURNS TABLE (
    table_name TEXT,
    index_name TEXT,
    operation TEXT,
    success BOOLEAN
) SET search_path = pggit, public AS $$
DECLARE
    v_table TEXT;
    v_index TEXT;
BEGIN
    -- Reindex each index in the pggit schema, capturing per-index success.
    -- Results are emitted with RETURN NEXT (no temp table) so the function makes
    -- no catalog writes of its own and can run in a read-only transaction.
    FOR v_table, v_index IN
        SELECT t.tablename::TEXT,
               i.indexname::TEXT
        FROM pg_tables t
        JOIN pg_indexes i ON i.schemaname = t.schemaname AND i.tablename = t.tablename
        WHERE t.schemaname = 'pggit'
        ORDER BY t.tablename, i.indexname
    LOOP
        table_name := v_table;
        index_name := v_index;
        operation := 'REINDEX';
        BEGIN
            EXECUTE format('REINDEX INDEX pggit.%I', v_index);
            success := TRUE;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Reindex failed for %: %', v_index, SQLERRM;
            success := FALSE;
        END;
        RETURN NEXT;
    END LOOP;
END;$$ LANGUAGE plpgsql;

-- ===== sql/pgit-advanced-commands.sql =====
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

-- ===== sql/pgit-archive.sql =====
-- Path: /sql/functions/019-archive.sql
-- Archive functionality

CREATE OR REPLACE FUNCTION pggit.create_archive(
    p_repo_id INTEGER,
    p_tree_ish TEXT DEFAULT 'HEAD',
    p_format TEXT DEFAULT 'tar'
) RETURNS BYTEA SET search_path = pggit, public AS $$
DECLARE
    v_tree_hash TEXT;
    v_archive BYTEA;
    v_header BYTEA;
    v_footer BYTEA;
BEGIN
    -- Resolve tree-ish to tree hash (scoped to this repository).
    IF p_tree_ish = 'HEAD' THEN
        SELECT tree_hash INTO v_tree_hash
        FROM commits c
        JOIN refs r ON c.repo_id = r.repo_id AND c.hash = r.commit_hash
        WHERE r.repo_id = p_repo_id AND r.name = 'HEAD';
    ELSE
        SELECT tree_hash INTO v_tree_hash
        FROM commits
        WHERE repo_id = p_repo_id AND hash = p_tree_ish;
    END IF;

    -- Initialize archive based on format
    CASE p_format
        WHEN 'tar' THEN
            v_header := '\x00'::BYTEA; -- tar header
            v_footer := '\x00'::BYTEA; -- tar footer
        WHEN 'zip' THEN
            -- bytea hex format is a single \x prefix followed by all hex digits;
            -- '\x50\x4B...' repeats the prefix and is rejected as invalid hex.
            v_header := '\x504B0304'::BYTEA; -- ZIP header
            v_footer := '\x504B0506'::BYTEA; -- ZIP footer
    END CASE;

    -- Build archive content
    WITH RECURSIVE tree_files AS (
        SELECT e->>'name' as path,
               e->>'hash' as hash,
               e->>'mode' as mode
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE trees.repo_id = p_repo_id AND trees.hash = v_tree_hash

        UNION ALL

        -- Parenthesize (e->>'name'): || binds tighter than ->>, so without the
        -- parens this parses as (tf.path || '/' || e) ->> 'name' and fails.
        SELECT tf.path || '/' || (e->>'name'),
               e->>'hash',
               e->>'mode'
        FROM tree_files tf
        JOIN trees t ON t.repo_id = p_repo_id AND tf.hash = t.hash,
        jsonb_array_elements(t.entries) e
        WHERE e->>'type' = 'tree'
    )
    SELECT v_header ||
           string_agg(
               CASE p_format
                   WHEN 'tar' THEN
                       -- tar file header (simplified)
                       convert_to(rpad(tf.path, 100, '\0'), 'UTF8') ||
                       convert_to(rpad(tf.mode, 8, '\0'), 'UTF8') ||
                       b.content
                   WHEN 'zip' THEN
                       -- zip file header (simplified)
                       convert_to(tf.path || '\n', 'UTF8') ||
                       b.content
               END,
               ''::BYTEA
           ) || v_footer
    INTO v_archive
    FROM tree_files tf
    JOIN blobs b ON b.repo_id = p_repo_id AND tf.hash = b.hash;

    RETURN v_archive;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-bundle.sql =====
-- Path: /sql/functions/032-bundle.sql
-- Bundle repository data for offline transfer

CREATE TABLE pggit.bundles (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    description TEXT,
    prerequisites TEXT[] DEFAULT ARRAY[]::TEXT[],
    "references" TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.create_bundle(
    p_repo_id INTEGER,
    p_name TEXT,
    p_refs TEXT[],
    p_description TEXT DEFAULT NULL
) RETURNS BYTEA SET search_path = pggit, public AS $$
DECLARE
    v_bundle_data BYTEA;
    v_bundle_id INTEGER;
BEGIN
    -- Create bundle record
    INSERT INTO pggit.bundles (repo_id, name, description, "references")
    VALUES (p_repo_id, p_name, p_description, p_refs)
    RETURNING id INTO v_bundle_id;

    -- Collect all required objects
    WITH RECURSIVE bundle_objects AS (
        -- Start with referenced commits
        SELECT hash, tree_hash, parent_hash
        FROM commits c
        WHERE hash = ANY(p_refs)
        
        UNION
        
        -- Include parent commits
        SELECT c.hash, c.tree_hash, c.parent_hash
        FROM commits c
        JOIN bundle_objects b ON c.hash = b.parent_hash
    ),
    all_objects AS (
        -- Include commit objects
        SELECT hash::TEXT as hash, 'commit'::TEXT as type
        FROM bundle_objects
        
        UNION ALL
        
        -- Include tree objects
        SELECT hash, 'tree'
        FROM trees
        WHERE hash IN (SELECT tree_hash FROM bundle_objects)
        
        UNION ALL
        
        -- Include blob objects
        SELECT hash, 'blob'
        FROM blobs
        WHERE hash IN (
            SELECT e->>'hash'
            FROM trees t,
            jsonb_array_elements(t.entries) e
            WHERE t.hash IN (SELECT tree_hash FROM bundle_objects)
        )
    )
    SELECT encode(
        string_agg(
            CASE type
                WHEN 'commit' THEN
                    (SELECT encode(message::bytea, 'hex') FROM commits WHERE hash = o.hash)
                WHEN 'tree' THEN
                    (SELECT encode(entries::text::bytea, 'hex') FROM trees WHERE hash = o.hash)
                WHEN 'blob' THEN
                    (SELECT encode(content, 'hex') FROM blobs WHERE hash = o.hash)
            END,
            E'\n'
        )::bytea,
        'hex'
    )::bytea INTO v_bundle_data
    FROM all_objects o;

    RETURN v_bundle_data;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.unbundle(
    p_repo_id INTEGER,
    p_bundle_data BYTEA
) RETURNS TABLE (
    type TEXT,
    hash TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_line RECORD;
BEGIN
    FOR v_line IN
        SELECT unnest(string_to_array(convert_from(p_bundle_data, 'UTF8'), E'\n')) as data
    LOOP
        -- Parse and store objects
        IF substring(v_line.data, 1, 6) = 'commit' THEN
            INSERT INTO commits (hash, message)
            VALUES (
                encode(sha256(decode(substring(v_line.data, 8), 'hex')), 'hex'),
                convert_from(decode(substring(v_line.data, 8), 'hex'), 'UTF8')
            )
            ON CONFLICT DO NOTHING
            RETURNING 'commit', hash;
        ELSIF substring(v_line.data, 1, 4) = 'tree' THEN
            INSERT INTO trees (hash, entries)
            VALUES (
                encode(sha256(decode(substring(v_line.data, 6), 'hex')), 'hex'),
                convert_from(decode(substring(v_line.data, 6), 'hex'), 'UTF8')::jsonb
            )
            ON CONFLICT DO NOTHING
            RETURNING 'tree', hash;
        ELSIF substring(v_line.data, 1, 4) = 'blob' THEN
            INSERT INTO blobs (hash, content)
            VALUES (
                encode(sha256(decode(substring(v_line.data, 6), 'hex')), 'hex'),
                decode(substring(v_line.data, 6), 'hex')
            )
            ON CONFLICT DO NOTHING
            RETURNING 'blob', hash;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-diagnose.sql =====
-- Path: /sql/functions/024-diagnose.sql
-- Diagnostic information collection

CREATE TABLE pggit.diagnostic_reports (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    report_type TEXT NOT NULL,
    report_data JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.collect_diagnostics(
    p_repo_id INTEGER
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_report_id INTEGER;
    v_report_data JSONB;
BEGIN
    -- Collect repository info
    WITH repo_info AS (
        SELECT r.*,
               (SELECT COUNT(*) FROM commits c) as commit_count,
               (SELECT COUNT(*) FROM blobs b) as blob_count,
               (SELECT COUNT(*) FROM trees t) as tree_count,
               (SELECT COUNT(*) FROM refs rf) as ref_count
        FROM repositories r
        WHERE id = p_repo_id
    ),
    -- Collect size info
    size_info AS (
        SELECT 'blobs' as type, pg_size_pretty(sum(octet_length(content))) as total_size
        FROM blobs
        UNION ALL
        SELECT 'trees', pg_size_pretty(sum(octet_length(entries::text)))
        FROM trees
    ),
    -- Collect performance metrics
    perf_metrics AS (
        SELECT obj_description(oid) as last_gc_run
        FROM pg_class
        WHERE relname = 'blobs'
    ),
    -- Collect error info
    error_info AS (
        SELECT status, count(*) as count
        FROM pggit.verify_integrity(p_repo_id)
        GROUP BY status
    )
    SELECT jsonb_build_object(
        'repository', row_to_json(repo_info),
        'sizes', jsonb_agg(to_jsonb(size_info)),
        'performance', to_jsonb(perf_metrics),
        'errors', jsonb_agg(to_jsonb(error_info)),
        'configs', (
            SELECT jsonb_object_agg(key, value)
            FROM pggit.config
            WHERE repo_id = p_repo_id
        )
    )
    INTO v_report_data
    FROM repo_info, size_info, perf_metrics, error_info;

    -- Store report
    INSERT INTO pggit.diagnostic_reports (repo_id, report_type, report_data)
    VALUES (p_repo_id, 'full', v_report_data)
    RETURNING id INTO v_report_id;

    RETURN v_report_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.get_diagnostic_report(
    p_report_id INTEGER
) RETURNS TABLE (
    section TEXT,
    content TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH report AS (
        SELECT report_data
        FROM pggit.diagnostic_reports
        WHERE id = p_report_id
    )
    SELECT 'Repository Info' as section,
           jsonb_pretty(report_data->'repository') as content
    FROM report
    UNION ALL
    SELECT 'Storage Usage',
           jsonb_pretty(report_data->'sizes')
    FROM report
    UNION ALL
    SELECT 'Performance Metrics',
           jsonb_pretty(report_data->'performance')
    FROM report
    UNION ALL
    SELECT 'Error Summary',
           jsonb_pretty(report_data->'errors')
    FROM report
    UNION ALL
    SELECT 'Configuration',
           jsonb_pretty(report_data->'configs')
    FROM report;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-extras.sql =====
-- Path: /sql/functions/018-extras.sql
-- Additional Git commands and utilities

-- Cherry-pick implementation
CREATE OR REPLACE FUNCTION pggit.cherry_pick(
    p_repo_id INTEGER,
    p_commit_hash TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_tree_hash TEXT;
    v_new_commit TEXT;
    v_message TEXT;
    v_author TEXT;
BEGIN
    -- Get commit details
    SELECT tree_hash, message, author 
    INTO v_tree_hash, v_message, v_author
    FROM commits WHERE hash = p_commit_hash;
    
    -- Create new commit with same tree
    v_new_commit := pggit.create_commit(
        p_repo_id,
        v_tree_hash,
        (SELECT commit_hash FROM refs WHERE repo_id = p_repo_id AND name = 'HEAD'),
        v_author,
        v_message || ' (cherry-picked from ' || p_commit_hash || ')'
    );
    
    -- Update HEAD
    UPDATE refs
    SET commit_hash = v_new_commit
    WHERE repo_id = p_repo_id AND name = 'HEAD';
    
    RETURN v_new_commit;
END;
$$ LANGUAGE plpgsql;

-- Revert implementation
CREATE OR REPLACE FUNCTION pggit.revert(
    p_repo_id INTEGER,
    p_commit_hash TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_parent_tree TEXT;
    v_commit_tree TEXT;
    v_new_tree TEXT;
    v_new_commit TEXT;
    v_message TEXT;
BEGIN
    -- Get trees and message
    SELECT tree_hash, message,
           (SELECT tree_hash FROM commits WHERE repo_id = p_repo_id AND hash = c.parent_hash)
    INTO v_commit_tree, v_message, v_parent_tree
    FROM commits c
    WHERE c.repo_id = p_repo_id AND hash = p_commit_hash;
    
    -- Create inverse diff
    v_new_tree := pggit.apply_inverse_diff(v_parent_tree, v_commit_tree);
    
    -- Create revert commit
    v_new_commit := pggit.create_commit(
        p_repo_id,
        v_new_tree,
        (SELECT commit_hash FROM refs WHERE repo_id = p_repo_id AND name = 'HEAD'),
        current_user,
        'Revert "' || v_message || '"'
    );
    
    -- Update HEAD
    UPDATE refs
    SET commit_hash = v_new_commit
    WHERE repo_id = p_repo_id AND name = 'HEAD';
    
    RETURN v_new_commit;
END;
$$ LANGUAGE plpgsql;

-- Bisect implementation
CREATE TABLE pggit.bisect_state (
    repo_id INTEGER REFERENCES repositories(id),
    start_commit TEXT NOT NULL,
    good_commits TEXT[] DEFAULT ARRAY[]::TEXT[],
    bad_commits TEXT[] DEFAULT ARRAY[]::TEXT[],
    current_commit TEXT,
    PRIMARY KEY (repo_id)
);

CREATE OR REPLACE FUNCTION pggit.bisect_start(
    p_repo_id INTEGER,
    p_bad_commit TEXT,
    p_good_commit TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_mid_commit TEXT;
BEGIN
    -- Initialize bisect state
    INSERT INTO pggit.bisect_state (repo_id, start_commit, good_commits, bad_commits)
    VALUES (p_repo_id, p_bad_commit, ARRAY[p_good_commit], ARRAY[p_bad_commit])
    ON CONFLICT (repo_id) DO UPDATE
    SET start_commit = p_bad_commit,
        good_commits = ARRAY[p_good_commit],
        bad_commits = ARRAY[p_bad_commit];
    
    -- Find middle commit
    SELECT hash INTO v_mid_commit
    FROM (
        SELECT hash, ROW_NUMBER() OVER (ORDER BY timestamp) as rn,
               COUNT(*) OVER () as total
        FROM pggit.rev_list(p_bad_commit, ARRAY[p_good_commit])
    ) commits
    WHERE rn = total/2;
    
    -- Update current commit
    UPDATE pggit.bisect_state
    SET current_commit = v_mid_commit
    WHERE repo_id = p_repo_id;
    
    RETURN v_mid_commit;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.bisect_good(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_current TEXT;
    v_next TEXT;
BEGIN
    -- Get current state
    SELECT current_commit INTO v_current
    FROM pggit.bisect_state
    WHERE repo_id = p_repo_id;
    
    -- Add to good commits
    UPDATE pggit.bisect_state
    SET good_commits = array_append(good_commits, v_current)
    WHERE repo_id = p_repo_id;
    
    -- Find next commit to test
    SELECT hash INTO v_next
    FROM (
        SELECT hash, ROW_NUMBER() OVER (ORDER BY timestamp) as rn,
               COUNT(*) OVER () as total
        FROM pggit.rev_list(
            (SELECT bad_commits[1] FROM pggit.bisect_state WHERE repo_id = p_repo_id),
            (SELECT good_commits FROM pggit.bisect_state WHERE repo_id = p_repo_id)
        )
    ) commits
    WHERE rn = total/2;
    
    -- Update current commit
    UPDATE pggit.bisect_state
    SET current_commit = v_next
    WHERE repo_id = p_repo_id;
    
    RETURN v_next;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.bisect_bad(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_current TEXT;
    v_next TEXT;
BEGIN
    -- Get current state
    SELECT current_commit INTO v_current
    FROM pggit.bisect_state
    WHERE repo_id = p_repo_id;
    
    -- Add to bad commits
    UPDATE pggit.bisect_state
    SET bad_commits = array_append(bad_commits, v_current)
    WHERE repo_id = p_repo_id;
    
    -- Find next commit to test
    SELECT hash INTO v_next
    FROM (
        SELECT hash, ROW_NUMBER() OVER (ORDER BY timestamp) as rn,
               COUNT(*) OVER () as total
        FROM pggit.rev_list(
            (SELECT bad_commits[1] FROM pggit.bisect_state WHERE repo_id = p_repo_id),
            (SELECT good_commits FROM pggit.bisect_state WHERE repo_id = p_repo_id)
        )
    ) commits
    WHERE rn = total/2;
    
    -- Update current commit
    UPDATE pggit.bisect_state
    SET current_commit = v_next
    WHERE repo_id = p_repo_id;
    
    RETURN v_next;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.bisect_reset(
    p_repo_id INTEGER
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    DELETE FROM pggit.bisect_state
    WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- Grep implementation
CREATE OR REPLACE FUNCTION pggit.grep(
    p_repo_id INTEGER,
    p_pattern TEXT,
    p_commit TEXT DEFAULT 'HEAD',
    p_ignore_case BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    file_path TEXT,
    line_number INTEGER,
    line_content TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Resolve commit
    IF p_commit = 'HEAD' THEN
        SELECT commit_hash INTO v_commit_hash
        FROM refs WHERE repo_id = p_repo_id AND name = 'HEAD';
    ELSE
        v_commit_hash := p_commit;
    END IF;
    
    RETURN QUERY
    WITH files AS (
        SELECT e->>'name' as path, b.content
        FROM commits c
        JOIN trees t ON c.repo_id = p_repo_id AND t.repo_id = p_repo_id AND c.tree_hash = t.hash,
        jsonb_array_elements(t.entries) e
        JOIN blobs b ON b.repo_id = p_repo_id AND e->>'hash' = b.hash
        WHERE c.repo_id = p_repo_id AND c.hash = v_commit_hash
    )
    SELECT f.path,
           s.line_number,
           s.lines[s.line_number]
    FROM files f,
    LATERAL (
        SELECT generate_subscripts(regexp_split_to_array(encode(f.content, 'escape'), E'\n'), 1) as line_number,
               regexp_split_to_array(encode(f.content, 'escape'), E'\n') as lines
    ) s
    WHERE CASE 
        WHEN p_ignore_case THEN 
            s.lines[s.line_number] ~* p_pattern
        ELSE 
            s.lines[s.line_number] ~ p_pattern
        END;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-instaweb.sql =====
-- Path: /sql/functions/028-instaweb.sql
-- Instaweb functionality for repository browsing

CREATE TABLE pggit.instaweb_config (
    repo_id INTEGER REFERENCES repositories(id),
    port INTEGER NOT NULL DEFAULT 1234,
    host TEXT NOT NULL DEFAULT 'localhost',
    theme TEXT NOT NULL DEFAULT 'default',
    auth_required BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id)
);

CREATE TABLE pggit.instaweb_users (
    repo_id INTEGER REFERENCES repositories(id),
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_admin BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, username)
);

CREATE TABLE pggit.instaweb_sessions (
    repo_id INTEGER REFERENCES repositories(id),
    session_id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    FOREIGN KEY (repo_id, username) REFERENCES pggit.instaweb_users(repo_id, username)
);

-- HTML Template for repository view
CREATE OR REPLACE FUNCTION pggit.get_instaweb_template(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
BEGIN
    RETURN '
<!DOCTYPE html>
<html>
<head>
    <title>{{repo_name}} - pg_git web</title>
    <style>
        body { font-family: sans-serif; margin: 0; padding: 20px; }
        .header { background: #f0f0f0; padding: 10px; }
        .commit-list { list-style: none; padding: 0; }
        .commit { border-bottom: 1px solid #eee; padding: 10px 0; }
        .file-tree { margin: 20px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>{{repo_name}}</h1>
        <div class="nav">
            <a href="/tree">Files</a> |
            <a href="/commits">History</a> |
            <a href="/branches">Branches</a>
        </div>
    </div>
    <div class="content">
        {{content}}
    </div>
</body>
</html>';
END;
$$ LANGUAGE plpgsql;

-- Generate repository view
CREATE OR REPLACE FUNCTION pggit.generate_repo_view(
    p_repo_id INTEGER,
    p_ref TEXT DEFAULT 'HEAD'
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_template TEXT;
    v_content TEXT;
    v_repo_name TEXT;
BEGIN
    SELECT name INTO v_repo_name
    FROM repositories
    WHERE id = p_repo_id;

    -- Get history
    WITH commit_list AS (
        SELECT c.hash, 
               c.message,
               c.author,
               c.timestamp
        FROM pggit.get_log(p_repo_id, 10) c
    )
    SELECT string_agg(
        format(
            '<div class="commit">
                <div class="commit-hash">%s</div>
                <div class="commit-message">%s</div>
                <div class="commit-author">%s</div>
                <div class="commit-date">%s</div>
            </div>',
            substr(hash, 1, 8),
            message,
            author,
            timestamp
        ),
        E'\n'
    ) INTO v_content
    FROM commit_list;

    -- Get template and replace placeholders
    v_template := pggit.get_instaweb_template(p_repo_id);
    v_template := replace(v_template, '{{repo_name}}', v_repo_name);
    v_template := replace(v_template, '{{content}}', v_content);

    RETURN v_template;
END;
$$ LANGUAGE plpgsql;

-- Start instaweb server
CREATE OR REPLACE FUNCTION pggit.start_instaweb(
    p_repo_id INTEGER,
    p_port INTEGER DEFAULT 1234,
    p_host TEXT DEFAULT 'localhost',
    p_auth_required BOOLEAN DEFAULT FALSE
) RETURNS TEXT SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.instaweb_config (
        repo_id, port, host, auth_required
    ) VALUES (
        p_repo_id, p_port, p_host, p_auth_required
    )
    ON CONFLICT (repo_id) DO UPDATE
    SET port = p_port,
        host = p_host,
        auth_required = p_auth_required;

    -- In a real implementation, this would start a web server
    -- For now, just return the URL
    RETURN format('http://%s:%s', p_host, p_port);
END;
$$ LANGUAGE plpgsql;

-- Stop instaweb server
CREATE OR REPLACE FUNCTION pggit.stop_instaweb(
    p_repo_id INTEGER
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    DELETE FROM pggit.instaweb_config
    WHERE repo_id = p_repo_id;
    
    -- Clean up sessions
    DELETE FROM pggit.instaweb_sessions
    WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-merge-tree.sql =====
-- Path: /sql/functions/022-merge-tree.sql
-- Enhanced merge tree operations

CREATE OR REPLACE FUNCTION pggit.merge_trees(
    p_base_tree TEXT,
    p_ours_tree TEXT,
    p_theirs_tree TEXT
) RETURNS TABLE (
    path TEXT,
    stage INTEGER,
    mode TEXT,
    hash TEXT,
    status TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Get all paths from all trees
    RETURN QUERY
    WITH all_paths AS (
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'base' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = p_base_tree
        
        UNION ALL
        
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'ours' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = p_ours_tree
        
        UNION ALL
        
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'theirs' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = p_theirs_tree
    ),
    -- Analyze changes
    analysis AS (
        SELECT DISTINCT path,
               bool_or(source = 'base') as in_base,
               bool_or(source = 'ours') as in_ours,
               bool_or(source = 'theirs') as in_theirs,
               max(CASE WHEN source = 'base' THEN hash END) as base_hash,
               max(CASE WHEN source = 'ours' THEN hash END) as ours_hash,
               max(CASE WHEN source = 'theirs' THEN hash END) as theirs_hash,
               max(CASE WHEN source = 'base' THEN mode END) as base_mode,
               max(CASE WHEN source = 'ours' THEN mode END) as ours_mode,
               max(CASE WHEN source = 'theirs' THEN mode END) as theirs_mode
        FROM all_paths
        GROUP BY path
    )
    SELECT path,
           CASE 
               WHEN NOT in_base AND in_ours AND in_theirs AND ours_hash != theirs_hash THEN 2  -- conflict
               WHEN in_base AND in_ours AND in_theirs AND base_hash != ours_hash AND base_hash != theirs_hash THEN 2  -- conflict
               ELSE 0  -- no conflict
           END as stage,
           COALESCE(ours_mode, theirs_mode, base_mode) as mode,
           CASE 
               WHEN ours_hash = theirs_hash THEN COALESCE(ours_hash, theirs_hash)
               WHEN base_hash = ours_hash THEN theirs_hash
               WHEN base_hash = theirs_hash THEN ours_hash
               ELSE ours_hash
           END as hash,
           CASE 
               WHEN NOT in_base AND in_ours AND in_theirs AND ours_hash != theirs_hash THEN 'both added'
               WHEN in_base AND NOT in_ours AND NOT in_theirs THEN 'both deleted'
               WHEN in_base AND in_ours AND in_theirs AND base_hash != ours_hash AND base_hash != theirs_hash THEN 'both modified'
               WHEN in_base AND NOT in_ours AND in_theirs THEN 'deleted by us'
               WHEN in_base AND in_ours AND NOT in_theirs THEN 'deleted by them'
               WHEN NOT in_base AND in_ours AND NOT in_theirs THEN 'added by us'
               WHEN NOT in_base AND NOT in_ours AND in_theirs THEN 'added by them'
               WHEN in_base AND in_ours AND in_theirs AND base_hash = ours_hash AND base_hash != theirs_hash THEN 'modified by them'
               WHEN in_base AND in_ours AND in_theirs AND base_hash != ours_hash AND base_hash = theirs_hash THEN 'modified by us'
               ELSE 'clean'
           END as status
    FROM analysis
    -- Only report paths that actually differ across base/ours/theirs.
    WHERE NOT (ours_hash IS NOT DISTINCT FROM theirs_hash
               AND ours_hash IS NOT DISTINCT FROM base_hash);
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-pack-refs.sql =====
-- Path: /sql/functions/029-pack-refs.sql
-- Pack refs for efficient repository access

CREATE TABLE pggit.packed_refs (
    repo_id INTEGER REFERENCES repositories(id),
    ref_name TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    peeled_hash TEXT,
    packed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, ref_name),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash),
    FOREIGN KEY (repo_id, peeled_hash) REFERENCES pggit.commits(repo_id, hash)
);

CREATE OR REPLACE FUNCTION pggit.pack_refs(
    p_repo_id INTEGER,
    p_all BOOLEAN DEFAULT FALSE
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Pack all refs or just frequently accessed ones
    INSERT INTO pggit.packed_refs (repo_id, ref_name, commit_hash, peeled_hash)
    SELECT r.repo_id, r.name, r.commit_hash,
           CASE 
               WHEN t.target_hash IS NOT NULL THEN t.target_hash
               ELSE NULL
           END
    FROM refs r
    LEFT JOIN pggit.tags t ON r.commit_hash = t.target_hash
    WHERE r.repo_id = p_repo_id
    AND r.name <> 'HEAD'
    AND (p_all OR r.name IN (
        SELECT name 
        FROM refs 
        WHERE repo_id = p_repo_id
        ORDER BY name DESC 
        LIMIT 100
    ))
    ON CONFLICT (repo_id, ref_name) DO UPDATE
    SET commit_hash = EXCLUDED.commit_hash,
        peeled_hash = EXCLUDED.peeled_hash,
        packed_at = CURRENT_TIMESTAMP;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.unpack_refs(
    p_repo_id INTEGER,
    p_ref_pattern TEXT DEFAULT NULL
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM pggit.packed_refs
    WHERE repo_id = p_repo_id
    AND (p_ref_pattern IS NULL OR ref_name LIKE p_ref_pattern);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_packed_refs(
    p_repo_id INTEGER
) RETURNS TABLE (
    ref_name TEXT,
    is_valid BOOLEAN,
    error_message TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    SELECT pr.ref_name,
           CASE 
               WHEN r.commit_hash != pr.commit_hash THEN FALSE
               WHEN pr.peeled_hash IS NOT NULL AND 
                    NOT EXISTS (SELECT 1 FROM commits WHERE hash = pr.peeled_hash) THEN FALSE
               ELSE TRUE
           END as is_valid,
           CASE 
               WHEN r.commit_hash != pr.commit_hash THEN 'Commit hash mismatch'
               WHEN pr.peeled_hash IS NOT NULL AND 
                    NOT EXISTS (SELECT 1 FROM commits WHERE hash = pr.peeled_hash) THEN 'Invalid peeled hash'
               ELSE 'Valid'
           END as error_message
    FROM pggit.packed_refs pr
    JOIN refs r ON r.name = pr.ref_name
    WHERE pr.repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-plumbing.sql =====
-- Path: /sql/functions/017-plumbing.sql
-- Git plumbing commands implementation

CREATE OR REPLACE FUNCTION pggit.cat_file(
    p_repo_id INTEGER,
    p_hash TEXT,
    p_type TEXT DEFAULT NULL
) RETURNS TABLE (
    object_type TEXT,
    size BIGINT,
    content TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Try blobs
    RETURN QUERY
    SELECT 'blob'::TEXT,
           octet_length(content)::BIGINT,
           encode(content, 'escape')
    FROM blobs WHERE repo_id = p_repo_id AND hash = p_hash
    AND (p_type IS NULL OR p_type = 'blob');
    
    IF FOUND THEN RETURN; END IF;
    
    -- Try trees
    RETURN QUERY
    SELECT 'tree'::TEXT,
           octet_length(entries::TEXT)::BIGINT,
           entries::TEXT
    FROM trees WHERE repo_id = p_repo_id AND hash = p_hash
    AND (p_type IS NULL OR p_type = 'tree');
    
    IF FOUND THEN RETURN; END IF;
    
    -- Try commits
    RETURN QUERY
    SELECT 'commit'::TEXT,
           octet_length(message)::BIGINT,
           message
    FROM commits WHERE repo_id = p_repo_id AND hash = p_hash
    AND (p_type IS NULL OR p_type = 'commit');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.hash_object(
    p_repo_id INTEGER,
    p_content BYTEA,
    p_type TEXT DEFAULT 'blob'
) RETURNS TEXT SET search_path = pggit, public AS $$
BEGIN
    CASE p_type
        WHEN 'blob' THEN
            RETURN pggit.create_blob(p_repo_id, p_content);
        WHEN 'tree' THEN
            RETURN pggit.create_tree(p_repo_id, p_content::TEXT::jsonb);
        ELSE
            RAISE EXCEPTION 'Unsupported object type: %', p_type;
    END CASE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.ls_tree(
    p_repo_id INTEGER,
    p_tree_hash TEXT,
    p_recursive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    mode TEXT,
    type TEXT,
    hash TEXT,
    path TEXT
) SET search_path = pggit, public AS $$
BEGIN
    IF NOT p_recursive THEN
        RETURN QUERY
        SELECT (e->>'mode')::TEXT,
               (e->>'type')::TEXT,
               (e->>'hash')::TEXT,
               (e->>'name')::TEXT
        FROM trees t,
             jsonb_array_elements(t.entries) e
        WHERE t.repo_id = p_repo_id AND t.hash = p_tree_hash;
    ELSE
        RETURN QUERY
        WITH RECURSIVE tree_entries AS (
            -- Base case: direct entries
            SELECT (e->>'mode')::TEXT as mode,
                   (e->>'type')::TEXT as type,
                   (e->>'hash')::TEXT as hash,
                   (e->>'name')::TEXT as path,
                   1 as level
            FROM trees t,
                 jsonb_array_elements(t.entries) e
            WHERE t.repo_id = p_repo_id AND t.hash = p_tree_hash
            
            
            UNION ALL
            
            -- Recursive case: subtrees
            SELECT (se->>'mode')::TEXT,
                   (se->>'type')::TEXT,
                   (se->>'hash')::TEXT,
                   te.path || '/' || (se->>'name')::TEXT,
                   te.level + 1
            FROM tree_entries te
            JOIN trees t ON t.repo_id = p_repo_id AND te.hash = t.hash,
            jsonb_array_elements(t.entries) se
            WHERE te.type = 'tree'
        )
        SELECT mode, type, hash, path
        FROM tree_entries
        ORDER BY path;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.merge_base(
    p_repo_id INTEGER,
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    -- Reuse existing merge base finding function
    SELECT pggit.find_merge_base(p_repo_id, p_commit1, p_commit2);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.rev_list(
    p_repo_id INTEGER,
    p_start_commit TEXT,
    p_exclude_commits TEXT[] DEFAULT ARRAY[]::TEXT[]
) RETURNS TABLE (
    hash TEXT,
    commit_data JSONB
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE commit_list AS (
        -- Start commit
        SELECT hash,
               jsonb_build_object(
                   'tree', tree_hash,
                   'parent', parent_hash,
                   'author', author,
                   'message', message,
                   'timestamp', timestamp
               ) as commit_data
        FROM commits
        WHERE repo_id = p_repo_id AND hash = p_start_commit
        
        UNION
        
        -- Parent commits
        SELECT c.hash,
               jsonb_build_object(
                   'tree', c.tree_hash,
                   'parent', c.parent_hash,
                   'author', c.author,
                   'message', c.message,
                   'timestamp', c.timestamp
               ) as commit_data
        FROM commit_list cl
        JOIN commits c ON c.repo_id = p_repo_id AND cl.commit_data->>'parent' = c.hash
        WHERE c.hash <> ALL(p_exclude_commits)
    )
    SELECT * FROM commit_list;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-repack.sql =====
-- Path: /sql/functions/030-repack.sql
-- Repack objects for efficient storage

CREATE TABLE pggit.pack_files (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    pack_hash TEXT NOT NULL,
    object_count INTEGER NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pggit.packed_objects (
    pack_id INTEGER REFERENCES pggit.pack_files(id),
    object_hash TEXT NOT NULL,
    "offset" INTEGER NOT NULL,
    size INTEGER NOT NULL,
    type TEXT NOT NULL,
    delta_base TEXT,
    PRIMARY KEY (pack_id, object_hash)
);

CREATE OR REPLACE FUNCTION pggit.repack(
    p_repo_id INTEGER,
    p_aggressive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    objects_packed INTEGER,
    space_saved BIGINT
) SET search_path = pggit, public AS $$
DECLARE
    v_pack_id INTEGER;
    v_old_size BIGINT;
    v_new_size BIGINT;
    v_pack_hash TEXT;
    v_object_count INTEGER;
BEGIN
    -- Calculate current storage size
    SELECT COALESCE(SUM(octet_length(content)), 0) +
           COALESCE(SUM(octet_length(entries::text)), 0)
    INTO v_old_size
    FROM (
        SELECT content, NULL::jsonb as entries FROM blobs
        UNION ALL
        SELECT NULL::bytea, entries FROM trees
    ) objects;

    -- Create new pack
    INSERT INTO pggit.pack_files (repo_id, pack_hash, object_count, size_bytes)
    SELECT p_repo_id,
           encode(sha256(convert_to(string_agg(hash, ''), 'UTF8')), 'hex'),
           count(*),
           sum(
               CASE 
                   WHEN content IS NOT NULL THEN octet_length(content)
                   ELSE octet_length(entries::text)
               END
           )
    FROM (
        SELECT hash, content, NULL::jsonb as entries 
        FROM blobs
        UNION ALL
        SELECT hash, NULL::bytea, entries 
        FROM trees
    ) objects
    RETURNING id, size_bytes, object_count 
    INTO v_pack_id, v_new_size, v_object_count;

    -- Pack objects with delta compression if aggressive
    IF p_aggressive THEN
        INSERT INTO pggit.packed_objects (
            pack_id, object_hash, "offset", size, type, delta_base
        )
        WITH object_analysis AS (
            SELECT hash,
                   CASE 
                       WHEN content IS NOT NULL THEN 'blob'
                       ELSE 'tree'
                   END as type,
                   CASE 
                       WHEN content IS NOT NULL THEN content
                       ELSE entries::text::bytea
                   END as data,
                   row_number() OVER (ORDER BY hash) as "offset"
            FROM (
                SELECT hash, content, NULL::jsonb as entries 
                FROM blobs
                UNION ALL
                SELECT hash, NULL::bytea, entries 
                FROM trees
            ) objects
        ),
        delta_candidates AS (
            SELECT a1.hash as obj_hash,
                   a1.type,
                   a1."offset",
                   octet_length(a1.data) as size,
                   a2.hash as base_hash
            FROM object_analysis a1
            LEFT JOIN object_analysis a2 ON a1.type = a2.type
            AND similarity(a1.data, a2.data) > 0.5
            AND a1.hash != a2.hash
            ORDER BY similarity(a1.data, a2.data) DESC
        )
        SELECT v_pack_id,
               obj_hash,
               "offset",
               size,
               type,
               base_hash
        FROM delta_candidates;
    ELSE
        INSERT INTO pggit.packed_objects (
            pack_id, object_hash, "offset", size, type
        )
        SELECT v_pack_id,
               hash,
               row_number() OVER (ORDER BY hash),
               CASE 
                   WHEN content IS NOT NULL THEN octet_length(content)
                   ELSE octet_length(entries::text)
               END,
               CASE 
                   WHEN content IS NOT NULL THEN 'blob'
                   ELSE 'tree'
               END
        FROM (
            SELECT hash, content, NULL::jsonb as entries 
            FROM blobs
            UNION ALL
            SELECT hash, NULL::bytea, entries 
            FROM trees
        ) objects;
    END IF;

    RETURN QUERY
    SELECT v_object_count as objects_packed,
           (v_old_size - v_new_size) as space_saved;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.unpack(
    p_repo_id INTEGER,
    p_pack_id INTEGER DEFAULT NULL
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM pggit.packed_objects po
    USING pggit.pack_files pf
    WHERE po.pack_id = pf.id
    AND pf.repo_id = p_repo_id
    AND (p_pack_id IS NULL OR pf.id = p_pack_id);
    
    DELETE FROM pggit.pack_files
    WHERE repo_id = p_repo_id
    AND (p_pack_id IS NULL OR id = p_pack_id);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-replace.sql =====
-- Path: /sql/functions/031-replace.sql
-- Replace object references

CREATE TABLE pggit.replacements (
    repo_id INTEGER REFERENCES repositories(id),
    original_hash TEXT NOT NULL,
    replacement_hash TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('commit', 'tree', 'blob')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, original_hash)
);

CREATE OR REPLACE FUNCTION pggit.replace(
    p_repo_id INTEGER,
    p_original TEXT,
    p_replacement TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_type TEXT;
BEGIN
    -- Determine object type
    IF EXISTS (SELECT 1 FROM commits WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'commit';
    ELSIF EXISTS (SELECT 1 FROM trees WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'tree';
    ELSIF EXISTS (SELECT 1 FROM blobs WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'blob';
    ELSE
        RAISE EXCEPTION 'Original object not found';
    END IF;

    -- Verify replacement exists and is the same object type
    IF NOT EXISTS (
        SELECT 1 FROM commits WHERE v_type = 'commit' AND repo_id = p_repo_id AND hash = p_replacement
        UNION ALL
        SELECT 1 FROM trees   WHERE v_type = 'tree'   AND repo_id = p_repo_id AND hash = p_replacement
        UNION ALL
        SELECT 1 FROM blobs   WHERE v_type = 'blob'   AND repo_id = p_repo_id AND hash = p_replacement
    ) THEN
        RAISE EXCEPTION 'Replacement object not found or wrong type';
    END IF;

    INSERT INTO pggit.replacements (repo_id, original_hash, replacement_hash, type)
    VALUES (p_repo_id, p_original, p_replacement, v_type)
    ON CONFLICT (repo_id, original_hash) 
    DO UPDATE SET replacement_hash = p_replacement;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.get_replaced_hash(
    p_repo_id INTEGER,
    p_hash TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    SELECT COALESCE(replacement_hash, p_hash)
    FROM pggit.replacements
    WHERE repo_id = p_repo_id
    AND original_hash = p_hash;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.remove_replace(
    p_repo_id INTEGER,
    p_original TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
    WITH deleted AS (
        DELETE FROM pggit.replacements
        WHERE repo_id = p_repo_id
        AND original_hash = p_original
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM deleted);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.list_replace(
    p_repo_id INTEGER
) RETURNS TABLE (
    original_hash TEXT,
    replacement_hash TEXT,
    type TEXT,
    created_at TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
    SELECT original_hash, replacement_hash, type, created_at
    FROM pggit.replacements
    WHERE repo_id = p_repo_id
    ORDER BY created_at DESC;
$$ LANGUAGE sql;

-- ===== sql/pgit-rerere.sql =====
-- Path: /sql/functions/023-rerere.sql
-- Reuse recorded resolution

CREATE TABLE pggit.rerere_cache (
    repo_id INTEGER REFERENCES repositories(id),
    conflict_hash TEXT NOT NULL,
    path TEXT NOT NULL,
    resolution_blob_hash TEXT,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    used_count INTEGER DEFAULT 0,
    last_used TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (repo_id, conflict_hash, path),
    FOREIGN KEY (repo_id, resolution_blob_hash) REFERENCES pggit.blobs(repo_id, hash)
);

CREATE OR REPLACE FUNCTION pggit.hash_conflict(
    p_our_blob TEXT,
    p_their_blob TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    SELECT encode(sha256(
        COALESCE(o.content, ''::BYTEA) || 
        COALESCE(t.content, ''::BYTEA)
    ), 'hex')
    FROM blobs o
    FULL OUTER JOIN blobs t ON TRUE
    WHERE o.hash = p_our_blob
    AND t.hash = p_their_blob;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.record_resolution(
    p_repo_id INTEGER,
    p_path TEXT,
    p_our_blob TEXT,
    p_their_blob TEXT,
    p_resolution_blob TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_conflict_hash TEXT;
BEGIN
    v_conflict_hash := pggit.hash_conflict(p_our_blob, p_their_blob);
    
    INSERT INTO pggit.rerere_cache (
        repo_id, conflict_hash, path, resolution_blob_hash
    ) VALUES (
        p_repo_id, v_conflict_hash, p_path, p_resolution_blob
    )
    ON CONFLICT (repo_id, conflict_hash, path) 
    DO UPDATE SET 
        resolution_blob_hash = p_resolution_blob,
        recorded_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.find_resolution(
    p_repo_id INTEGER,
    p_path TEXT,
    p_our_blob TEXT,
    p_their_blob TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_conflict_hash TEXT;
    v_resolution_hash TEXT;
BEGIN
    v_conflict_hash := pggit.hash_conflict(p_our_blob, p_their_blob);
    
    UPDATE pggit.rerere_cache
    SET used_count = used_count + 1,
        last_used = CURRENT_TIMESTAMP
    WHERE repo_id = p_repo_id
    AND conflict_hash = v_conflict_hash
    AND path = p_path
    RETURNING resolution_blob_hash INTO v_resolution_hash;
    
    RETURN v_resolution_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.clear_rerere_cache(
    p_repo_id INTEGER,
    p_older_than INTERVAL DEFAULT NULL
) RETURNS INTEGER SET search_path = pggit, public AS $$
    DELETE FROM pggit.rerere_cache
    WHERE repo_id = p_repo_id
    AND (
        p_older_than IS NULL OR
        recorded_at < (CURRENT_TIMESTAMP - p_older_than)
    )
    RETURNING 1;
$$ LANGUAGE sql;

-- ===== sql/pgit-sparse.sql =====
-- Path: /sql/functions/021-sparse-checkout.sql
-- Sparse checkout functionality

CREATE TABLE pggit.sparse_patterns (
    repo_id INTEGER REFERENCES repositories(id),
    pattern TEXT NOT NULL,
    is_negative BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, pattern)
);

CREATE OR REPLACE FUNCTION pggit.sparse_checkout_set(
    p_repo_id INTEGER,
    p_patterns TEXT[]
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    -- Clear existing patterns
    DELETE FROM pggit.sparse_patterns
    WHERE repo_id = p_repo_id;
    
    -- Add new patterns
    INSERT INTO pggit.sparse_patterns (repo_id, pattern, is_negative)
    SELECT p_repo_id,
           pattern,
           pattern LIKE '!%'
    FROM unnest(p_patterns) pattern;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.sparse_checkout_add(
    p_repo_id INTEGER,
    p_patterns TEXT[]
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.sparse_patterns (repo_id, pattern, is_negative)
    SELECT p_repo_id,
           pattern,
           pattern LIKE '!%'
    FROM unnest(p_patterns) pattern
    ON CONFLICT (repo_id, pattern) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.is_path_in_sparse_checkout(
    p_repo_id INTEGER,
    p_path TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    WITH matched_patterns AS (
        SELECT pattern, is_negative,
               p_path LIKE replace(
                   replace(pattern, '!', ''),
                   '*', '%'
               ) as matches
        FROM pggit.sparse_patterns
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
CREATE OR REPLACE FUNCTION pggit.get_tree_files(
    p_repo_id INTEGER,
    p_tree_hash TEXT
) RETURNS TABLE (
    path TEXT,
    blob_hash TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE tree_files AS (
        SELECT e->>'name' as path,
               e->>'hash' as hash,
               e->>'type' as type
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE repo_id = p_repo_id AND hash = p_tree_hash

        UNION ALL

        -- Parenthesize (e->>'name'): the || operator binds tighter than ->>,
        -- so without parens this parses as (tf.path || '/' || e) ->> 'name'
        -- and fails to type-check.
        SELECT tf.path || '/' || (e->>'name'),
               e->>'hash',
               e->>'type'
        FROM tree_files tf
        JOIN trees t ON t.repo_id = p_repo_id AND tf.hash = t.hash,
        jsonb_array_elements(t.entries) e
        WHERE tf.type = 'tree'
    )
    SELECT tf.path, tf.hash
    FROM tree_files tf
    WHERE tf.type = 'blob'
    AND pggit.is_path_in_sparse_checkout(p_repo_id, tf.path);
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-submodule.sql =====
-- Path: /sql/functions/020-submodule.sql
-- Submodule support

CREATE TABLE pggit.submodules (
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    url TEXT NOT NULL,
    branch TEXT DEFAULT 'main',
    commit_hash TEXT,
    PRIMARY KEY (repo_id, path)
);

CREATE OR REPLACE FUNCTION pggit.submodule_add(
    p_repo_id INTEGER,
    p_repository_url TEXT,
    p_path TEXT,
    p_name TEXT DEFAULT NULL
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_name TEXT;
    v_commit_hash TEXT;
BEGIN
    -- Generate name if not provided
    v_name := COALESCE(p_name, regexp_replace(p_path, '.*/', ''));
    
    -- Clone submodule
    v_commit_hash := pggit.clone(p_repository_url, v_name, p_path);
    
    -- Register submodule
    INSERT INTO pggit.submodules (repo_id, name, path, url, commit_hash)
    VALUES (p_repo_id, v_name, p_path, p_repository_url, v_commit_hash);
    
    RETURN v_commit_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.submodule_update(
    p_repo_id INTEGER,
    p_path TEXT DEFAULT NULL,
    p_recursive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    submodule_path TEXT,
    old_commit TEXT,
    new_commit TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH updated AS (
        SELECT s.path,
               s.commit_hash as old_commit,
               pggit.pull(s.repo_id, 'origin', s.branch) as new_commit
        FROM pggit.submodules s
        WHERE s.repo_id = p_repo_id
        AND (p_path IS NULL OR s.path = p_path)
    )
    UPDATE pggit.submodules s
    SET commit_hash = u.new_commit
    FROM updated u
    WHERE s.repo_id = p_repo_id AND s.path = u.path
    RETURNING s.path, u.old_commit, u.new_commit;
    
    -- Handle recursive update
    IF p_recursive THEN
        RETURN QUERY
        SELECT * FROM pggit.submodule_update_recursive(p_repo_id, p_path);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.submodule_update_recursive(
    p_repo_id INTEGER,
    p_path TEXT DEFAULT NULL
) RETURNS TABLE (
    submodule_path TEXT,
    old_commit TEXT,
    new_commit TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_submodule RECORD;
BEGIN
    FOR v_submodule IN
        SELECT s.* 
        FROM pggit.submodules s
        WHERE s.repo_id = p_repo_id
        AND (p_path IS NULL OR s.path = p_path)
    LOOP
        RETURN QUERY
        SELECT * FROM pggit.submodule_update(v_submodule.repo_id, NULL, TRUE);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-verify-commit.sql =====
-- Path: /sql/functions/025-verify-commit.sql
-- Commit verification with GPG

CREATE TABLE pggit.gpg_keys (
    repo_id INTEGER REFERENCES repositories(id),
    key_id TEXT NOT NULL,
    public_key TEXT NOT NULL,
    user_id TEXT NOT NULL,
    trust_level TEXT CHECK (trust_level IN ('unknown', 'never', 'marginal', 'full', 'ultimate')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, key_id)
);

CREATE TABLE pggit.commit_signatures (
    repo_id INTEGER REFERENCES repositories(id),
    commit_hash TEXT NOT NULL,
    key_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    signed_data TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, commit_hash),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash)
);

CREATE OR REPLACE FUNCTION pggit.add_gpg_key(
    p_repo_id INTEGER,
    p_key_id TEXT,
    p_public_key TEXT,
    p_user_id TEXT,
    p_trust_level TEXT DEFAULT 'unknown'
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.gpg_keys (repo_id, key_id, public_key, user_id, trust_level)
    VALUES (p_repo_id, p_key_id, p_public_key, p_user_id, p_trust_level)
    ON CONFLICT (repo_id, key_id) DO UPDATE 
    SET public_key = p_public_key,
        user_id = p_user_id,
        trust_level = p_trust_level;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_commit(
    p_repo_id INTEGER,
    p_commit_hash TEXT,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    is_valid BOOLEAN,
    key_id TEXT,
    user_id TEXT,
    trust_level TEXT,
    verification_message TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_signature RECORD;
    v_key RECORD;
BEGIN
    -- Get signature info
    SELECT * INTO v_signature
    FROM pggit.commit_signatures
    WHERE repo_id = p_repo_id
    AND commit_hash = p_commit_hash;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, NULL::TEXT, NULL::TEXT, NULL::TEXT, 'No signature found'::TEXT;
        RETURN;
    END IF;

    -- Get key info
    SELECT * INTO v_key
    FROM pggit.gpg_keys
    WHERE repo_id = p_repo_id
    AND key_id = v_signature.key_id;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, v_signature.key_id, NULL::TEXT, NULL::TEXT, 'Unknown key'::TEXT;
        RETURN;
    END IF;

    -- Check trust level if required
    IF p_require_trust_level IS NOT NULL AND 
       v_key.trust_level NOT IN ('full', 'ultimate') THEN
        RETURN QUERY
        SELECT FALSE, v_key.key_id, v_key.user_id, v_key.trust_level,
               'Insufficient trust level'::TEXT;
        RETURN;
    END IF;

    -- Here you would implement actual GPG verification
    -- For now, we'll assume any stored signature is valid
    RETURN QUERY
    SELECT TRUE, v_key.key_id, v_key.user_id, v_key.trust_level,
           'Valid signature'::TEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.sign_commit(
    p_repo_id INTEGER,
    p_commit_hash TEXT,
    p_key_id TEXT,
    p_signature TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_signed_data TEXT;
BEGIN
    -- Construct signed data from commit
    SELECT tree_hash || parent_hash || author || message INTO v_signed_data
    FROM commits
    WHERE hash = p_commit_hash;

    INSERT INTO pggit.commit_signatures (
        repo_id, commit_hash, key_id, signature, signed_data
    ) VALUES (
        p_repo_id, p_commit_hash, p_key_id, p_signature, v_signed_data
    );
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-verify-tag.sql =====
-- Path: /sql/functions/026-verify-tag.sql
-- Tag verification with GPG

CREATE TABLE pggit.tag_signatures (
    repo_id INTEGER REFERENCES repositories(id),
    tag_name TEXT NOT NULL,
    key_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    signed_data TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, tag_name),
    FOREIGN KEY (repo_id, key_id) REFERENCES pggit.gpg_keys(repo_id, key_id)
);

CREATE OR REPLACE FUNCTION pggit.sign_tag(
    p_repo_id INTEGER,
    p_tag_name TEXT,
    p_key_id TEXT,
    p_signature TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_signed_data TEXT;
BEGIN
    -- Construct signed data from tag
    SELECT target_hash || tagger || message INTO v_signed_data
    FROM pggit.tags
    WHERE repo_id = p_repo_id AND name = p_tag_name;

    INSERT INTO pggit.tag_signatures (
        repo_id, tag_name, key_id, signature, signed_data
    ) VALUES (
        p_repo_id, p_tag_name, p_key_id, p_signature, v_signed_data
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_tag(
    p_repo_id INTEGER,
    p_tag_name TEXT,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    is_valid BOOLEAN,
    key_id TEXT,
    user_id TEXT,
    trust_level TEXT,
    verification_message TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_signature RECORD;
    v_key RECORD;
BEGIN
    -- Get signature info
    SELECT * INTO v_signature
    FROM pggit.tag_signatures
    WHERE repo_id = p_repo_id
    AND tag_name = p_tag_name;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, NULL::TEXT, NULL::TEXT, NULL::TEXT, 'No signature found'::TEXT;
        RETURN;
    END IF;

    -- Get key info
    SELECT * INTO v_key
    FROM pggit.gpg_keys
    WHERE repo_id = p_repo_id
    AND key_id = v_signature.key_id;

    -- Check trust level
    IF p_require_trust_level IS NOT NULL AND 
       v_key.trust_level NOT IN ('full', 'ultimate') THEN
        RETURN QUERY
        SELECT FALSE, v_key.key_id, v_key.user_id, v_key.trust_level,
               'Insufficient trust level'::TEXT;
        RETURN;
    END IF;

    -- Here you would implement actual GPG verification
    -- For now, we assume stored signatures are valid
    RETURN QUERY
    SELECT TRUE, v_key.key_id, v_key.user_id, v_key.trust_level,
           'Valid signature'::TEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_all_tags(
    p_repo_id INTEGER,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    tag_name TEXT,
    is_valid BOOLEAN,
    verification_message TEXT
) SET search_path = pggit, public AS $$
    SELECT t.name,
           v.is_valid,
           v.verification_message
    FROM pggit.tags t
    LEFT JOIN LATERAL pggit.verify_tag(p_repo_id, t.name, p_require_trust_level) v ON TRUE
    WHERE t.repo_id = p_repo_id
    ORDER BY t.name;
$$ LANGUAGE sql;

-- ===== sql/pgit-whatchanged.sql =====
-- Path: /sql/functions/027-whatchanged.sql
-- Whatchanged command implementation

CREATE OR REPLACE FUNCTION pggit.whatchanged(
    p_repo_id INTEGER,
    p_since TEXT DEFAULT NULL,
    p_until TEXT DEFAULT 'HEAD',
    p_paths TEXT[] DEFAULT NULL
) RETURNS TABLE (
    commit_hash TEXT,
    author TEXT,
    "timestamp" TIMESTAMP WITH TIME ZONE,
    message TEXT,
    path TEXT,
    change_type TEXT,
    old_mode TEXT,
    new_mode TEXT,
    old_hash TEXT,
    new_hash TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_since_hash TEXT;
    v_until_hash TEXT;
BEGIN
    -- Resolve commit references
    IF p_until = 'HEAD' THEN
        SELECT commit_hash INTO v_until_hash
        FROM refs WHERE name = 'HEAD';
    ELSE
        v_until_hash := p_until;
    END IF;

    -- Get commit history with changes
    RETURN QUERY
    WITH RECURSIVE commit_history AS (
        -- Start from until commit
        SELECT repo_id, hash, parent_hash, author, timestamp, message, tree_hash
        FROM commits
        WHERE repo_id = p_repo_id
          AND hash = v_until_hash

        UNION ALL

        -- Walk back through parents
        SELECT c.repo_id, c.hash, c.parent_hash, c.author, c.timestamp, c.message, c.tree_hash
        FROM commits c
        JOIN commit_history ch ON c.hash = ch.parent_hash
        WHERE c.repo_id = p_repo_id
          AND (p_since IS NULL OR c.hash != p_since)
    ),
    file_changes AS (
        SELECT
            ch.hash as commit_hash,
            ch.author,
            ch.timestamp,
            ch.message,
            dt.path,
            dt.change_type,
            dt.old_mode,
            dt.new_mode,
            dt.old_hash,
            dt.new_hash
        FROM commit_history ch
        LEFT JOIN LATERAL (
            SELECT repo_id, tree_hash
            FROM commits
            WHERE hash = ch.parent_hash
              AND repo_id = ch.repo_id
        ) parent ON TRUE
        CROSS JOIN LATERAL (
            SELECT d.path,
                   CASE
                       WHEN d.old_hash IS NULL THEN 'A'  -- Added
                       WHEN d.new_hash IS NULL THEN 'D'  -- Deleted
                       ELSE 'M'                          -- Modified
                   END as change_type,
                   t1.mode as old_mode,
                   t2.mode as new_mode,
                   d.old_hash,
                   d.new_hash
            FROM pggit.diff_trees(
                COALESCE(parent.repo_id, ch.repo_id),
                parent.tree_hash,
                ch.tree_hash
            ) d
            LEFT JOIN pggit.get_tree_entry(parent.tree_hash, d.path) t1 ON TRUE
            LEFT JOIN pggit.get_tree_entry(ch.tree_hash, d.path) t2 ON TRUE
            WHERE p_paths IS NULL OR d.path = ANY(p_paths)
        ) dt
    )
    SELECT *
    FROM file_changes
    ORDER BY timestamp DESC, commit_hash, path;
END;
$$ LANGUAGE plpgsql;

-- Helper function to get a single tree entry
CREATE OR REPLACE FUNCTION pggit.get_tree_entry(
    p_tree_hash TEXT,
    p_path TEXT
) RETURNS TABLE (
    mode TEXT,
    type TEXT,
    hash TEXT
) SET search_path = pggit, public AS $$
    SELECT (e->>'mode')::TEXT,
           (e->>'type')::TEXT,
           (e->>'hash')::TEXT
    FROM trees,
    jsonb_array_elements(entries) e
    WHERE hash = p_tree_hash
    AND e->>'name' = p_path;
$$ LANGUAGE sql;
