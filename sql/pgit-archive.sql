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
