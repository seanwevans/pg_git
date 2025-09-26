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
    -- Split texts into arrays with line numbers using ordinality
    WITH old_lines AS (
        SELECT line, line_num
        FROM unnest(string_to_array(p_old_text, E'\n')) WITH ORDINALITY AS t(line, line_num)
    ),
    new_lines AS (
        SELECT line, line_num
        FROM unnest(string_to_array(p_new_text, E'\n')) WITH ORDINALITY AS t(line, line_num)
    )
    -- Simple line-by-line diff preserving line order
    SELECT line_type, line_content
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
    ORDER BY line_num, CASE line_type WHEN '-' THEN 1 WHEN '+' THEN 2 ELSE 3 END;
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
    v_repo_id INTEGER;
    v_old_tree TEXT;
    v_new_tree TEXT;
BEGIN
    -- Get tree hashes
    SELECT repo_id, tree_hash INTO v_repo_id, v_old_tree
    FROM commits WHERE hash = p_old_commit;

    IF v_repo_id IS NULL THEN
        SELECT repo_id INTO v_repo_id
        FROM commits WHERE hash = p_new_commit;
    END IF;

    SELECT tree_hash INTO v_new_tree
    FROM commits WHERE hash = p_new_commit AND repo_id = v_repo_id;

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
    FROM pg_git.diff_trees(v_repo_id, v_old_tree, v_new_tree) d;
END;$$ LANGUAGE plpgsql;
