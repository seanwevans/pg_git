-- Path: /test/sql/diff_test.sql
-- pg_git diff sequence tests

BEGIN;

SELECT plan(2);

-- Direct diff_text check
SELECT results_eq(
    $$SELECT line_type || line_content FROM pggit.diff_text(E'C\nA\nB', E'C\nB\nA')$$,
    $$VALUES (' C'), ('-A'), ('+B'), ('-B'), ('+A')$$,
    'diff_text preserves line order'
);

-- Repository diff_commits check
SELECT pggit.init_repository('diff_repo', '/diff/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', E'C\nA\nB'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'author', 'initial') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', E'C\nB\nA'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'author', 'second') AS c2 \gset
SELECT set_config('vars.c2', :'c2', false);

SELECT results_eq(
    $$SELECT unnest(diff_content) FROM pggit.diff_commits(current_setting('vars.c1'), current_setting('vars.c2')) WHERE path = 'test.txt'$$,
    $$VALUES (' C'), ('-A'), ('+B'), ('-B'), ('+A')$$,
    'diff_commits preserves line order'
);

SELECT * FROM finish();
ROLLBACK;
