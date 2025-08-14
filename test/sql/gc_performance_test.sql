-- Path: /test/sql/gc_performance_test.sql
-- pg_git garbage collection performance test

BEGIN;

SELECT plan(1);

-- Setup test repository with a reachable commit
SELECT pg_git.init_repository('perf_repo', '/perf/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'keep.txt', 'keep content'::bytea);
SELECT pg_git.commit_index(:repo_id, 'author', 'reachable commit');

-- Create many unreachable objects
DO $$
DECLARE
    i INTEGER;
    blob_hash TEXT;
    tree_hash TEXT;
BEGIN
    FOR i IN 1..1000 LOOP
        blob_hash := pg_git.create_blob(:repo_id, ('orphan content ' || i)::bytea);
        tree_hash := pg_git.create_tree(:repo_id,
            jsonb_build_array(
                jsonb_build_object('mode','100644','type','blob','hash',blob_hash,'name','orphan' || i || '.txt')
            )
        );
        PERFORM pg_git.create_commit(:repo_id, tree_hash, NULL, 'author', 'orphan commit');
    END LOOP;
END$$;

-- Capture memory usage before GC
SELECT sum(total_allocated) AS before_bytes FROM pg_backend_memory_contexts \gset

-- Run garbage collection
SELECT pg_git.gc(:repo_id);

-- Capture memory usage after GC
SELECT sum(total_allocated) AS after_bytes FROM pg_backend_memory_contexts \gset

-- Verify GC runs with limited memory growth (<5MB)
SELECT ok( abs((:after_bytes::bigint - :before_bytes::bigint)) < 5000000,
            'GC runs with low memory overhead');

SELECT * FROM finish();
ROLLBACK;
