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

    -- Get local ref (resolving symbolic refs such as HEAD)
    v_commit_hash := pggit.resolve_ref(p_repo_id, p_ref_name);

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
