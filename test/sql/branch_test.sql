-- Path: /test/sql/branch_test.sql
-- pg_git branch tests

BEGIN;

SELECT plan(8);

-- Setup test repository with initial commit
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'test.txt', 'test content'::bytea);
SELECT pg_git.commit_index(:repo_id, 'test_author', 'test commit');

-- Test branch creation
SELECT lives_ok(
    $$SELECT pg_git.create_branch(:repo_id, 'test-branch')$$,
    'Can create branch'
);

SELECT results_eq(
    $$SELECT name FROM pg_git.list_branches(:repo_id)$$,
    $$VALUES ('master'), ('test-branch')$$,
    'Branch list shows all branches'
);

-- Test checkout
SELECT lives_ok(
    $$SELECT pg_git.checkout_branch(:repo_id, 'test-branch')$$,
    'Can checkout branch'
);

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE name = 'HEAD'$$,
    $$SELECT commit_hash FROM refs WHERE name = 'test-branch'$$,
    'HEAD points to correct commit after checkout'
);

-- Test new branch with start point
SELECT lives_ok(
    $$SELECT pg_git.create_branch(:repo_id, 'feature-branch', 
        (SELECT commit_hash FROM refs WHERE name = 'master'))$$,
    'Can create branch from specific commit'
);

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE name = 'feature-branch'$$,
    $$SELECT commit_hash FROM refs WHERE name = 'master'$$,
    'Branch created at correct commit'
);

-- Test checkout with create
SELECT lives_ok(
    $$SELECT pg_git.checkout_branch(:repo_id, 'new-branch', TRUE)$$,
    'Can checkout with branch creation'
);

SELECT results_eq(
    $$SELECT name FROM pg_git.list_branches(:repo_id)$$,
    $$VALUES ('master'), ('test-branch'), ('feature-branch'), ('new-branch')$$,
    'New branch created and listed'
);

SELECT * FROM finish();
ROLLBACK;

