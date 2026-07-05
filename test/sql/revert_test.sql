-- Path: /test/sql/revert_test.sql
-- pg_git revert tests
-- Regression: revert previously called a non-existent apply_inverse_diff and
-- errored on every invocation.

BEGIN;

SELECT plan(5);

SELECT pggit.init_repository('revert_repo', '/revert/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- c1: a.txt = v1
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'v1'::bytea)
    AS blob_v1 \gset
SELECT set_config('vars.blob_v1', :'blob_v1', false);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c1') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);

-- c2: a.txt -> v2, and add b.txt
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'v2'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'b.txt', 'new'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c2') AS c2 \gset
SELECT set_config('vars.c2', :'c2', false);

-- Revert c2. Reversing the c1->c2 delta onto HEAD undoes both changes.
SELECT pggit.revert((current_setting('vars.repo_id')::int), current_setting('vars.c2'))
    AS revert_commit \gset
SELECT set_config('vars.revert_commit', :'revert_commit', false);

-- A fresh commit was created (distinct from the reverted one).
SELECT isnt(
    current_setting('vars.revert_commit'),
    current_setting('vars.c2'),
    'revert creates a new commit'
);

-- HEAD advanced to the revert commit.
SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD'),
    current_setting('vars.revert_commit'),
    'HEAD points at the revert commit'
);

SELECT tree_hash AS revert_tree FROM commits WHERE hash = :'revert_commit' \gset
SELECT set_config('vars.revert_tree', :'revert_tree', false);

-- a.txt is restored to its pre-c2 (v1) content.
SELECT is(
    (SELECT blob_hash FROM pggit.get_tree_files(
        (current_setting('vars.repo_id')::int), current_setting('vars.revert_tree')) gtf
     WHERE gtf.path = 'a.txt'),
    current_setting('vars.blob_v1'),
    'revert restores a file modified by the reverted commit'
);

-- b.txt, which c2 added, is removed by the revert.
SELECT is_empty(
    $$SELECT 1 FROM pggit.get_tree_files(
        (current_setting('vars.repo_id')::int), current_setting('vars.revert_tree')) gtf
      WHERE gtf.path = 'b.txt'$$,
    'revert removes a file added by the reverted commit'
);

-- The reverted tree contains exactly the surviving file.
SELECT results_eq(
    $$SELECT gtf.path FROM pggit.get_tree_files(
        (current_setting('vars.repo_id')::int), current_setting('vars.revert_tree')) gtf
      ORDER BY gtf.path$$,
    $$VALUES ('a.txt')$$,
    'revert yields the expected tree'
);

SELECT * FROM finish();
ROLLBACK;
