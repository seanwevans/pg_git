-- Path: /sql/functions/010-tag.sql
-- pg_git tag operations

CREATE TABLE pg_git.tags (
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    target_hash TEXT NOT NULL,
    tagger TEXT NOT NULL,
    message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, name)
);

CREATE OR REPLACE FUNCTION pg_git.create_tag(
    p_repo_id INTEGER,
    p_name TEXT,
    p_target TEXT DEFAULT 'HEAD',
    p_tagger TEXT DEFAULT current_user,
    p_message TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_target_hash TEXT;
BEGIN
    -- Resolve target to commit hash
    IF p_target = 'HEAD' THEN
        SELECT commit_hash INTO v_target_hash
        FROM refs WHERE repo_id = p_repo_id AND name = 'HEAD';
    ELSE
        v_target_hash := p_target;
    END IF;

    INSERT INTO pg_git.tags (repo_id, name, target_hash, tagger, message)
    VALUES (p_repo_id, p_name, v_target_hash, p_tagger, p_message);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.list_tags(
    p_repo_id INTEGER
) RETURNS TABLE (
    name TEXT,
    target_hash TEXT,
    tagger TEXT,
    message TEXT,
    created_at TIMESTAMP WITH TIME ZONE
) AS $$
    SELECT name, target_hash, tagger, message, created_at
    FROM pg_git.tags
    WHERE repo_id = p_repo_id
    ORDER BY created_at DESC;$$ LANGUAGE sql;
