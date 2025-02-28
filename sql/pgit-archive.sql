-- Path: /sql/functions/019-archive.sql
-- Archive functionality

CREATE OR REPLACE FUNCTION pg_git.create_archive(
    p_repo_id INTEGER,
    p_tree_ish TEXT DEFAULT 'HEAD',
    p_format TEXT DEFAULT 'tar'
) RETURNS BYTEA AS $$
DECLARE
    v_tree_hash TEXT;
    v_archive BYTEA;
    v_header BYTEA;
    v_footer BYTEA;
BEGIN
    -- Resolve tree-ish to tree hash
    IF p_tree_ish = 'HEAD' THEN
        SELECT tree_hash INTO v_tree_hash
        FROM commits c
        JOIN refs r ON c.hash = r.commit_hash
        WHERE r.name = 'HEAD';
    ELSE
        SELECT tree_hash INTO v_tree_hash
        FROM commits
        WHERE hash = p_tree_ish;
    END IF;

    -- Initialize archive based on format
    CASE p_format
        WHEN 'tar' THEN
            v_header := '\x00'::BYTEA; -- tar header
            v_footer := '\x00'::BYTEA; -- tar footer
        WHEN 'zip' THEN
            v_header := '\x50\x4B\x03\x04'::BYTEA; -- ZIP header
            v_footer := '\x50\x4B\x05\x06'::BYTEA; -- ZIP footer
    END CASE;

    -- Build archive content
    WITH RECURSIVE tree_files AS (
        SELECT e->>'name' as path,
               e->>'hash' as hash,
               e->>'mode' as mode
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = v_tree_hash
        
        UNION ALL
        
        SELECT tf.path || '/' || e->>'name',
               e->>'hash',
               e->>'mode'
        FROM tree_files tf
        JOIN trees t ON tf.hash = t.hash,
        jsonb_array_elements(t.entries) e
        WHERE e->>'type' = 'tree'
    )
    SELECT v_header || 
           string_agg(
               CASE p_format
                   WHEN 'tar' THEN
                       -- tar file header (simplified)
                       convert_to(rpad(path, 100, '\0'), 'UTF8') ||
                       convert_to(rpad(mode, 8, '\0'), 'UTF8') ||
                       content
                   WHEN 'zip' THEN
                       -- zip file header (simplified)
                       convert_to(path || '\n', 'UTF8') ||
                       content
               END,
               ''::BYTEA
           ) || v_footer
    INTO v_archive
    FROM tree_files tf
    JOIN blobs b ON tf.hash = b.hash;

    RETURN v_archive;
END;
$$ LANGUAGE plpgsql;