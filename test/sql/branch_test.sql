-- Path: /test/sql/branch_test.sql
-- pg_git branch tests

BEGIN;

SELECT plan(8);

-- Setup test repository with initial commit
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', 'test content'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'test_author', 'test commit');

-- Test branch creation
SELECT lives_ok(
    $$SELECT pggit.create_branch((current_setting('vars.repo_id')::int), 'test-branch')$$,
    'Can create branch'
);

SELECT results_eq(
    $$SELECT name FROM pggit.list_branches((current_setting('vars.repo_id')::int))$$,
    $$VALUES ('master'), ('test-branch')$$,
    'Branch list shows all branches'
);

-- Test checkout
SELECT lives_ok(
    $$SELECT pggit.checkout_branch((current_setting('vars.repo_id')::int), 'test-branch')$$,
    'Can checkout branch'
);

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'HEAD'$$,
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'test-branch'$$,
    'HEAD points to correct commit after checkout'
);

-- Test new branch with start point
SELECT lives_ok(
    $$SELECT pggit.create_branch((current_setting('vars.repo_id')::int), 'feature-branch', 
        (SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'master'))$$,
    'Can create branch from specific commit'
);

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'feature-branch'$$,
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'master'$$,
    'Branch created at correct commit'
);

-- Test checkout with create
SELECT lives_ok(
    $$SELECT pggit.checkout_branch((current_setting('vars.repo_id')::int), 'new-branch', TRUE)$$,
    'Can checkout with branch creation'
);

SELECT results_eq(
    $$SELECT name FROM pggit.list_branches((current_setting('vars.repo_id')::int))$$,
    $$VALUES ('feature-branch'), ('master'), ('new-branch'), ('test-branch')$$,
    'New branch created and listed'
);

SELECT * FROM finish();
ROLLBACK;

