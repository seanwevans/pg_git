-- Path: /test/sql/search_path_qualification_test.sql
-- Validate pg_git functions work with a non-default search_path.

BEGIN;

SELECT plan(4);

SET LOCAL search_path TO public;

SELECT pggit.init_repository('spath_repo', '/tmp/spath_repo') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'file.txt', 'hello world'::bytea);

SELECT lives_ok(
    $$SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'search_path_tester', 'commit under custom search_path')$$,
    'Commit succeeds with non-default search_path'
);

SELECT results_eq(
    $$SELECT COUNT(*)::bigint FROM pggit.commits WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES (2::bigint)$$,
    'Commit rows are written in pggit.commits'
);

SELECT results_eq(
    $$SELECT commit_hash FROM pggit.refs WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'master'$$,
    $$SELECT pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD')$$,
    'HEAD and master remain aligned after commit'
);

SELECT results_eq(
    $$SELECT message FROM pggit.commits WHERE repo_id = (current_setting('vars.repo_id')::int) ORDER BY timestamp DESC LIMIT 1$$,
    $$VALUES ('commit under custom search_path'::text)$$,
    'Latest commit message is stored correctly'
);

SELECT * FROM finish();
ROLLBACK;
