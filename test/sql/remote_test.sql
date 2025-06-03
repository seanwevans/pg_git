-- Path: /test/sql/remote_test.sql
-- pg_git remote operations tests

BEGIN;

SELECT plan(8);

-- Setup test repository
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset

-- Test remote addition
SELECT lives_ok(
    $$SELECT pg_git.add_remote(:repo_id, 'origin', 'postgresql://remote/repo')$$,
    'Can add remote'
);

SELECT results_eq(
    $$SELECT url FROM pg_git.remotes WHERE repo_id = :repo_id$$,
    $$VALUES ('postgresql://remote/repo')$$,
    'Remote URL stored correctly'
);

-- Test fetch operation
SELECT lives_ok(
    $$SELECT * FROM pg_git.fetch_remote(:repo_id, 'origin')$$,
    'Can fetch from remote'
);

-- Test remote refs
SELECT lives_ok(
    $$INSERT INTO pg_git.remote_refs (repo_id, remote_name, ref_name, commit_hash)
    VALUES (:repo_id, 'origin', 'main', 'test_hash')$$,
    'Can track remote refs'
);

-- Test push operation
SELECT lives_ok(
    $$SELECT pg_git.push(:repo_id, 'origin', 'master')$$,
    'Can push to remote'
);

-- Test pull operation
SELECT lives_ok(
    $$SELECT pg_git.pull(:repo_id, 'origin', 'master')$$,
    'Can pull from remote'
);

-- Test clone operation
SELECT lives_ok(
    $$SELECT pg_git.clone('postgresql://remote/repo', 'clone_test', '/clone/path')$$,
    'Can clone repository'
);

SELECT results_eq(
    $$SELECT name FROM repositories WHERE path = '/clone/path'$$,
    $$VALUES ('clone_test')$$,
    'Cloned repository created correctly'
);

SELECT * FROM finish();
ROLLBACK;
