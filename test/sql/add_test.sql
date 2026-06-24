-- Path: /test/sql/add_test.sql
-- pg_git add/stage tests

BEGIN;

SELECT plan(10);

-- Setup test repository
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Test staging a file
SELECT lives_ok(
    $$SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', 'test content'::bytea)$$,
    'Can stage a file'
);

SELECT results_eq(
    $$SELECT path FROM index_entries WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES ('test.txt')$$,
    'File path indexed correctly'
);

-- Test updating staged file
SELECT lives_ok(
    $$SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', 'updated content'::bytea)$$,
    'Can update staged file'
);

SELECT results_eq(
    $$SELECT encode(content, 'escape') FROM blobs b
    JOIN index_entries i ON b.hash = i.blob_hash
    WHERE i.repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES ('updated content')$$,
    'Updated content stored correctly'
);

-- Test unstaging
SELECT lives_ok(
    $$SELECT pggit.unstage_file((current_setting('vars.repo_id')::int), 'test.txt')$$,
    'Can unstage file'
);

SELECT is_empty(
    $$SELECT * FROM index_entries WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    'Index cleared after unstage'
);

-- Test path normalization
SELECT lives_ok(
    $$SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'dir/./sub/../file.txt', 'norm content'::bytea)$$,
    'Stages file with normalized path'
);

SELECT results_eq(
    $$SELECT path FROM index_entries WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES ('dir/file.txt')$$,
    'Normalized path stored correctly'
);

-- Test rejection of path traversal
SELECT throws_ok(
    $$SELECT pggit.stage_file((current_setting('vars.repo_id')::int), '../evil.txt', 'x'::bytea)$$,
    'Path traversal is not allowed',
    'Rejects path traversal'
);

-- Test rejection of absolute paths
SELECT throws_ok(
    $$SELECT pggit.stage_file((current_setting('vars.repo_id')::int), '/etc/passwd', 'x'::bytea)$$,
    'Absolute paths are not allowed',
    'Rejects absolute paths'
);

SELECT * FROM finish();
ROLLBACK;

