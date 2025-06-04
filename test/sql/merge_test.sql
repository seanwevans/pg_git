-- Path: /test/sql/merge_test.sql
-- pg_git merge tests

BEGIN;

SELECT plan(6);

-- Setup test repository with branched history
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'test.txt', 'test content'::bytea);
SELECT pg_git.commit_index(:repo_id, 'test_author', 'main commit') AS main_commit \gset

SELECT pg_git.create_branch(:repo_id, 'feature');
SELECT pg_git.checkout_branch(:repo_id, 'feature');
SELECT pg_git.stage_file(:repo_id, 'feature.txt', 'feature content'::bytea);
SELECT pg_git.commit_index(:repo_id, 'test_author', 'feature commit') AS feature_commit \gset

-- Test merge base finding
SELECT results_eq(
    $$SELECT pg_git.find_merge_base(:main_commit, :feature_commit)$$,
    $$SELECT :main_commit$$,
    'Finds correct merge base'
);

-- Test fast-forward possible check
SELECT results_eq(
    $$SELECT pg_git.can_fast_forward(:main_commit, :feature_commit)$$,
    $$VALUES (true)$$,
    'Correctly identifies fast-forward possibility'
);

-- Test basic merge
SELECT lives_ok(
    $$SELECT pg_git.merge_branches(:repo_id, 'feature', 'master')$$,
    'Can perform merge'
);

-- Test HEAD after merge
SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE name = 'HEAD'$$,
    $$SELECT :feature_commit$$,
    'HEAD points to correct commit after merge'
);

-- Test branch pointer after merge
SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE name = 'master'$$,
    $$SELECT :feature_commit$$,
    'Branch points to correct commit after merge'
);

-- Test merge conflict detection
SELECT throws_ok(
    $$SELECT pg_git.merge_branches(:repo_id, 'invalid-branch')$$,
    'Branch invalid-branch does not exist',
    'Detects invalid branch names'
);

SELECT * FROM finish();
ROLLBACK;

