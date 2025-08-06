-- Path: /test/sql/diff_test.sql
-- pg_git diff sequence tests

BEGIN;

SELECT plan(2);

-- Direct diff_text check
SELECT results_eq(
    $$SELECT line_type || line_content FROM pg_git.diff_text('C\nA\nB', 'C\nB\nA')$$,
    $$VALUES (' C'), ('-A'), ('+B'), ('-B'), ('+A')$$,
    'diff_text preserves line order'
);

-- Repository diff_commits check
SELECT pg_git.init_repository('diff_repo', '/diff/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'test.txt', 'C\nA\nB'::bytea);
SELECT pg_git.commit_index(:repo_id, 'author', 'initial') AS c1 \gset
SELECT pg_git.stage_file(:repo_id, 'test.txt', 'C\nB\nA'::bytea);
SELECT pg_git.commit_index(:repo_id, 'author', 'second') AS c2 \gset

SELECT results_eq(
    $$SELECT unnest(diff_content) FROM pg_git.diff_commits(:c1, :c2) WHERE path = 'test.txt'$$,
    $$VALUES (' C'), ('-A'), ('+B'), ('-B'), ('+A')$$,
    'diff_commits preserves line order'
);

SELECT * FROM finish();
ROLLBACK;
