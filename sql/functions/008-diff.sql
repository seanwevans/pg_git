-- Path: /sql/functions/008-diff.sql
-- pg_git diff operations

CREATE OR REPLACE FUNCTION pg_git.diff_blobs(
    p_old_hash TEXT,
    p_new_hash TEXT
) RETURNS TABLE (
    line_type CHAR(1),
    line_content TEXT
) AS $$
DECLARE
    v_old_content TEXT;
    v_new_content TEXT;
BEGIN
    -- Get content from blobs
    SELECT encode(content, 'escape') INTO v_old_content
    FROM blobs WHERE hash = p_old_hash;
    
    SELECT encode(content, 'escape') INTO v_new_content
    FROM blobs WHERE hash = p_new_hash;
    
    RETURN QUERY
    SELECT *
    FROM pg_git.diff_text(v_old_content, v_new_content);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.diff_text(
    p_old_text TEXT,
    p_new_text TEXT
) RETURNS TABLE (
    line_type CHAR(1),
    line_content TEXT
) AS $$
BEGIN
    -- Split texts into arrays
    WITH old_lines AS (
        SELECT unnest(string_to_array(p_old_text, E'\n')) as line,
               generate_subscripts(string_to_array(p_old_text, E'\n'), 1) as line_num
    ),
    new_lines AS (
        SELECT unnest(string_to_array(p_new_text, E'\n')) as line,
               generate_subscripts(string_to_array(p_new_text, E'\n'), 1) as line_num
    )
    -- Simple line-by-line diff
    SELECT '-' as line_type, old_lines.line as line_content
    FROM old_lines
    WHERE NOT EXISTS (
        SELECT 1 FROM new_lines WHERE new_lines.line = old_lines.line
    )
    UNION ALL
    SELECT '+' as line_type, new_lines.line as line_content
    FROM new_lines
    WHERE NOT EXISTS (
        SELECT 1 FROM old_lines WHERE old_lines.line = new_lines.line
    )
    UNION ALL
    SELECT ' ' as line_type, old_lines.line as line_content
    FROM old_lines
    JOIN new_lines ON old_lines.line = new_lines.line
    ORDER BY line_content;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.diff_commits(
    p_old_commit TEXT,
    p_new_commit TEXT
) RETURNS TABLE (
    path TEXT,
    change_type TEXT,
    diff_content TEXT[]
) AS $$
DECLARE
    v_old_tree TEXT;
    v_new_tree TEXT;
BEGIN
    -- Get tree hashes
    SELECT tree_hash INTO v_old_tree
    FROM commits WHERE hash = p_old_commit;
    
    SELECT tree_hash INTO v_new_tree
    FROM commits WHERE hash = p_new_commit;
    
    RETURN QUERY
    SELECT 
        d.path,
        d.change_type,
        CASE 
            WHEN d.change_type = 'modified' THEN
                ARRAY(
                    SELECT line_type || line_content
                    FROM pg_git.diff_blobs(d.old_hash, d.new_hash)
                )
            ELSE
                ARRAY[]::TEXT[]
        END as diff_content
    FROM pg_git.diff_trees(v_old_tree, v_new_tree) d;
END;
$$ LANGUAGE plpgsql;