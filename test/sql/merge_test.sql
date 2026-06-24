-- Path: /test/sql/merge_test.sql
-- pg_git merge tests

BEGIN;

SELECT plan(6);

-- Setup test repository with branched history
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', 'test content'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'test_author', 'main commit') AS main_commit \gset
SELECT set_config('vars.main_commit', :'main_commit', false);

SELECT pggit.create_branch((current_setting('vars.repo_id')::int), 'feature');
SELECT pggit.checkout_branch((current_setting('vars.repo_id')::int), 'feature');
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'feature.txt', 'feature content'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'test_author', 'feature commit') AS feature_commit \gset
SELECT set_config('vars.feature_commit', :'feature_commit', false);

-- Test merge base finding
SELECT results_eq(
    $$SELECT pggit.find_merge_base(current_setting('vars.main_commit'), current_setting('vars.feature_commit'))$$,
    $$SELECT current_setting('vars.main_commit')$$,
    'Finds correct merge base'
);

-- Test fast-forward possible check
SELECT results_eq(
    $$SELECT pggit.can_fast_forward(current_setting('vars.main_commit'), current_setting('vars.feature_commit'))$$,
    $$VALUES (true)$$,
    'Correctly identifies fast-forward possibility'
);

-- Test basic merge
SELECT lives_ok(
    $$SELECT pggit.merge_branches((current_setting('vars.repo_id')::int), 'feature', 'master')$$,
    'Can perform merge'
);

-- Test HEAD after merge
SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'HEAD'$$,
    $$SELECT current_setting('vars.feature_commit')$$,
    'HEAD points to correct commit after merge'
);

-- Test branch pointer after merge
SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'master'$$,
    $$SELECT current_setting('vars.feature_commit')$$,
    'Branch points to correct commit after merge'
);

-- Test merge conflict detection
SELECT throws_ok(
    $$SELECT pggit.merge_branches((current_setting('vars.repo_id')::int), 'invalid-branch')$$,
    'Branch invalid-branch does not exist',
    'Detects invalid branch names'
);

SELECT * FROM finish();
ROLLBACK;

