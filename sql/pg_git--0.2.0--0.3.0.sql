-- pg_git 0.2.0 -> 0.3.0
-- GENERATED FILE -- DO NOT EDIT.
-- Objects added in 0.3.0.
-- Regenerate with: make sql/pg_git--0.2.0--0.3.0.sql

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
        -- Start from pggit.refs (only direct refs; symbolic refs such as HEAD
        -- have a NULL commit_hash and are reached through their target branch).
        SELECT 'commit'::TEXT, commit_hash FROM pggit.refs
        WHERE repo_id = p_repo_id AND commit_hash IS NOT NULL
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
            pggit.resolve_ref(p_repo_id, 'HEAD'),
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
    -- Resolve commit (HEAD follows the symbolic ref to the current branch tip).
    v_commit_hash := COALESCE(pggit.resolve_ref(p_repo_id, p_commit), p_commit);

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
        pggit.resolve_ref(p_repo_id, 'HEAD'),
        v_author,
        v_message || ' (cherry-picked from ' || p_commit_hash || ')'
    );

    -- Advance the current branch (or detached HEAD) to the new commit.
    PERFORM pggit.advance_head(p_repo_id, v_new_commit);

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

    -- The revert applies on top of the current HEAD tree (resolving symbolic HEAD).
    SELECT c.tree_hash INTO v_head_tree
    FROM commits c
    WHERE c.repo_id = p_repo_id AND c.hash = pggit.resolve_ref(p_repo_id, 'HEAD');

    -- Reverse the parent->commit change onto HEAD.
    v_new_tree := pggit.apply_inverse_diff(
        p_repo_id, v_head_tree, v_parent_tree, v_commit_tree);

    -- Create revert commit
    v_new_commit := pggit.create_commit(
        p_repo_id,
        v_new_tree,
        pggit.resolve_ref(p_repo_id, 'HEAD'),
        current_user,
        'Revert "' || v_message || '"'
    );

    -- Advance the current branch (or detached HEAD) to the revert commit.
    PERFORM pggit.advance_head(p_repo_id, v_new_commit);

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
    -- Resolve commit (HEAD follows the symbolic ref to the current branch tip).
    v_commit_hash := COALESCE(pggit.resolve_ref(p_repo_id, p_commit), p_commit);

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
    -- Try blobs. Columns are table-qualified because the RETURNS TABLE OUT
    -- parameter "content" would otherwise shadow blobs.content.
    RETURN QUERY
    SELECT 'blob'::TEXT,
           octet_length(blobs.content)::BIGINT,
           encode(blobs.content, 'escape')
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
        -- Qualify with the CTE name: mode/type/hash/path are also RETURNS TABLE
        -- OUT parameters and would otherwise be ambiguous.
        SELECT tree_entries.mode, tree_entries.type, tree_entries.hash, tree_entries.path
        FROM tree_entries
        ORDER BY tree_entries.path;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.merge_base(
    p_repo_id INTEGER,
    p_commit1 TEXT,
    p_commit2 TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    -- Reuse existing merge base finding function. find_merge_base identifies the
    -- repository from the commit hashes themselves, so it takes only two args.
    SELECT pggit.find_merge_base(p_commit1, p_commit2);
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
        -- Start commit. commits.hash is qualified because "hash" is also a
        -- RETURNS TABLE OUT parameter and would otherwise be ambiguous.
        SELECT commits.hash,
               jsonb_build_object(
                   'tree', tree_hash,
                   'parent', parent_hash,
                   'author', author,
                   'message', message,
                   'timestamp', timestamp
               ) as commit_data
        FROM commits
        WHERE repo_id = p_repo_id AND commits.hash = p_start_commit
        
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
