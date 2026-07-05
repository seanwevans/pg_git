-- Path: /test/sql/commit_test.sql
-- pg_git commit tests

BEGIN;

SELECT plan(9);

-- Setup test repository and staged file
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', 'test content'::bytea);

-- Test commit creation
SELECT lives_ok(
    $$SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'test_author', 'test commit')$$,
    'Can create commit from index'
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

SELECT results_eq(
    $$SELECT commit_hash FROM refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'master'$$,
    $$SELECT pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD')$$,
    'Branch reference moves to new commit'
);

-- Test commit tree content
SELECT results_eq(
    $$SELECT jsonb_array_length(entries) FROM trees t
    JOIN commits c ON c.repo_id = (current_setting('vars.repo_id')::int) AND c.tree_hash = t.hash AND t.repo_id = (current_setting('vars.repo_id')::int)
    ORDER BY c.timestamp DESC LIMIT 1$$,
    $$VALUES (1)$$,
    'Commit tree has correct number of entries'
);

-- Test index cleared after commit
SELECT is_empty(
    $$SELECT * FROM index_entries WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    'Index cleared after commit'
);

-- Test commit history
SELECT results_eq(
    $$SELECT COUNT(*) FROM pggit.get_log((current_setting('vars.repo_id')::int))$$,
    $$VALUES (2::bigint)$$,  -- Initial commit + our test commit
    'Commit history has correct length'
);

-- Test decorated log
SELECT results_eq(
    $$SELECT array_length(refs, 1) FROM pggit.get_decorated_log((current_setting('vars.repo_id')::int)) LIMIT 1$$,
    $$VALUES (1)$$,
    'Decorated log shows correct number of refs'
);

-- Test parent relationship
SELECT results_eq(
    $$SELECT COUNT(*) FROM commits WHERE repo_id = (current_setting('vars.repo_id')::int) AND parent_hash IS NOT NULL$$,
    $$VALUES (1::bigint)$$,
    'Parent relationship stored correctly'
);

SELECT * FROM finish();
ROLLBACK;

