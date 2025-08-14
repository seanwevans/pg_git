-- Path: /test/sql/add_test.sql
-- pg_git add/stage tests

BEGIN;

SELECT plan(10);

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

-- Test path normalization
SELECT lives_ok(
    $$SELECT pg_git.stage_file(:repo_id, 'dir/./sub/../file.txt', 'norm content'::bytea)$$,
    'Stages file with normalized path'
);

SELECT results_eq(
    $$SELECT path FROM index_entries WHERE repo_id = :repo_id$$,
    $$VALUES ('dir/file.txt')$$,
    'Normalized path stored correctly'
);

-- Test rejection of path traversal
SELECT throws_ok(
    $$SELECT pg_git.stage_file(:repo_id, '../evil.txt', 'x'::bytea)$$,
    'Path traversal is not allowed',
    'Rejects path traversal'
);

-- Test rejection of absolute paths
SELECT throws_ok(
    $$SELECT pg_git.stage_file(:repo_id, '/etc/passwd', 'x'::bytea)$$,
    'Absolute paths are not allowed',
    'Rejects absolute paths'
);

SELECT * FROM finish();
ROLLBACK;

