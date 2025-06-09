-- Path: /sql/functions/030-repack.sql
-- Repack objects for efficient storage

CREATE TABLE pg_git.pack_files (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    pack_hash TEXT NOT NULL,
    object_count INTEGER NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pg_git.packed_objects (
    pack_id INTEGER REFERENCES pg_git.pack_files(id),
    object_hash TEXT NOT NULL,
    offset INTEGER NOT NULL,
    size INTEGER NOT NULL,
    type TEXT NOT NULL,
    delta_base TEXT,
    PRIMARY KEY (pack_id, object_hash)
);

CREATE OR REPLACE FUNCTION pg_git.repack(
    p_repo_id INTEGER,
    p_aggressive BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    objects_packed INTEGER,
    space_saved BIGINT
) AS $$
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
    INSERT INTO pg_git.pack_files (repo_id, pack_hash, object_count, size_bytes)
    SELECT p_repo_id,
           encode(sha256(string_agg(hash, '')), 'hex'),
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
        INSERT INTO pg_git.packed_objects (
            pack_id, object_hash, offset, size, type, delta_base
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
                   row_number() OVER (ORDER BY hash) as offset
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
                   a1.offset,
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
               offset,
               size,
               type,
               base_hash
        FROM delta_candidates;
    ELSE
        INSERT INTO pg_git.packed_objects (
            pack_id, object_hash, offset, size, type
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

CREATE OR REPLACE FUNCTION pg_git.unpack(
    p_repo_id INTEGER,
    p_pack_id INTEGER DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM pg_git.packed_objects po
    USING pg_git.pack_files pf
    WHERE po.pack_id = pf.id
    AND pf.repo_id = p_repo_id
    AND (p_pack_id IS NULL OR pf.id = p_pack_id);
    
    DELETE FROM pg_git.pack_files
    WHERE repo_id = p_repo_id
    AND (p_pack_id IS NULL OR id = p_pack_id);
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;
