-- Path: /test/sql/init.sql
-- pg_git initialization tests

BEGIN;

SELECT plan(12);

-- Test repository creation
SELECT lives_ok(
    $$SELECT pg_git.init_repository('test_repo', '/test/path')$$,
    'Can create repository'
);

SELECT results_eq(
    $$SELECT name FROM repositories WHERE path = '/test/path'$$,
    $$VALUES ('test_repo')$$,
    'Repository record created correctly'
);

SELECT results_eq(
    $$SELECT name FROM refs WHERE name = 'HEAD'$$,
    $$VALUES ('HEAD')$$,
    'HEAD reference created'
);

-- Test blob creation
SELECT lives_ok(
    $$SELECT pg_git.create_blob('test content'::bytea)$$,
    'Can create blob'
);

SELECT results_eq(
    $$SELECT encode(content, 'escape') FROM blobs LIMIT 1$$,
    $$VALUES ('test content')$$,
    'Blob content stored correctly'
);

-- Test tree creation
SELECT lives_ok(
    $$SELECT pg_git.create_tree('[{"mode": "100644", "type": "blob", "hash": "abc", "name": "test.txt"}]'::jsonb)$$,
    'Can create tree'
);

SELECT results_eq(
    $$SELECT entries->0->>'name' FROM trees LIMIT 1$$,
    $$VALUES ('test.txt')$$,
    'Tree entries stored correctly'
);

-- Test basic commit
SELECT lives_ok(
    $$SELECT pg_git.create_commit(
        (SELECT hash FROM trees LIMIT 1),
        NULL,
        'test_author',
        'test commit'
    )$$,
    'Can create commit'
);

SELECT results_eq(
    $$SELECT message FROM commits LIMIT 1$$,
    $$VALUES ('test commit')$$,
    'Commit message stored correctly'
);

SELECT results_eq(
    $$SELECT author FROM commits LIMIT 1$$,
    $$VALUES ('test_author')$$,
    'Commit author stored correctly'
);

-- Test refs
SELECT lives_ok(
    $$SELECT pg_git.update_ref('test_branch', (SELECT hash FROM commits LIMIT 1))$$,
    'Can create branch reference'
);

SELECT results_eq(
    $$SELECT name FROM refs WHERE name = 'test_branch'$$,
    $$VALUES ('test_branch')$$,
    'Branch reference created correctly'
);

SELECT * FROM finish();
ROLLBACK;

