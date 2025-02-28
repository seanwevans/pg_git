-- Path: /sql/functions/032-bundle.sql
-- Bundle repository data for offline transfer

CREATE TABLE pg_git.bundles (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    name TEXT NOT NULL,
    description TEXT,
    prerequisites TEXT[] DEFAULT ARRAY[]::TEXT[],
    references TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pg_git.create_bundle(
    p_repo_id INTEGER,
    p_name TEXT,
    p_refs TEXT[],
    p_description TEXT DEFAULT NULL
) RETURNS BYTEA AS $$
DECLARE
    v_bundle_data BYTEA;
    v_bundle_id INTEGER;
BEGIN
    -- Create bundle record
    INSERT INTO pg_git.bundles (repo_id, name, description, references)
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

CREATE OR REPLACE FUNCTION pg_git.unbundle(
    p_repo_id INTEGER,
    p_bundle_data BYTEA
) RETURNS TABLE (
    type TEXT,
    hash TEXT
) AS $$
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