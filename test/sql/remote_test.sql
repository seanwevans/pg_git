-- Path: /test/sql/remote_test.sql
-- pg_git remote operations tests

BEGIN;

SELECT plan(10);

-- Setup test repository
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Test remote addition
SELECT lives_ok(
    $$SELECT pggit.add_remote((current_setting('vars.repo_id')::int), 'origin', 'postgresql://remote/repo')$$,
    'Can add remote'
);

SELECT results_eq(
    $$SELECT url FROM pggit.remotes WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES ('postgresql://remote/repo')$$,
    'Remote URL stored correctly'
);

-- Prepare a remote branch tip that fetch materializes into refs as origin/master
SELECT lives_ok(
    $$INSERT INTO pggit.remote_refs (repo_id, remote_name, ref_name, commit_hash)
      SELECT (current_setting('vars.repo_id')::int), 'origin', 'master', commit_hash
      FROM refs
      WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'master'$$,
    'Can track remote refs'
);

-- Test fetch operation
SELECT lives_ok(
    $$SELECT * FROM pggit.fetch_remote((current_setting('vars.repo_id')::int), 'origin')$$,
    'Can fetch from remote'
);

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'origin/master'$$,
    $$SELECT commit_hash FROM pggit.remote_refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND remote_name = 'origin' AND ref_name = 'master'$$,
    'Fetch materializes remote tracking ref in refs'
);

-- Test push operation
SELECT lives_ok(
    $$SELECT pggit.push((current_setting('vars.repo_id')::int), 'origin', 'master')$$,
    'Can push to remote'
);

-- Test pull operation succeeds when tracking branch exists
SELECT lives_ok(
    $$SELECT pggit.pull((current_setting('vars.repo_id')::int), 'origin', 'master')$$,
    'Can pull from remote tracked branch'
);

-- Test pull operation fails with clear error when branch is missing remotely
SELECT throws_matching(
    $$SELECT pggit.pull((current_setting('vars.repo_id')::int), 'origin', 'feature')$$,
    'Remote-tracking ref origin/feature does not exist for repo .*',
    'Pull fails when remote tracking branch is missing'
);

-- Test clone operation
SELECT lives_ok(
    $$SELECT pggit.clone('postgresql://remote/repo', 'clone_test', '/clone/path')$$,
    'Can clone repository'
);

SELECT results_eq(
    $$SELECT name FROM repositories WHERE path = '/clone/path'$$,
    $$VALUES ('clone_test')$$,
    'Cloned repository created correctly'
);

SELECT * FROM finish();
ROLLBACK;
