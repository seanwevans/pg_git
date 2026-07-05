-- Path: /test/sql/reset_test.sql
-- pg_git reset tests

BEGIN;

SELECT plan(7);

-- Setup: repository with two commits on a single line of history.
SELECT pggit.init_repository('reset_repo', '/reset/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- First commit: a.txt = 'hello'
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'hello'::bytea)
    AS blob_v1 \gset
SELECT set_config('vars.blob_v1', :'blob_v1', false);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'first') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);

-- Second commit: a.txt = 'world'
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'world'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'second') AS c2 \gset
SELECT set_config('vars.c2', :'c2', false);

-- reset_soft: moves the current branch (HEAD tracks it) to the target commit.
SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.c1'));
SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD'),
    current_setting('vars.c1'),
    'reset_soft moves HEAD to the target commit'
);

-- reset_mixed: moves HEAD and clears the staging index.
SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.c2'));
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'staged.txt', 'wip'::bytea);
SELECT pggit.reset_mixed((current_setting('vars.repo_id')::int), current_setting('vars.c1'));
SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD'),
    current_setting('vars.c1'),
    'reset_mixed moves HEAD to the target commit'
);
SELECT is_empty(
    $$SELECT 1 FROM index_entries WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    'reset_mixed clears the staging index'
);

-- reset_file with the default target ('HEAD'): a staged modification is reverted
-- to the blob recorded in HEAD's commit. Regression test: the default used to be
-- treated as a literal commit hash, so the entry was dropped instead of restored.
SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.c1'));
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'CHANGED'::bytea);
SELECT pggit.reset_file((current_setting('vars.repo_id')::int), 'a.txt');
SELECT is(
    (SELECT blob_hash FROM index_entries
     WHERE repo_id = (current_setting('vars.repo_id')::int) AND path = 'a.txt'),
    current_setting('vars.blob_v1'),
    'reset_file with default HEAD restores the committed blob'
);

-- reset_file with the default target drops an index entry absent from HEAD's tree.
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'ghost.txt', 'boo'::bytea);
SELECT pggit.reset_file((current_setting('vars.repo_id')::int), 'ghost.txt');
SELECT is_empty(
    $$SELECT 1 FROM index_entries
      WHERE repo_id = (current_setting('vars.repo_id')::int) AND path = 'ghost.txt'$$,
    'reset_file removes an index entry not present in the target commit'
);

-- reset_file accepts an explicit commit hash and restores from that commit.
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'CHANGED-AGAIN'::bytea);
SELECT pggit.reset_file(
    (current_setting('vars.repo_id')::int), 'a.txt', current_setting('vars.c1'));
SELECT is(
    (SELECT blob_hash FROM index_entries
     WHERE repo_id = (current_setting('vars.repo_id')::int) AND path = 'a.txt'),
    current_setting('vars.blob_v1'),
    'reset_file restores from an explicit commit hash'
);

-- A ref name that does not resolve is treated as a literal commit hash; an
-- unknown hash yields no tree, so the file is dropped rather than erroring.
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'CHANGED'::bytea);
SELECT lives_ok(
    $$SELECT pggit.reset_file(
        (current_setting('vars.repo_id')::int), 'a.txt', 'deadbeef')$$,
    'reset_file tolerates an unresolvable target'
);

SELECT * FROM finish();
ROLLBACK;
