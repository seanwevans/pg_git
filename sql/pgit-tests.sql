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

-- Path: /test/sql/add_test.sql
-- pg_git add/stage tests

BEGIN;

SELECT plan(6);

-- Setup test repository
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset

-- Test staging a file
SELECT lives_ok(
    $$SELECT pg_git.stage_file(:repo_id, 'test.txt', 'test content'::bytea)$$,
    'Can stage a file'
);

SELECT results_eq(
    $$SELECT path FROM index_entries WHERE repo_id = :repo_id$$,
    $$VALUES ('test.txt')$$,
    'File path indexed correctly'
);

-- Test updating staged file
SELECT lives_ok(
    $$SELECT pg_git.stage_file(:repo_id, 'test.txt', 'updated content'::bytea)$$,
    'Can update staged file'
);

SELECT results_eq(
    $$SELECT encode(content, 'escape') FROM blobs b
    JOIN index_entries i ON b.hash = i.blob_hash
    WHERE i.repo_id = :repo_id$$,
    $$VALUES ('updated content')$$,
    'Updated content stored correctly'
);

-- Test unstaging
SELECT lives_ok(
    $$SELECT pg_git.unstage_file(:repo_id, 'test.txt')$$,
    'Can unstage file'
);

SELECT is_empty(
    $$SELECT * FROM index_entries WHERE repo_id = :repo_id$$,
    'Index cleared after unstage'
);

SELECT * FROM finish();
ROLLBACK;

-- Path: /test/sql/commit_test.sql
-- pg_git commit tests

BEGIN;

SELECT plan(8);

-- Setup test repository and staged file
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'test.txt', 'test content'::bytea);

-- Test commit creation
SELECT lives_ok(
    $$SELECT pg_git.commit_index(:repo_id, 'test_author', 'test commit')$$,
    'Can create commit from index'
);

SELECT results_eq(
    $$SELECT message FROM commits ORDER BY timestamp DESC LIMIT 1$$,
    $$VALUES ('test commit')$$,
    'Commit message stored correctly'
);

SELECT results_eq(
    $$SELECT author FROM commits ORDER BY timestamp DESC LIMIT 1$$,
    $$VALUES ('test_author')$$,
    'Commit author stored correctly'
);

-- Test commit tree content
SELECT results_eq(
    $$SELECT jsonb_array_length(entries) FROM trees t
    JOIN commits c ON c.tree_hash = t.hash
    ORDER BY c.timestamp DESC LIMIT 1$$,
    $$VALUES (1)$$,
    'Commit tree has correct number of entries'
);

-- Test index cleared after commit
SELECT is_empty(
    $$SELECT * FROM index_entries WHERE repo_id = :repo_id$$,
    'Index cleared after commit'
);

-- Test commit history
SELECT results_eq(
    $$SELECT COUNT(*) FROM pg_git.get_log(:repo_id)$$,
    $$VALUES (2)$$,  -- Initial commit + our test commit
    'Commit history has correct length'
);

-- Test decorated log
SELECT results_eq(
    $$SELECT array_length(refs, 1) FROM pg_git.get_decorated_log(:repo_id) LIMIT 1$$,
    $$VALUES (1)$$,
    'Decorated log shows correct number of refs'
);

-- Test parent relationship
SELECT results_eq(
    $$SELECT COUNT(*) FROM commits WHERE parent_hash IS NOT NULL$$,
    $$VALUES (1)$$,
    'Parent relationship stored correctly'
);

SELECT * FROM finish();
ROLLBACK;

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