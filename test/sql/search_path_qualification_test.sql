-- Path: /test/sql/search_path_qualification_test.sql
-- Validate pg_git functions work with a non-default search_path.

BEGIN;

SELECT plan(4);

SET LOCAL search_path TO public;

SELECT pg_git.init_repository('spath_repo', '/tmp/spath_repo') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'file.txt', 'hello world'::bytea);

SELECT lives_ok(
    $$SELECT pg_git.commit_index(:repo_id, 'search_path_tester', 'commit under custom search_path')$$,
    'Commit succeeds with non-default search_path'
);

SELECT results_eq(
    $$SELECT COUNT(*)::bigint FROM pg_git.commits WHERE repo_id = :repo_id$$,
    $$VALUES (2::bigint)$$,
    'Commit rows are written in pg_git.commits'
);

SELECT results_eq(
    $$SELECT commit_hash FROM pg_git.refs WHERE repo_id = :repo_id AND name = 'master'$$,
    $$SELECT commit_hash FROM pg_git.refs WHERE repo_id = :repo_id AND name = 'HEAD'$$,
    'HEAD and master remain aligned after commit'
);

SELECT results_eq(
    $$SELECT message FROM pg_git.commits WHERE repo_id = :repo_id ORDER BY timestamp DESC LIMIT 1$$,
    $$VALUES ('commit under custom search_path'::text)$$,
    'Latest commit message is stored correctly'
);

SELECT * FROM finish();
ROLLBACK;
