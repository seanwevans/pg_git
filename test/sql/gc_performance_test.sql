-- Path: /test/sql/gc_performance_test.sql
-- pg_git garbage collection performance test

BEGIN;

SELECT plan(1);

-- Setup test repository with a reachable commit
SELECT pggit.init_repository('perf_repo', '/perf/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'keep.txt', 'keep content'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'author', 'reachable commit');

-- Create many unreachable objects
DO $$
DECLARE
    i INTEGER;
    blob_hash TEXT;
    tree_hash TEXT;
BEGIN
    FOR i IN 1..1000 LOOP
        blob_hash := pggit.create_blob((current_setting('vars.repo_id')::int), ('orphan content ' || i)::bytea);
        tree_hash := pggit.create_tree((current_setting('vars.repo_id')::int),
            jsonb_build_array(
                jsonb_build_object('mode','100644','type','blob','hash',blob_hash,'name','orphan' || i || '.txt')
            )
        );
        PERFORM pggit.create_commit((current_setting('vars.repo_id')::int), tree_hash, NULL, 'author', 'orphan commit');
    END LOOP;
END$$;

-- Capture memory usage before GC
SELECT sum(total_bytes) AS before_bytes FROM pg_backend_memory_contexts \gset

-- Run garbage collection
SELECT pggit.gc((current_setting('vars.repo_id')::int));

-- Capture memory usage after GC
SELECT sum(total_bytes) AS after_bytes FROM pg_backend_memory_contexts \gset

-- Verify GC runs with limited memory growth (<5MB)
SELECT ok( abs((:after_bytes::bigint - :before_bytes::bigint)) < 5000000,
            'GC runs with low memory overhead');

SELECT * FROM finish();
ROLLBACK;
