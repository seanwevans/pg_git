-- Path: /test/sql/remote_test.sql
-- pg_git remote operations tests

BEGIN;

SELECT plan(10);

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

-- Prepare a remote branch tip that fetch materializes into refs as origin/master
SELECT lives_ok(
    $$INSERT INTO pg_git.remote_refs (repo_id, remote_name, ref_name, commit_hash)
      SELECT :repo_id, 'origin', 'master', commit_hash
      FROM refs
      WHERE repo_id = :repo_id AND name = 'master'$$,
    'Can track remote refs'
);

-- Test fetch operation
SELECT lives_ok(
    $$SELECT * FROM pg_git.fetch_remote(:repo_id, 'origin')$$,
    'Can fetch from remote'
);

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = :repo_id AND name = 'origin/master'$$,
    $$SELECT commit_hash FROM pg_git.remote_refs WHERE repo_id = :repo_id AND remote_name = 'origin' AND ref_name = 'master'$$,
    'Fetch materializes remote tracking ref in refs'
);

-- Test push operation
SELECT lives_ok(
    $$SELECT pg_git.push(:repo_id, 'origin', 'master')$$,
    'Can push to remote'
);

-- Test pull operation succeeds when tracking branch exists
SELECT lives_ok(
    $$SELECT pg_git.pull(:repo_id, 'origin', 'master')$$,
    'Can pull from remote tracked branch'
);

-- Test pull operation fails with clear error when branch is missing remotely
SELECT throws_ok(
    $$SELECT pg_git.pull(:repo_id, 'origin', 'feature')$$,
    'Remote-tracking ref origin/feature does not exist for repo .*',
    'Pull fails when remote tracking branch is missing'
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
