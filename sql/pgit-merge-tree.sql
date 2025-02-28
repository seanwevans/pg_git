-- Path: /sql/functions/022-merge-tree.sql
-- Enhanced merge tree operations

CREATE OR REPLACE FUNCTION pg_git.merge_trees(
    p_base_tree TEXT,
    p_ours_tree TEXT,
    p_theirs_tree TEXT
) RETURNS TABLE (
    path TEXT,
    stage INTEGER,
    mode TEXT,
    hash TEXT,
    status TEXT
) AS $$
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
        WHERE hash = p_base_tree
        
        UNION ALL
        
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'ours' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = p_ours_tree
        
        UNION ALL
        
        SELECT e->>'name' as path,
               e->>'mode' as mode,
               e->>'hash' as hash,
               'theirs' as source
        FROM trees,
        jsonb_array_elements(entries) e
        WHERE hash = p_theirs_tree
    ),
    -- Analyze changes
    analysis AS (
        SELECT DISTINCT path,
               bool_or(source = 'base') as in_base,
               bool_or(source = 'ours') as in_ours,
               bool_or(source = 'theirs') as in_theirs,
               max(CASE WHEN source = 'base' THEN hash END) as base_hash,
               max(CASE WHEN source = 'ours' THEN hash END) as ours_hash,
               max(CASE WHEN source = 'theirs' THEN hash END) as theirs_hash,
               max(CASE WHEN source = 'base' THEN mode END) as base_mode,
               max(CASE WHEN source = 'ours' THEN mode END) as ours_mode,
               max(CASE WHEN source = 'theirs' THEN mode END) as theirs_mode
        FROM all_paths
        GROUP BY path
    )
    SELECT path,
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
    WHERE NOT (ours_hash = theirs_hash