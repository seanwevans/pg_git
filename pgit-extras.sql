-- Path: /sql/functions/018-extras.sql
-- Additional Git commands and utilities

-- Cherry-pick implementation
CREATE OR REPLACE FUNCTION pg_git.cherry_pick(
    p_repo_id INTEGER,
    p_commit_hash TEXT
) RETURNS TEXT AS $$
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
    v_new_commit := pg_git.create_commit(
        v_tree_hash,
        (SELECT commit_hash FROM refs WHERE name = 'HEAD'),
        v_author,
        v_message || ' (cherry-picked from ' || p_commit_hash || ')'
    );
    
    -- Update HEAD
    UPDATE refs 
    SET commit_hash = v_new_commit
    WHERE name = 'HEAD';
    
    RETURN v_new_commit;
END;
$$ LANGUAGE plpgsql;

-- Revert implementation
CREATE OR REPLACE FUNCTION pg_git.revert(
    p_repo_id INTEGER,
    p_commit_hash TEXT
) RETURNS TEXT AS $$
DECLARE
    v_parent_tree TEXT;
    v_commit_tree TEXT;
    v_new_tree TEXT;
    v_new_commit TEXT;
    v_message TEXT;
BEGIN
    -- Get trees and message
    SELECT tree_hash, message,
           (SELECT tree_hash FROM commits WHERE hash = c.parent_hash)
    INTO v_commit_tree, v_message, v_parent_tree
    FROM commits c 
    WHERE hash = p_commit_hash;
    
    -- Create inverse diff
    v_new_tree := pg_git.apply_inverse_diff(v_parent_tree, v_commit_tree);
    
    -- Create revert commit
    v_new_commit := pg_git.create_commit(
        v_new_tree,
        (SELECT commit_hash FROM refs WHERE name = 'HEAD'),
        current_user,
        'Revert "' || v_message || '"'
    );
    
    -- Update HEAD
    UPDATE refs 
    SET commit_hash = v_new_commit
    WHERE name = 'HEAD';
    
    RETURN v_new_commit;
END;
$$ LANGUAGE plpgsql;

-- Bisect implementation
CREATE TABLE pg_git.bisect_state (
    repo_id INTEGER REFERENCES repositories(id),
    start_commit TEXT NOT NULL,
    good_commits TEXT[] DEFAULT ARRAY[]::TEXT[],
    bad_commits TEXT[] DEFAULT ARRAY[]::TEXT[],
    current_commit TEXT,
    PRIMARY KEY (repo_id)
);

CREATE OR REPLACE FUNCTION pg_git.bisect_start(
    p_repo_id INTEGER,
    p_bad_commit TEXT,
    p_good_commit TEXT
) RETURNS TEXT AS $$
DECLARE
    v_mid_commit TEXT;
BEGIN
    -- Initialize bisect state
    INSERT INTO pg_git.bisect_state (repo_id, start_commit, good_commits, bad_commits)
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
        FROM pg_git.rev_list(p_bad_commit, ARRAY[p_good_commit])
    ) commits
    WHERE rn = total/2;
    
    -- Update current commit
    UPDATE pg_git.bisect_state
    SET current_commit = v_mid_commit
    WHERE repo_id = p_repo_id;
    
    RETURN v_mid_commit;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.bisect_good(
    p_repo_id INTEGER
) RETURNS TEXT AS $$
DECLARE
    v_current TEXT;
    v_next TEXT;
BEGIN
    -- Get current state
    SELECT current_commit INTO v_current
    FROM pg_git.bisect_state
    WHERE repo_id = p_repo_id;
    
    -- Add to good commits
    UPDATE pg_git.bisect_state
    SET good_commits = array_append(good_commits, v_current)
    WHERE repo_id = p_repo_id;
    
    -- Find next commit to test
    SELECT hash INTO v_next
    FROM (
        SELECT hash, ROW_NUMBER() OVER (ORDER BY timestamp) as rn,
               COUNT(*) OVER () as total
        FROM pg_git.rev_list(
            (SELECT bad_commits[1] FROM pg_git.bisect_state WHERE repo_id = p_repo_id),
            (SELECT good_commits FROM pg_git.bisect_state WHERE repo_id = p_repo_id)
        )
    ) commits
    WHERE rn = total/2;
    
    -- Update current commit
    UPDATE pg_git.bisect_state
    SET current_commit = v_next
    WHERE repo_id = p_repo_id;
    
    RETURN v_next;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.bisect_bad(
    p_repo_id INTEGER
) RETURNS TEXT AS $$
DECLARE
    v_current TEXT;
    v_next TEXT;
BEGIN
    -- Get current state
    SELECT current_commit INTO v_current
    FROM pg_git.bisect_state
    WHERE repo_id = p_repo_id;
    
    -- Add to bad commits
    UPDATE pg_git.bisect_state
    SET bad_commits = array_append(bad_commits, v_current)
    WHERE repo_id = p_repo_id;
    
    -- Find next commit to test
    SELECT hash INTO v_next
    FROM (
        SELECT hash, ROW_NUMBER() OVER (ORDER BY timestamp) as rn,
               COUNT(*) OVER () as total
        FROM pg_git.rev_list(
            (SELECT bad_commits[1] FROM pg_git.bisect_state WHERE repo_id = p_repo_id),
            (SELECT good_commits FROM pg_git.bisect_state WHERE repo_id = p_repo_id)
        )
    ) commits
    WHERE rn = total/2;
    
    -- Update current commit
    UPDATE pg_git.bisect_state
    SET current_commit = v_next
    WHERE repo_id = p_repo_id;
    
    RETURN v_next;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.bisect_reset(
    p_repo_id INTEGER
) RETURNS VOID AS $$
BEGIN
    DELETE FROM pg_git.bisect_state
    WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- Grep implementation
CREATE OR REPLACE FUNCTION pg_git.grep(
    p_repo_id INTEGER,
    p_pattern TEXT,
    p_commit TEXT DEFAULT 'HEAD',
    p_ignore_case BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    file_path TEXT,
    line_number INTEGER,
    line_content TEXT
) AS $$
DECLARE
    v_commit_hash TEXT;
BEGIN
    -- Resolve commit
    IF p_commit = 'HEAD' THEN
        SELECT commit_hash INTO v_commit_hash
        FROM refs WHERE name = 'HEAD';
    ELSE
        v_commit_hash := p_commit;
    END IF;
    
    RETURN QUERY
    WITH files AS (
        SELECT e->>'name' as path, b.content
        FROM commits c
        JOIN trees t ON c.tree_hash = t.hash,
        jsonb_array_elements(t.entries) e
        JOIN blobs b ON e->>'hash' = b.hash
        WHERE c.hash = v_commit_hash
    )
    SELECT f.path,
           s.line_number,
           s.line_content
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