-- pg_git 0.3.0 -> 0.4.0
-- GENERATED FILE -- DO NOT EDIT.
-- Objects added in 0.4.0.
-- Regenerate with: make sql/pg_git--0.3.0--0.4.0.sql

-- ===== sql/pgit-archive.sql =====
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
    -- Resolve tree-ish to a tree hash. A ref name (the default 'HEAD', a branch)
    -- resolves through resolve_ref; otherwise treat it as a literal commit hash.
    SELECT tree_hash INTO v_tree_hash
    FROM commits
    WHERE repo_id = p_repo_id
      AND hash = COALESCE(pggit.resolve_ref(p_repo_id, p_tree_ish), p_tree_ish);

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

-- ===== sql/pgit-bundle.sql =====
-- Path: /sql/functions/032-bundle.sql
-- Bundle repository data for offline transfer

CREATE TABLE pggit.bundles (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    description TEXT,
    prerequisites TEXT[] DEFAULT ARRAY[]::TEXT[],
    "references" TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.create_bundle(
    p_repo_id INTEGER,
    p_name TEXT,
    p_refs TEXT[],
    p_description TEXT DEFAULT NULL
) RETURNS BYTEA SET search_path = pggit, public AS $$
DECLARE
    v_bundle_data BYTEA;
    v_bundle_id INTEGER;
BEGIN
    -- Create bundle record
    INSERT INTO pggit.bundles (repo_id, name, description, "references")
    VALUES (p_repo_id, p_name, p_description, p_refs)
    RETURNING id INTO v_bundle_id;

    -- Collect all required objects
    WITH RECURSIVE bundle_objects AS (
        -- Start with referenced commits
        SELECT hash, tree_hash, parent_hash
        FROM commits c
        WHERE hash = ANY(p_refs)
        
        UNION
        
        -- Include parent commits
        SELECT c.hash, c.tree_hash, c.parent_hash
        FROM commits c
        JOIN bundle_objects b ON c.hash = b.parent_hash
    ),
    all_objects AS (
        -- Include commit objects
        SELECT hash::TEXT as hash, 'commit'::TEXT as type
        FROM bundle_objects
        
        UNION ALL
        
        -- Include tree objects
        SELECT hash, 'tree'
        FROM trees
        WHERE hash IN (SELECT tree_hash FROM bundle_objects)
        
        UNION ALL
        
        -- Include blob objects
        SELECT hash, 'blob'
        FROM blobs
        WHERE hash IN (
            SELECT e->>'hash'
            FROM trees t,
            jsonb_array_elements(t.entries) e
            WHERE t.hash IN (SELECT tree_hash FROM bundle_objects)
        )
    )
    SELECT encode(
        string_agg(
            CASE type
                WHEN 'commit' THEN
                    (SELECT encode(message::bytea, 'hex') FROM commits WHERE hash = o.hash)
                WHEN 'tree' THEN
                    (SELECT encode(entries::text::bytea, 'hex') FROM trees WHERE hash = o.hash)
                WHEN 'blob' THEN
                    (SELECT encode(content, 'hex') FROM blobs WHERE hash = o.hash)
            END,
            E'\n'
        )::bytea,
        'hex'
    )::bytea INTO v_bundle_data
    FROM all_objects o;

    RETURN v_bundle_data;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.unbundle(
    p_repo_id INTEGER,
    p_bundle_data BYTEA
) RETURNS TABLE (
    type TEXT,
    hash TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_line RECORD;
BEGIN
    FOR v_line IN
        SELECT unnest(string_to_array(convert_from(p_bundle_data, 'UTF8'), E'\n')) as data
    LOOP
        -- Parse and store objects
        IF substring(v_line.data, 1, 6) = 'commit' THEN
            INSERT INTO commits (hash, message)
            VALUES (
                encode(sha256(decode(substring(v_line.data, 8), 'hex')), 'hex'),
                convert_from(decode(substring(v_line.data, 8), 'hex'), 'UTF8')
            )
            ON CONFLICT DO NOTHING
            RETURNING 'commit', hash;
        ELSIF substring(v_line.data, 1, 4) = 'tree' THEN
            INSERT INTO trees (hash, entries)
            VALUES (
                encode(sha256(decode(substring(v_line.data, 6), 'hex')), 'hex'),
                convert_from(decode(substring(v_line.data, 6), 'hex'), 'UTF8')::jsonb
            )
            ON CONFLICT DO NOTHING
            RETURNING 'tree', hash;
        ELSIF substring(v_line.data, 1, 4) = 'blob' THEN
            INSERT INTO blobs (hash, content)
            VALUES (
                encode(sha256(decode(substring(v_line.data, 6), 'hex')), 'hex'),
                decode(substring(v_line.data, 6), 'hex')
            )
            ON CONFLICT DO NOTHING
            RETURNING 'blob', hash;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-diagnose.sql =====
-- Path: /sql/functions/024-diagnose.sql
-- Diagnostic information collection

CREATE TABLE pggit.diagnostic_reports (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    report_type TEXT NOT NULL,
    report_data JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.collect_diagnostics(
    p_repo_id INTEGER
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_report_id INTEGER;
    v_report_data JSONB;
BEGIN
    -- Collect repository info. Object counts are scoped to this repository so
    -- the report reflects the requested repo rather than the whole install.
    WITH repo_info AS (
        SELECT r.*,
               (SELECT COUNT(*) FROM commits c WHERE c.repo_id = p_repo_id) as commit_count,
               (SELECT COUNT(*) FROM blobs b WHERE b.repo_id = p_repo_id) as blob_count,
               (SELECT COUNT(*) FROM trees t WHERE t.repo_id = p_repo_id) as tree_count,
               (SELECT COUNT(*) FROM refs rf WHERE rf.repo_id = p_repo_id) as ref_count
        FROM repositories r
        WHERE id = p_repo_id
    ),
    -- Collect size info (scoped to this repository).
    size_info AS (
        SELECT 'blobs' as type, pg_size_pretty(sum(octet_length(content))) as total_size
        FROM blobs
        WHERE repo_id = p_repo_id
        UNION ALL
        SELECT 'trees', pg_size_pretty(sum(octet_length(entries::text)))
        FROM trees
        WHERE repo_id = p_repo_id
    ),
    -- Collect performance metrics
    perf_metrics AS (
        SELECT obj_description(oid) as last_gc_run
        FROM pg_class
        WHERE relname = 'blobs'
    ),
    -- Collect error info
    error_info AS (
        SELECT status, count(*) as count
        FROM pggit.verify_integrity(p_repo_id)
        GROUP BY status
    )
    -- Each section is built with a scalar subquery so the aggregated sections
    -- (sizes, errors) do not have to share a GROUP BY with the single-row
    -- repository/performance sections.
    SELECT jsonb_build_object(
        'repository', (SELECT row_to_json(repo_info) FROM repo_info),
        'sizes',      (SELECT jsonb_agg(to_jsonb(size_info)) FROM size_info),
        'performance',(SELECT to_jsonb(perf_metrics) FROM perf_metrics),
        'errors',     (SELECT jsonb_agg(to_jsonb(error_info)) FROM error_info)
    )
    INTO v_report_data;

    -- Store report
    INSERT INTO pggit.diagnostic_reports (repo_id, report_type, report_data)
    VALUES (p_repo_id, 'full', v_report_data)
    RETURNING id INTO v_report_id;

    RETURN v_report_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.get_diagnostic_report(
    p_report_id INTEGER
) RETURNS TABLE (
    section TEXT,
    content TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH report AS (
        SELECT report_data
        FROM pggit.diagnostic_reports
        WHERE id = p_report_id
    )
    SELECT 'Repository Info' as section,
           jsonb_pretty(report_data->'repository') as content
    FROM report
    UNION ALL
    SELECT 'Storage Usage',
           jsonb_pretty(report_data->'sizes')
    FROM report
    UNION ALL
    SELECT 'Performance Metrics',
           jsonb_pretty(report_data->'performance')
    FROM report
    UNION ALL
    SELECT 'Error Summary',
           jsonb_pretty(report_data->'errors')
    FROM report;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-instaweb.sql =====
-- Path: /sql/functions/028-instaweb.sql
-- Instaweb functionality for repository browsing

CREATE TABLE pggit.instaweb_config (
    repo_id INTEGER REFERENCES repositories(id),
    port INTEGER NOT NULL DEFAULT 1234,
    host TEXT NOT NULL DEFAULT 'localhost',
    theme TEXT NOT NULL DEFAULT 'default',
    auth_required BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id)
);

CREATE TABLE pggit.instaweb_users (
    repo_id INTEGER REFERENCES repositories(id),
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_admin BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, username)
);

CREATE TABLE pggit.instaweb_sessions (
    repo_id INTEGER REFERENCES repositories(id),
    session_id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    FOREIGN KEY (repo_id, username) REFERENCES pggit.instaweb_users(repo_id, username)
);

-- HTML Template for repository view
CREATE OR REPLACE FUNCTION pggit.get_instaweb_template(
    p_repo_id INTEGER
) RETURNS TEXT SET search_path = pggit, public AS $$
BEGIN
    RETURN '
<!DOCTYPE html>
<html>
<head>
    <title>{{repo_name}} - pg_git web</title>
    <style>
        body { font-family: sans-serif; margin: 0; padding: 20px; }
        .header { background: #f0f0f0; padding: 10px; }
        .commit-list { list-style: none; padding: 0; }
        .commit { border-bottom: 1px solid #eee; padding: 10px 0; }
        .file-tree { margin: 20px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>{{repo_name}}</h1>
        <div class="nav">
            <a href="/tree">Files</a> |
            <a href="/commits">History</a> |
            <a href="/branches">Branches</a>
        </div>
    </div>
    <div class="content">
        {{content}}
    </div>
</body>
</html>';
END;
$$ LANGUAGE plpgsql;

-- Generate repository view
CREATE OR REPLACE FUNCTION pggit.generate_repo_view(
    p_repo_id INTEGER,
    p_ref TEXT DEFAULT 'HEAD'
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_template TEXT;
    v_content TEXT;
    v_repo_name TEXT;
BEGIN
    SELECT name INTO v_repo_name
    FROM repositories
    WHERE id = p_repo_id;

    -- Get history
    WITH commit_list AS (
        SELECT c.hash, 
               c.message,
               c.author,
               c.timestamp
        FROM pggit.get_log(p_repo_id, 10) c
    )
    SELECT string_agg(
        format(
            '<div class="commit">
                <div class="commit-hash">%s</div>
                <div class="commit-message">%s</div>
                <div class="commit-author">%s</div>
                <div class="commit-date">%s</div>
            </div>',
            substr(hash, 1, 8),
            message,
            author,
            timestamp
        ),
        E'\n'
    ) INTO v_content
    FROM commit_list;

    -- Get template and replace placeholders
    v_template := pggit.get_instaweb_template(p_repo_id);
    v_template := replace(v_template, '{{repo_name}}', v_repo_name);
    v_template := replace(v_template, '{{content}}', v_content);

    RETURN v_template;
END;
$$ LANGUAGE plpgsql;

-- Start instaweb server
CREATE OR REPLACE FUNCTION pggit.start_instaweb(
    p_repo_id INTEGER,
    p_port INTEGER DEFAULT 1234,
    p_host TEXT DEFAULT 'localhost',
    p_auth_required BOOLEAN DEFAULT FALSE
) RETURNS TEXT SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.instaweb_config (
        repo_id, port, host, auth_required
    ) VALUES (
        p_repo_id, p_port, p_host, p_auth_required
    )
    ON CONFLICT (repo_id) DO UPDATE
    SET port = p_port,
        host = p_host,
        auth_required = p_auth_required;

    -- In a real implementation, this would start a web server
    -- For now, just return the URL
    RETURN format('http://%s:%s', p_host, p_port);
END;
$$ LANGUAGE plpgsql;

-- Stop instaweb server
CREATE OR REPLACE FUNCTION pggit.stop_instaweb(
    p_repo_id INTEGER
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    DELETE FROM pggit.instaweb_config
    WHERE repo_id = p_repo_id;
    
    -- Clean up sessions
    DELETE FROM pggit.instaweb_sessions
    WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-merge-tree.sql =====
-- Path: /sql/functions/022-merge-tree.sql
-- Enhanced merge tree operations

CREATE OR REPLACE FUNCTION pggit.merge_trees(
    p_base_tree TEXT,
    p_ours_tree TEXT,
    p_theirs_tree TEXT
) RETURNS TABLE (
    path TEXT,
    stage INTEGER,
    mode TEXT,
    hash TEXT,
    status TEXT
) SET search_path = pggit, public AS $$
BEGIN
    -- Get all paths from all trees
    RETURN QUERY
    WITH all_paths AS (
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'base' as source
        FROM trees,
        jsonb_array_elements(entries) e
        -- trees.hash is qualified: "hash" is also a RETURNS TABLE OUT parameter.
        WHERE trees.hash = p_base_tree
        
        UNION ALL
        
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'ours' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE trees.hash = p_ours_tree
        
        UNION ALL
        
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'theirs' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE trees.hash = p_theirs_tree
    ),
    -- Analyze changes
    analysis AS (
        SELECT DISTINCT all_paths.path,
               bool_or(source = 'base') as in_base,
               bool_or(source = 'ours') as in_ours,
               bool_or(source = 'theirs') as in_theirs,
               -- all_paths.hash / all_paths.mode are qualified: "hash" and
               -- "mode" are also RETURNS TABLE OUT parameters.
               max(CASE WHEN source = 'base' THEN all_paths.hash END) as base_hash,
               max(CASE WHEN source = 'ours' THEN all_paths.hash END) as ours_hash,
               max(CASE WHEN source = 'theirs' THEN all_paths.hash END) as theirs_hash,
               max(CASE WHEN source = 'base' THEN all_paths.mode END) as base_mode,
               max(CASE WHEN source = 'ours' THEN all_paths.mode END) as ours_mode,
               max(CASE WHEN source = 'theirs' THEN all_paths.mode END) as theirs_mode
        FROM all_paths
        GROUP BY all_paths.path
    )
    -- analysis.path is qualified: "path" is also a RETURNS TABLE OUT parameter.
    SELECT analysis.path,
           CASE
               WHEN NOT in_base AND in_ours AND in_theirs AND ours_hash != theirs_hash THEN 2  -- conflict
               WHEN in_base AND in_ours AND in_theirs AND base_hash != ours_hash AND base_hash != theirs_hash THEN 2  -- conflict
               ELSE 0  -- no conflict
           END as stage,
           COALESCE(ours_mode, theirs_mode, base_mode) as mode,
           CASE 
               WHEN ours_hash = theirs_hash THEN COALESCE(ours_hash, theirs_hash)
               WHEN base_hash = ours_hash THEN theirs_hash
               WHEN base_hash = theirs_hash THEN ours_hash
               ELSE ours_hash
           END as hash,
           CASE 
               WHEN NOT in_base AND in_ours AND in_theirs AND ours_hash != theirs_hash THEN 'both added'
               WHEN in_base AND NOT in_ours AND NOT in_theirs THEN 'both deleted'
               WHEN in_base AND in_ours AND in_theirs AND base_hash != ours_hash AND base_hash != theirs_hash THEN 'both modified'
               WHEN in_base AND NOT in_ours AND in_theirs THEN 'deleted by us'
               WHEN in_base AND in_ours AND NOT in_theirs THEN 'deleted by them'
               WHEN NOT in_base AND in_ours AND NOT in_theirs THEN 'added by us'
               WHEN NOT in_base AND NOT in_ours AND in_theirs THEN 'added by them'
               WHEN in_base AND in_ours AND in_theirs AND base_hash = ours_hash AND base_hash != theirs_hash THEN 'modified by them'
               WHEN in_base AND in_ours AND in_theirs AND base_hash != ours_hash AND base_hash = theirs_hash THEN 'modified by us'
               ELSE 'clean'
           END as status
    FROM analysis
    -- Only report paths that actually differ across base/ours/theirs.
    WHERE NOT (ours_hash IS NOT DISTINCT FROM theirs_hash
               AND ours_hash IS NOT DISTINCT FROM base_hash);
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-pack-refs.sql =====
-- Path: /sql/functions/029-pack-refs.sql
-- Pack refs for efficient repository access

CREATE TABLE pggit.packed_refs (
    repo_id INTEGER REFERENCES repositories(id),
    ref_name TEXT NOT NULL,
    commit_hash TEXT NOT NULL,
    peeled_hash TEXT,
    packed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, ref_name),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash),
    FOREIGN KEY (repo_id, peeled_hash) REFERENCES pggit.commits(repo_id, hash)
);

CREATE OR REPLACE FUNCTION pggit.pack_refs(
    p_repo_id INTEGER,
    p_all BOOLEAN DEFAULT FALSE
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Pack all refs or just frequently accessed ones
    INSERT INTO pggit.packed_refs (repo_id, ref_name, commit_hash, peeled_hash)
    SELECT r.repo_id, r.name, r.commit_hash,
           CASE 
               WHEN t.target_hash IS NOT NULL THEN t.target_hash
               ELSE NULL
           END
    FROM refs r
    LEFT JOIN pggit.tags t ON r.commit_hash = t.target_hash
    WHERE r.repo_id = p_repo_id
    AND r.name <> 'HEAD'
    AND (p_all OR r.name IN (
        SELECT name 
        FROM refs 
        WHERE repo_id = p_repo_id
        ORDER BY name DESC 
        LIMIT 100
    ))
    ON CONFLICT (repo_id, ref_name) DO UPDATE
    SET commit_hash = EXCLUDED.commit_hash,
        peeled_hash = EXCLUDED.peeled_hash,
        packed_at = CURRENT_TIMESTAMP;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.unpack_refs(
    p_repo_id INTEGER,
    p_ref_pattern TEXT DEFAULT NULL
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM pggit.packed_refs
    WHERE repo_id = p_repo_id
    AND (p_ref_pattern IS NULL OR ref_name LIKE p_ref_pattern);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_packed_refs(
    p_repo_id INTEGER
) RETURNS TABLE (
    ref_name TEXT,
    is_valid BOOLEAN,
    error_message TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    SELECT pr.ref_name,
           CASE 
               WHEN r.commit_hash != pr.commit_hash THEN FALSE
               WHEN pr.peeled_hash IS NOT NULL AND 
                    NOT EXISTS (SELECT 1 FROM commits WHERE hash = pr.peeled_hash) THEN FALSE
               ELSE TRUE
           END as is_valid,
           CASE 
               WHEN r.commit_hash != pr.commit_hash THEN 'Commit hash mismatch'
               WHEN pr.peeled_hash IS NOT NULL AND 
                    NOT EXISTS (SELECT 1 FROM commits WHERE hash = pr.peeled_hash) THEN 'Invalid peeled hash'
               ELSE 'Valid'
           END as error_message
    FROM pggit.packed_refs pr
    JOIN refs r ON r.name = pr.ref_name
    WHERE pr.repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-repack.sql =====
-- Path: /sql/functions/030-repack.sql
-- Repack objects for efficient storage

CREATE TABLE pggit.pack_files (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    pack_hash TEXT NOT NULL,
    object_count INTEGER NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pggit.packed_objects (
    pack_id INTEGER REFERENCES pggit.pack_files(id),
    object_hash TEXT NOT NULL,
    "offset" INTEGER NOT NULL,
    size INTEGER NOT NULL,
    type TEXT NOT NULL,
    delta_base TEXT,
    PRIMARY KEY (pack_id, object_hash)
);

CREATE OR REPLACE FUNCTION pggit.repack(
    p_repo_id INTEGER,
    p_aggressive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    objects_packed INTEGER,
    space_saved BIGINT
) SET search_path = pggit, public AS $$
DECLARE
    v_pack_id INTEGER;
    v_old_size BIGINT;
    v_new_size BIGINT;
    v_pack_hash TEXT;
    v_object_count INTEGER;
BEGIN
    -- Calculate current storage size
    SELECT COALESCE(SUM(octet_length(content)), 0) +
           COALESCE(SUM(octet_length(entries::text)), 0)
    INTO v_old_size
    FROM (
        SELECT content, NULL::jsonb as entries FROM blobs
        UNION ALL
        SELECT NULL::bytea, entries FROM trees
    ) objects;

    -- Create new pack
    INSERT INTO pggit.pack_files (repo_id, pack_hash, object_count, size_bytes)
    SELECT p_repo_id,
           encode(sha256(convert_to(string_agg(hash, ''), 'UTF8')), 'hex'),
           count(*),
           sum(
               CASE 
                   WHEN content IS NOT NULL THEN octet_length(content)
                   ELSE octet_length(entries::text)
               END
           )
    FROM (
        SELECT hash, content, NULL::jsonb as entries 
        FROM blobs
        UNION ALL
        SELECT hash, NULL::bytea, entries 
        FROM trees
    ) objects
    RETURNING id, size_bytes, object_count 
    INTO v_pack_id, v_new_size, v_object_count;

    -- Pack objects with delta compression if aggressive
    IF p_aggressive THEN
        INSERT INTO pggit.packed_objects (
            pack_id, object_hash, "offset", size, type, delta_base
        )
        WITH object_analysis AS (
            SELECT hash,
                   CASE 
                       WHEN content IS NOT NULL THEN 'blob'
                       ELSE 'tree'
                   END as type,
                   CASE 
                       WHEN content IS NOT NULL THEN content
                       ELSE entries::text::bytea
                   END as data,
                   row_number() OVER (ORDER BY hash) as "offset"
            FROM (
                SELECT hash, content, NULL::jsonb as entries 
                FROM blobs
                UNION ALL
                SELECT hash, NULL::bytea, entries 
                FROM trees
            ) objects
        ),
        delta_candidates AS (
            SELECT a1.hash as obj_hash,
                   a1.type,
                   a1."offset",
                   octet_length(a1.data) as size,
                   a2.hash as base_hash
            FROM object_analysis a1
            LEFT JOIN object_analysis a2 ON a1.type = a2.type
            AND similarity(a1.data, a2.data) > 0.5
            AND a1.hash != a2.hash
            ORDER BY similarity(a1.data, a2.data) DESC
        )
        SELECT v_pack_id,
               obj_hash,
               "offset",
               size,
               type,
               base_hash
        FROM delta_candidates;
    ELSE
        INSERT INTO pggit.packed_objects (
            pack_id, object_hash, "offset", size, type
        )
        SELECT v_pack_id,
               hash,
               row_number() OVER (ORDER BY hash),
               CASE 
                   WHEN content IS NOT NULL THEN octet_length(content)
                   ELSE octet_length(entries::text)
               END,
               CASE 
                   WHEN content IS NOT NULL THEN 'blob'
                   ELSE 'tree'
               END
        FROM (
            SELECT hash, content, NULL::jsonb as entries 
            FROM blobs
            UNION ALL
            SELECT hash, NULL::bytea, entries 
            FROM trees
        ) objects;
    END IF;

    RETURN QUERY
    SELECT v_object_count as objects_packed,
           (v_old_size - v_new_size) as space_saved;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.unpack(
    p_repo_id INTEGER,
    p_pack_id INTEGER DEFAULT NULL
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM pggit.packed_objects po
    USING pggit.pack_files pf
    WHERE po.pack_id = pf.id
    AND pf.repo_id = p_repo_id
    AND (p_pack_id IS NULL OR pf.id = p_pack_id);
    
    DELETE FROM pggit.pack_files
    WHERE repo_id = p_repo_id
    AND (p_pack_id IS NULL OR id = p_pack_id);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-replace.sql =====
-- Path: /sql/functions/031-replace.sql
-- Replace object references

CREATE TABLE pggit.replacements (
    repo_id INTEGER REFERENCES repositories(id),
    original_hash TEXT NOT NULL,
    replacement_hash TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('commit', 'tree', 'blob')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, original_hash)
);

CREATE OR REPLACE FUNCTION pggit.replace(
    p_repo_id INTEGER,
    p_original TEXT,
    p_replacement TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_type TEXT;
BEGIN
    -- Determine object type
    IF EXISTS (SELECT 1 FROM commits WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'commit';
    ELSIF EXISTS (SELECT 1 FROM trees WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'tree';
    ELSIF EXISTS (SELECT 1 FROM blobs WHERE repo_id = p_repo_id AND hash = p_original) THEN
        v_type := 'blob';
    ELSE
        RAISE EXCEPTION 'Original object not found';
    END IF;

    -- Verify replacement exists and is the same object type
    IF NOT EXISTS (
        SELECT 1 FROM commits WHERE v_type = 'commit' AND repo_id = p_repo_id AND hash = p_replacement
        UNION ALL
        SELECT 1 FROM trees   WHERE v_type = 'tree'   AND repo_id = p_repo_id AND hash = p_replacement
        UNION ALL
        SELECT 1 FROM blobs   WHERE v_type = 'blob'   AND repo_id = p_repo_id AND hash = p_replacement
    ) THEN
        RAISE EXCEPTION 'Replacement object not found or wrong type';
    END IF;

    INSERT INTO pggit.replacements (repo_id, original_hash, replacement_hash, type)
    VALUES (p_repo_id, p_original, p_replacement, v_type)
    ON CONFLICT (repo_id, original_hash) 
    DO UPDATE SET replacement_hash = p_replacement;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.get_replaced_hash(
    p_repo_id INTEGER,
    p_hash TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    SELECT COALESCE(replacement_hash, p_hash)
    FROM pggit.replacements
    WHERE repo_id = p_repo_id
    AND original_hash = p_hash;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.remove_replace(
    p_repo_id INTEGER,
    p_original TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
    WITH deleted AS (
        DELETE FROM pggit.replacements
        WHERE repo_id = p_repo_id
        AND original_hash = p_original
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM deleted);
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.list_replace(
    p_repo_id INTEGER
) RETURNS TABLE (
    original_hash TEXT,
    replacement_hash TEXT,
    type TEXT,
    created_at TIMESTAMP WITH TIME ZONE
) SET search_path = pggit, public AS $$
    SELECT original_hash, replacement_hash, type, created_at
    FROM pggit.replacements
    WHERE repo_id = p_repo_id
    ORDER BY created_at DESC;
$$ LANGUAGE sql;

-- ===== sql/pgit-rerere.sql =====
-- Path: /sql/functions/023-rerere.sql
-- Reuse recorded resolution

CREATE TABLE pggit.rerere_cache (
    repo_id INTEGER REFERENCES repositories(id),
    conflict_hash TEXT NOT NULL,
    path TEXT NOT NULL,
    resolution_blob_hash TEXT,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    used_count INTEGER DEFAULT 0,
    last_used TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (repo_id, conflict_hash, path),
    FOREIGN KEY (repo_id, resolution_blob_hash) REFERENCES pggit.blobs(repo_id, hash)
);

CREATE OR REPLACE FUNCTION pggit.hash_conflict(
    p_our_blob TEXT,
    p_their_blob TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
    SELECT encode(sha256(
        COALESCE(o.content, ''::BYTEA) || 
        COALESCE(t.content, ''::BYTEA)
    ), 'hex')
    FROM blobs o
    FULL OUTER JOIN blobs t ON TRUE
    WHERE o.hash = p_our_blob
    AND t.hash = p_their_blob;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.record_resolution(
    p_repo_id INTEGER,
    p_path TEXT,
    p_our_blob TEXT,
    p_their_blob TEXT,
    p_resolution_blob TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_conflict_hash TEXT;
BEGIN
    v_conflict_hash := pggit.hash_conflict(p_our_blob, p_their_blob);
    
    INSERT INTO pggit.rerere_cache (
        repo_id, conflict_hash, path, resolution_blob_hash
    ) VALUES (
        p_repo_id, v_conflict_hash, p_path, p_resolution_blob
    )
    ON CONFLICT (repo_id, conflict_hash, path) 
    DO UPDATE SET 
        resolution_blob_hash = p_resolution_blob,
        recorded_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.find_resolution(
    p_repo_id INTEGER,
    p_path TEXT,
    p_our_blob TEXT,
    p_their_blob TEXT
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_conflict_hash TEXT;
    v_resolution_hash TEXT;
BEGIN
    v_conflict_hash := pggit.hash_conflict(p_our_blob, p_their_blob);
    
    UPDATE pggit.rerere_cache
    SET used_count = used_count + 1,
        last_used = CURRENT_TIMESTAMP
    WHERE repo_id = p_repo_id
    AND conflict_hash = v_conflict_hash
    AND path = p_path
    RETURNING resolution_blob_hash INTO v_resolution_hash;
    
    RETURN v_resolution_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.clear_rerere_cache(
    p_repo_id INTEGER,
    p_older_than INTERVAL DEFAULT NULL
) RETURNS INTEGER SET search_path = pggit, public AS $$
    DELETE FROM pggit.rerere_cache
    WHERE repo_id = p_repo_id
    AND (
        p_older_than IS NULL OR
        recorded_at < (CURRENT_TIMESTAMP - p_older_than)
    )
    RETURNING 1;
$$ LANGUAGE sql;

-- ===== sql/pgit-sparse.sql =====
-- Path: /sql/functions/021-sparse-checkout.sql
-- Sparse checkout functionality

CREATE TABLE pggit.sparse_patterns (
    repo_id INTEGER REFERENCES repositories(id),
    pattern TEXT NOT NULL,
    is_negative BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, pattern)
);

CREATE OR REPLACE FUNCTION pggit.sparse_checkout_set(
    p_repo_id INTEGER,
    p_patterns TEXT[]
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    -- Clear existing patterns
    DELETE FROM pggit.sparse_patterns
    WHERE repo_id = p_repo_id;
    
    -- Add new patterns
    INSERT INTO pggit.sparse_patterns (repo_id, pattern, is_negative)
    SELECT p_repo_id,
           pattern,
           pattern LIKE '!%'
    FROM unnest(p_patterns) pattern;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.sparse_checkout_add(
    p_repo_id INTEGER,
    p_patterns TEXT[]
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.sparse_patterns (repo_id, pattern, is_negative)
    SELECT p_repo_id,
           pattern,
           pattern LIKE '!%'
    FROM unnest(p_patterns) pattern
    ON CONFLICT (repo_id, pattern) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.is_path_in_sparse_checkout(
    p_repo_id INTEGER,
    p_path TEXT
) RETURNS BOOLEAN SET search_path = pggit, public AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    WITH matched_patterns AS (
        SELECT pattern, is_negative,
               p_path LIKE replace(
                   replace(pattern, '!', ''),
                   '*', '%'
               ) as matches
        FROM pggit.sparse_patterns
        WHERE repo_id = p_repo_id
        ORDER BY is_negative, length(pattern) DESC
    )
    SELECT COALESCE(
        bool_or(
            CASE 
                WHEN is_negative THEN NOT matches
                ELSE matches
            END
        ),
        TRUE  -- If no patterns, include everything
    )
    INTO v_result
    FROM matched_patterns
    WHERE matches;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- Override tree functions to respect sparse checkout
CREATE OR REPLACE FUNCTION pggit.get_tree_files(
    p_repo_id INTEGER,
    p_tree_hash TEXT
) RETURNS TABLE (
    path TEXT,
    blob_hash TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE tree_files AS (
        SELECT e->>'name' as path,
               e->>'hash' as hash,
               e->>'type' as type
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE repo_id = p_repo_id AND hash = p_tree_hash

        UNION ALL

        -- Parenthesize (e->>'name'): the || operator binds tighter than ->>,
        -- so without parens this parses as (tf.path || '/' || e) ->> 'name'
        -- and fails to type-check.
        SELECT tf.path || '/' || (e->>'name'),
               e->>'hash',
               e->>'type'
        FROM tree_files tf
        JOIN trees t ON t.repo_id = p_repo_id AND tf.hash = t.hash,
        jsonb_array_elements(t.entries) e
        WHERE tf.type = 'tree'
    )
    SELECT tf.path, tf.hash
    FROM tree_files tf
    WHERE tf.type = 'blob'
    AND pggit.is_path_in_sparse_checkout(p_repo_id, tf.path);
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-submodule.sql =====
-- Path: /sql/functions/020-submodule.sql
-- Submodule support

CREATE TABLE pggit.submodules (
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    url TEXT NOT NULL,
    branch TEXT DEFAULT 'main',
    commit_hash TEXT,
    PRIMARY KEY (repo_id, path)
);

CREATE OR REPLACE FUNCTION pggit.submodule_add(
    p_repo_id INTEGER,
    p_repository_url TEXT,
    p_path TEXT,
    p_name TEXT DEFAULT NULL
) RETURNS TEXT SET search_path = pggit, public AS $$
DECLARE
    v_name TEXT;
    v_commit_hash TEXT;
BEGIN
    -- Generate name if not provided
    v_name := COALESCE(p_name, regexp_replace(p_path, '.*/', ''));
    
    -- Clone submodule
    v_commit_hash := pggit.clone(p_repository_url, v_name, p_path);
    
    -- Register submodule
    INSERT INTO pggit.submodules (repo_id, name, path, url, commit_hash)
    VALUES (p_repo_id, v_name, p_path, p_repository_url, v_commit_hash);
    
    RETURN v_commit_hash;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.submodule_update(
    p_repo_id INTEGER,
    p_path TEXT DEFAULT NULL,
    p_recursive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    submodule_path TEXT,
    old_commit TEXT,
    new_commit TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH updated AS (
        SELECT s.path,
               s.commit_hash as old_commit,
               pggit.pull(s.repo_id, 'origin', s.branch) as new_commit
        FROM pggit.submodules s
        WHERE s.repo_id = p_repo_id
        AND (p_path IS NULL OR s.path = p_path)
    )
    UPDATE pggit.submodules s
    SET commit_hash = u.new_commit
    FROM updated u
    WHERE s.repo_id = p_repo_id AND s.path = u.path
    RETURNING s.path, u.old_commit, u.new_commit;
    
    -- Handle recursive update
    IF p_recursive THEN
        RETURN QUERY
        SELECT * FROM pggit.submodule_update_recursive(p_repo_id, p_path);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.submodule_update_recursive(
    p_repo_id INTEGER,
    p_path TEXT DEFAULT NULL
) RETURNS TABLE (
    submodule_path TEXT,
    old_commit TEXT,
    new_commit TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_submodule RECORD;
BEGIN
    FOR v_submodule IN
        SELECT s.* 
        FROM pggit.submodules s
        WHERE s.repo_id = p_repo_id
        AND (p_path IS NULL OR s.path = p_path)
    LOOP
        RETURN QUERY
        SELECT * FROM pggit.submodule_update(v_submodule.repo_id, NULL, TRUE);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-verify-commit.sql =====
-- Path: /sql/functions/025-verify-commit.sql
-- Commit verification with GPG

CREATE TABLE pggit.gpg_keys (
    repo_id INTEGER REFERENCES repositories(id),
    key_id TEXT NOT NULL,
    public_key TEXT NOT NULL,
    user_id TEXT NOT NULL,
    trust_level TEXT CHECK (trust_level IN ('unknown', 'never', 'marginal', 'full', 'ultimate')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, key_id)
);

CREATE TABLE pggit.commit_signatures (
    repo_id INTEGER REFERENCES repositories(id),
    commit_hash TEXT NOT NULL,
    key_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    signed_data TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, commit_hash),
    FOREIGN KEY (repo_id, commit_hash) REFERENCES pggit.commits(repo_id, hash)
);

CREATE OR REPLACE FUNCTION pggit.add_gpg_key(
    p_repo_id INTEGER,
    p_key_id TEXT,
    p_public_key TEXT,
    p_user_id TEXT,
    p_trust_level TEXT DEFAULT 'unknown'
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    INSERT INTO pggit.gpg_keys (repo_id, key_id, public_key, user_id, trust_level)
    VALUES (p_repo_id, p_key_id, p_public_key, p_user_id, p_trust_level)
    ON CONFLICT (repo_id, key_id) DO UPDATE 
    SET public_key = p_public_key,
        user_id = p_user_id,
        trust_level = p_trust_level;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_commit(
    p_repo_id INTEGER,
    p_commit_hash TEXT,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    is_valid BOOLEAN,
    key_id TEXT,
    user_id TEXT,
    trust_level TEXT,
    verification_message TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_signature RECORD;
    v_key RECORD;
BEGIN
    -- Get signature info
    SELECT * INTO v_signature
    FROM pggit.commit_signatures
    WHERE repo_id = p_repo_id
    AND commit_hash = p_commit_hash;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, NULL::TEXT, NULL::TEXT, NULL::TEXT, 'No signature found'::TEXT;
        RETURN;
    END IF;

    -- Get key info
    -- gpg_keys.key_id is qualified: "key_id" is also a RETURNS TABLE OUT
    -- parameter and would otherwise be an ambiguous column reference.
    SELECT * INTO v_key
    FROM pggit.gpg_keys
    WHERE repo_id = p_repo_id
    AND gpg_keys.key_id = v_signature.key_id;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, v_signature.key_id, NULL::TEXT, NULL::TEXT, 'Unknown key'::TEXT;
        RETURN;
    END IF;

    -- Check trust level if required
    IF p_require_trust_level IS NOT NULL AND 
       v_key.trust_level NOT IN ('full', 'ultimate') THEN
        RETURN QUERY
        SELECT FALSE, v_key.key_id, v_key.user_id, v_key.trust_level,
               'Insufficient trust level'::TEXT;
        RETURN;
    END IF;

    -- Here you would implement actual GPG verification
    -- For now, we'll assume any stored signature is valid
    RETURN QUERY
    SELECT TRUE, v_key.key_id, v_key.user_id, v_key.trust_level,
           'Valid signature'::TEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.sign_commit(
    p_repo_id INTEGER,
    p_commit_hash TEXT,
    p_key_id TEXT,
    p_signature TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_signed_data TEXT;
BEGIN
    -- Construct signed data from commit
    SELECT tree_hash || parent_hash || author || message INTO v_signed_data
    FROM commits
    WHERE hash = p_commit_hash;

    INSERT INTO pggit.commit_signatures (
        repo_id, commit_hash, key_id, signature, signed_data
    ) VALUES (
        p_repo_id, p_commit_hash, p_key_id, p_signature, v_signed_data
    );
END;
$$ LANGUAGE plpgsql;

-- ===== sql/pgit-verify-tag.sql =====
-- Path: /sql/functions/026-verify-tag.sql
-- Tag verification with GPG

CREATE TABLE pggit.tag_signatures (
    repo_id INTEGER REFERENCES repositories(id),
    tag_name TEXT NOT NULL,
    key_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    signed_data TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, tag_name),
    FOREIGN KEY (repo_id, key_id) REFERENCES pggit.gpg_keys(repo_id, key_id)
);

CREATE OR REPLACE FUNCTION pggit.sign_tag(
    p_repo_id INTEGER,
    p_tag_name TEXT,
    p_key_id TEXT,
    p_signature TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_signed_data TEXT;
BEGIN
    -- Construct signed data from tag
    SELECT target_hash || tagger || message INTO v_signed_data
    FROM pggit.tags
    WHERE repo_id = p_repo_id AND name = p_tag_name;

    INSERT INTO pggit.tag_signatures (
        repo_id, tag_name, key_id, signature, signed_data
    ) VALUES (
        p_repo_id, p_tag_name, p_key_id, p_signature, v_signed_data
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_tag(
    p_repo_id INTEGER,
    p_tag_name TEXT,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    is_valid BOOLEAN,
    key_id TEXT,
    user_id TEXT,
    trust_level TEXT,
    verification_message TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_signature RECORD;
    v_key RECORD;
BEGIN
    -- Get signature info
    SELECT * INTO v_signature
    FROM pggit.tag_signatures
    WHERE repo_id = p_repo_id
    AND tag_name = p_tag_name;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, NULL::TEXT, NULL::TEXT, NULL::TEXT, 'No signature found'::TEXT;
        RETURN;
    END IF;

    -- Get key info. gpg_keys.key_id is qualified: "key_id" is also a RETURNS
    -- TABLE OUT parameter and would otherwise be an ambiguous column reference.
    SELECT * INTO v_key
    FROM pggit.gpg_keys
    WHERE repo_id = p_repo_id
    AND gpg_keys.key_id = v_signature.key_id;

    -- Check trust level
    IF p_require_trust_level IS NOT NULL AND 
       v_key.trust_level NOT IN ('full', 'ultimate') THEN
        RETURN QUERY
        SELECT FALSE, v_key.key_id, v_key.user_id, v_key.trust_level,
               'Insufficient trust level'::TEXT;
        RETURN;
    END IF;

    -- Here you would implement actual GPG verification
    -- For now, we assume stored signatures are valid
    RETURN QUERY
    SELECT TRUE, v_key.key_id, v_key.user_id, v_key.trust_level,
           'Valid signature'::TEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_all_tags(
    p_repo_id INTEGER,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    tag_name TEXT,
    is_valid BOOLEAN,
    verification_message TEXT
) SET search_path = pggit, public AS $$
    SELECT t.name,
           v.is_valid,
           v.verification_message
    FROM pggit.tags t
    LEFT JOIN LATERAL pggit.verify_tag(p_repo_id, t.name, p_require_trust_level) v ON TRUE
    WHERE t.repo_id = p_repo_id
    ORDER BY t.name;
$$ LANGUAGE sql;

-- ===== sql/pgit-whatchanged.sql =====
-- Path: /sql/functions/027-whatchanged.sql
-- Whatchanged command implementation

CREATE OR REPLACE FUNCTION pggit.whatchanged(
    p_repo_id INTEGER,
    p_since TEXT DEFAULT NULL,
    p_until TEXT DEFAULT 'HEAD',
    p_paths TEXT[] DEFAULT NULL
) RETURNS TABLE (
    commit_hash TEXT,
    author TEXT,
    "timestamp" TIMESTAMP WITH TIME ZONE,
    message TEXT,
    path TEXT,
    change_type TEXT,
    old_mode TEXT,
    new_mode TEXT,
    old_hash TEXT,
    new_hash TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_since_hash TEXT;
    v_until_hash TEXT;
BEGIN
    -- Resolve commit references (HEAD follows the symbolic ref for this repo).
    IF p_until = 'HEAD' THEN
        v_until_hash := pggit.resolve_ref(p_repo_id, 'HEAD');
    ELSE
        v_until_hash := p_until;
    END IF;

    -- Get commit history with changes
    RETURN QUERY
    WITH RECURSIVE commit_history AS (
        -- Start from until commit. Columns are qualified because author,
        -- timestamp and message are also RETURNS TABLE OUT parameters.
        SELECT c.repo_id, c.hash, c.parent_hash, c.author, c.timestamp, c.message, c.tree_hash
        FROM commits c
        WHERE c.repo_id = p_repo_id
          AND c.hash = v_until_hash

        UNION ALL

        -- Walk back through parents
        SELECT c.repo_id, c.hash, c.parent_hash, c.author, c.timestamp, c.message, c.tree_hash
        FROM commits c
        JOIN commit_history ch ON c.hash = ch.parent_hash
        WHERE c.repo_id = p_repo_id
          AND (p_since IS NULL OR c.hash != p_since)
    ),
    file_changes AS (
        SELECT
            ch.hash as commit_hash,
            ch.author,
            ch.timestamp,
            ch.message,
            dt.path,
            dt.change_type,
            dt.old_mode,
            dt.new_mode,
            dt.old_hash,
            dt.new_hash
        FROM commit_history ch
        LEFT JOIN LATERAL (
            SELECT repo_id, tree_hash
            FROM commits
            WHERE hash = ch.parent_hash
              AND repo_id = ch.repo_id
        ) parent ON TRUE
        CROSS JOIN LATERAL (
            SELECT d.path,
                   CASE
                       WHEN d.old_hash IS NULL THEN 'A'  -- Added
                       WHEN d.new_hash IS NULL THEN 'D'  -- Deleted
                       ELSE 'M'                          -- Modified
                   END as change_type,
                   t1.mode as old_mode,
                   t2.mode as new_mode,
                   d.old_hash,
                   d.new_hash
            FROM pggit.diff_trees(
                COALESCE(parent.repo_id, ch.repo_id),
                parent.tree_hash,
                ch.tree_hash
            ) d
            LEFT JOIN pggit.get_tree_entry(parent.tree_hash, d.path) t1 ON TRUE
            LEFT JOIN pggit.get_tree_entry(ch.tree_hash, d.path) t2 ON TRUE
            WHERE p_paths IS NULL OR d.path = ANY(p_paths)
        ) dt
    )
    SELECT *
    FROM file_changes
    ORDER BY file_changes.timestamp DESC, file_changes.commit_hash, file_changes.path;
END;
$$ LANGUAGE plpgsql;

-- Helper function to get a single tree entry
CREATE OR REPLACE FUNCTION pggit.get_tree_entry(
    p_tree_hash TEXT,
    p_path TEXT
) RETURNS TABLE (
    mode TEXT,
    type TEXT,
    hash TEXT
) SET search_path = pggit, public AS $$
    SELECT (e->>'mode')::TEXT,
           (e->>'type')::TEXT,
           (e->>'hash')::TEXT
    FROM trees,
    jsonb_array_elements(entries) e
    WHERE hash = p_tree_hash
    AND e->>'name' = p_path;
$$ LANGUAGE sql;
