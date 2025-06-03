-- Path: /test/sql/add_test.sql
-- pg_git add/stage tests

BEGIN;

SELECT plan(6);

-- Setup test repository
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset

-- Test staging a file
SELECT lives_ok(
    $$SELECT pg_git.stage_file(:repo_id, 'test.txt', 'test content'::bytea)$$,
    'Can stage a file'
);

SELECT results_eq(
    $$SELECT path FROM index_entries WHERE repo_id = :repo_id$$,
    $$VALUES ('test.txt')$$,
    'File path indexed correctly'
);

-- Test updating staged file
SELECT lives_ok(
    $$SELECT pg_git.stage_file(:repo_id, 'test.txt', 'updated content'::bytea)$$,
    'Can update staged file'
);

SELECT results_eq(
    $$SELECT encode(content, 'escape') FROM blobs b
    JOIN index_entries i ON b.hash = i.blob_hash
    WHERE i.repo_id = :repo_id$$,
    $$VALUES ('updated content')$$,
    'Updated content stored correctly'
);

-- Test unstaging
SELECT lives_ok(
    $$SELECT pg_git.unstage_file(:repo_id, 'test.txt')$$,
    'Can unstage file'
);

SELECT is_empty(
    $$SELECT * FROM index_entries WHERE repo_id = :repo_id$$,
    'Index cleared after unstage'
);

SELECT * FROM finish();
ROLLBACK;

