-- Path: /test/sql/init.sql
-- pg_git initialization tests

CREATE EXTENSION IF NOT EXISTS pgtap;
-- CASCADE auto-installs the required extensions (pgcrypto, pg_trgm, plpython3u).
CREATE EXTENSION IF NOT EXISTS pg_git CASCADE;

BEGIN;

SELECT plan(12);

-- Test repository creation
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT lives_ok(
    $$SELECT (current_setting('vars.repo_id')::int)$$,
    'Can create repository'
);

SELECT results_eq(
    $$SELECT name FROM repositories WHERE path = '/test/path'$$,
    $$VALUES ('test_repo')$$,
    'Repository record created correctly'
);

SELECT results_eq(
    $$SELECT name FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'HEAD'$$,
    $$VALUES ('HEAD')$$,
    'HEAD reference created'
);

-- Test blob creation
SELECT lives_ok(
    $$SELECT pggit.create_blob((current_setting('vars.repo_id')::int), 'test content'::bytea)$$,
    'Can create blob'
);

SELECT results_eq(
    $$SELECT encode(content, 'escape') FROM blobs WHERE repo_id = (current_setting('vars.repo_id')::int) LIMIT 1$$,
    $$VALUES ('test content')$$,
    'Blob content stored correctly'
);

-- Test tree creation
SELECT lives_ok(
    $$SELECT pggit.create_tree((current_setting('vars.repo_id')::int), '[{"mode": "100644", "type": "blob", "hash": "abc", "name": "test.txt"}]'::jsonb)$$,
    'Can create tree'
);

SELECT results_eq(
    $$SELECT entries->0->>'name' FROM trees WHERE repo_id = (current_setting('vars.repo_id')::int) AND jsonb_array_length(entries) > 0 LIMIT 1$$,
    $$VALUES ('test.txt')$$,
    'Tree entries stored correctly'
);

-- Test basic commit
SELECT lives_ok(
    $$SELECT pggit.create_commit(
        (current_setting('vars.repo_id')::int),
        (SELECT hash FROM trees WHERE repo_id = (current_setting('vars.repo_id')::int) LIMIT 1),
        NULL,
        'test_author',
        'test commit'
    )$$,
    'Can create commit'
);

SELECT results_eq(
    $$SELECT message FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int) ORDER BY timestamp DESC LIMIT 1$$,
    $$VALUES ('test commit')$$,
    'Commit message stored correctly'
);

SELECT results_eq(
    $$SELECT author FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int) ORDER BY timestamp DESC LIMIT 1$$,
    $$VALUES ('test_author')$$,
    'Commit author stored correctly'
);

-- Test refs
SELECT lives_ok(
    $$SELECT pggit.update_ref((current_setting('vars.repo_id')::int), 'test_branch', (SELECT hash FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int) LIMIT 1))$$,
    'Can create branch reference'
);

SELECT results_eq(
    $$SELECT name FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'test_branch'$$,
    $$VALUES ('test_branch')$$,
    'Branch reference created correctly'
);

SELECT * FROM finish();
ROLLBACK;

