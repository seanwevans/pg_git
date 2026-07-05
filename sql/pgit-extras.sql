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

-- Produce a new tree by taking p_onto_tree and reversing the change that turned
-- p_old_tree into p_new_tree (the old->new delta). This is the tree-level core of
-- a revert: for each path the delta touched, a file it added is removed, and a
-- file it modified or deleted is restored to its p_old_tree contents. Paths the
-- delta did not touch are carried over from p_onto_tree unchanged.
CREATE OR REPLACE FUNCTION pggit.apply_inverse_diff(
    p_repo_id INTEGER,
    p_onto_tree TEXT,
    p_old_tree TEXT,
    p_new_tree TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_result JSONB;
BEGIN
    WITH onto_entries AS (
        SELECT e->>'name' AS name, e AS entry
        FROM pggit.trees t, jsonb_array_elements(t.entries) e
        WHERE t.repo_id = p_repo_id AND t.hash = p_onto_tree
    ),
    old_entries AS (
        SELECT e->>'name' AS name, e AS entry
        FROM pggit.trees t, jsonb_array_elements(t.entries) e
        WHERE t.repo_id = p_repo_id AND t.hash = p_old_tree
    ),
    delta AS (
        SELECT d.change_type, d.path
        FROM pggit.diff_trees(p_repo_id, p_old_tree, p_new_tree) d
    ),
    merged AS (
        -- Carry over onto entries, but drop paths the delta added (reverting an
        -- addition removes the file) and restore old contents for modified paths.
        SELECT o.name,
               CASE WHEN dl.change_type = 'modified'
                        THEN (SELECT oe.entry FROM old_entries oe WHERE oe.name = o.name)
                    ELSE o.entry
               END AS entry
        FROM onto_entries o
        LEFT JOIN delta dl ON dl.path = o.name
        WHERE dl.change_type IS DISTINCT FROM 'added'

        UNION ALL

        -- Restore files the delta deleted (present in old, absent in new) that
        -- are not already present in the onto tree.
        SELECT oe.name, oe.entry
        FROM delta dl
        JOIN old_entries oe ON oe.name = dl.path
        WHERE dl.change_type = 'deleted'
          AND NOT EXISTS (SELECT 1 FROM onto_entries o2 WHERE o2.name = dl.path)
    )
    SELECT jsonb_agg(entry ORDER BY name) INTO v_result FROM merged;

    RETURN pggit.create_tree(p_repo_id, COALESCE(v_result, '[]'::jsonb));
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
    v_head_tree TEXT;
    v_new_tree TEXT;
    v_new_commit TEXT;
    v_message TEXT;
BEGIN
    -- Get the reverted commit's tree, its parent's tree, and its message.
    SELECT tree_hash, message,
           (SELECT tree_hash FROM commits WHERE repo_id = p_repo_id AND hash = c.parent_hash)
    INTO v_commit_tree, v_message, v_parent_tree
    FROM commits c
    WHERE c.repo_id = p_repo_id AND hash = p_commit_hash;

    -- The revert applies on top of the current HEAD tree.
    SELECT c.tree_hash INTO v_head_tree
    FROM refs r
    JOIN commits c ON c.repo_id = r.repo_id AND c.hash = r.commit_hash
    WHERE r.repo_id = p_repo_id AND r.name = 'HEAD';

    -- Reverse the parent->commit change onto HEAD.
    v_new_tree := pggit.apply_inverse_diff(
        p_repo_id, v_head_tree, v_parent_tree, v_commit_tree);

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
        SELECT hash, ROW_NUMBER() OVER (ORDER BY (commit_data->>'timestamp')::timestamptz) as rn,
               COUNT(*) OVER () as total
        FROM pggit.rev_list(p_repo_id, p_bad_commit, ARRAY[p_good_commit])
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
        SELECT hash, ROW_NUMBER() OVER (ORDER BY (commit_data->>'timestamp')::timestamptz) as rn,
               COUNT(*) OVER () as total
        FROM pggit.rev_list(
            p_repo_id,
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
        SELECT hash, ROW_NUMBER() OVER (ORDER BY (commit_data->>'timestamp')::timestamptz) as rn,
               COUNT(*) OVER () as total
        FROM pggit.rev_list(
            p_repo_id,
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
