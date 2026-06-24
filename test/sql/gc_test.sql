-- Path: /test/sql/gc_test.sql
-- pg_git garbage collection tests

BEGIN;

SELECT plan(7);

-- Setup test repository and reachable commit
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'reachable.txt', 'reachable content'::bytea) AS reachable_blob \gset
SELECT set_config('vars.reachable_blob', :'reachable_blob', false);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'author', 'reachable commit') AS reachable_commit \gset
SELECT set_config('vars.reachable_commit', :'reachable_commit', false);

-- Create unreachable objects
SELECT pggit.create_blob((current_setting('vars.repo_id')::int), 'orphan content'::bytea) AS orphan_blob \gset
SELECT set_config('vars.orphan_blob', :'orphan_blob', false);
SELECT pggit.create_tree((current_setting('vars.repo_id')::int), jsonb_build_array(
    jsonb_build_object('mode','100644','type','blob','hash', :'orphan_blob','name','orphan.txt')
)) AS orphan_tree \gset
SELECT set_config('vars.orphan_tree', :'orphan_tree', false);
SELECT pggit.create_commit((current_setting('vars.repo_id')::int), :'orphan_tree', NULL, 'author', 'orphan commit') AS orphan_commit \gset
SELECT set_config('vars.orphan_commit', :'orphan_commit', false);

-- Run garbage collection
SELECT results_eq(
    $$SELECT object_type, objects_removed FROM pggit.gc((current_setting('vars.repo_id')::int)) ORDER BY object_type$$,
    $$VALUES ('blobs',1), ('commits',1), ('trees',1)$$,
    'GC removed unreachable objects'
);

-- Verify reachable commit preserved and unreachable removed
SELECT results_eq(
    $$SELECT count(*) FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES (2::bigint)$$,  -- initial commit + reachable commit; orphan removed
    'Only reachable commits remain'
);

SELECT results_eq(
    $$SELECT hash FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int) AND hash = current_setting('vars.reachable_commit')$$,
    $$SELECT current_setting('vars.reachable_commit')$$,
    'Reachable commit preserved'
);

SELECT is_empty(
    $$SELECT 1 FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int) AND hash = current_setting('vars.orphan_commit')$$,
    'Unreachable commit removed'
);

-- Verify trees and blobs
SELECT results_eq(
    $$SELECT count(*) FROM trees WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES (2::bigint)$$,  -- initial empty tree + reachable tree; orphan removed
    'Only reachable trees remain'
);

SELECT results_eq(
    $$SELECT count(*) FROM blobs WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES (1::bigint)$$,
    'Only reachable blob remains'
);

SELECT is_empty(
    $$SELECT 1 FROM blobs WHERE repo_id = (current_setting('vars.repo_id')::int) AND hash = current_setting('vars.orphan_blob')$$,
    'Unreachable blob removed'
);

SELECT * FROM finish();
ROLLBACK;

