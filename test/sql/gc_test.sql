-- Path: /test/sql/gc_test.sql
-- pg_git garbage collection tests

BEGIN;

SELECT plan(7);

-- Setup test repository and reachable commit
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'reachable.txt', 'reachable content'::bytea) AS reachable_blob \gset
SELECT pg_git.commit_index(:repo_id, 'author', 'reachable commit') AS reachable_commit \gset

-- Create unreachable objects
SELECT pg_git.create_blob(:repo_id, 'orphan content'::bytea) AS orphan_blob \gset
SELECT pg_git.create_tree(:repo_id, jsonb_build_array(
    jsonb_build_object('mode','100644','type','blob','hash', :'orphan_blob','name','orphan.txt')
)) AS orphan_tree \gset
SELECT pg_git.create_commit(:repo_id, :'orphan_tree', NULL, 'author', 'orphan commit') AS orphan_commit \gset

-- Run garbage collection
SELECT results_eq(
    $$SELECT object_type, objects_removed FROM pg_git.gc(:repo_id) ORDER BY object_type$$,
    $$VALUES ('blobs',1), ('commits',1), ('trees',1)$$,
    'GC removed unreachable objects'
);

-- Verify reachable commit preserved and unreachable removed
SELECT results_eq(
    $$SELECT count(*) FROM commits WHERE repo_id = :repo_id$$,
    $$VALUES (1)$$,
    'Only reachable commit remains'
);

SELECT results_eq(
    $$SELECT hash FROM commits WHERE repo_id = :repo_id$$,
    $$SELECT :'reachable_commit'$$,
    'Reachable commit preserved'
);

SELECT is_empty(
    $$SELECT 1 FROM commits WHERE repo_id = :repo_id AND hash = :'orphan_commit'$$,
    'Unreachable commit removed'
);

-- Verify trees and blobs
SELECT results_eq(
    $$SELECT count(*) FROM trees WHERE repo_id = :repo_id$$,
    $$VALUES (1)$$,
    'Only reachable tree remains'
);

SELECT results_eq(
    $$SELECT count(*) FROM blobs WHERE repo_id = :repo_id$$,
    $$VALUES (1)$$,
    'Only reachable blob remains'
);

SELECT is_empty(
    $$SELECT 1 FROM blobs WHERE repo_id = :repo_id AND hash = :'orphan_blob'$$,
    'Unreachable blob removed'
);

SELECT * FROM finish();
ROLLBACK;

