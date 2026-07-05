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
    -- Resolve target to a commit hash: a ref name (the default 'HEAD', a branch)
    -- via resolve_ref, otherwise a literal commit hash.
    v_target_hash := COALESCE(pggit.resolve_ref(p_repo_id, p_target), p_target);

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
