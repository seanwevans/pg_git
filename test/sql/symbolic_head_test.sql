-- Path: /test/sql/symbolic_head_test.sql
-- pg_git symbolic HEAD tests
-- HEAD is a symbolic ref that tracks the current branch. Committing advances
-- only that branch (or a detached HEAD), not every branch sharing the old
-- commit -- the behaviour this redesign fixes.

BEGIN;

SELECT plan(12);

SELECT pggit.init_repository('sym_repo', '/sym/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Initial commit on master.
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'f.txt', 'one'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c1') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);

-- Fresh repos start on master, and HEAD resolves to its tip.
SELECT is(
    pggit.current_branch((current_setting('vars.repo_id')::int)),
    'master',
    'a new repository is on master'
);
SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD'),
    current_setting('vars.c1'),
    'HEAD resolves to the current branch tip'
);

-- A branch created at HEAD shares the commit but is not current.
SELECT pggit.create_branch((current_setting('vars.repo_id')::int), 'feature');
SELECT is(
    (SELECT commit_hash FROM refs
     WHERE repo_id = (current_setting('vars.repo_id')::int) AND name = 'feature'),
    current_setting('vars.c1'),
    'a new branch is created at HEAD'
);
SELECT results_eq(
    $$SELECT name FROM pggit.list_branches((current_setting('vars.repo_id')::int))
      WHERE is_current$$,
    $$VALUES ('master')$$,
    'only the checked-out branch is current, even when branches share a commit'
);
-- creating a branch must not move HEAD off master
SELECT is(
    pggit.current_branch((current_setting('vars.repo_id')::int)),
    'master',
    'create_branch does not switch the current branch'
);

-- Switch to feature and commit: feature advances, master stays put.
SELECT pggit.checkout_branch((current_setting('vars.repo_id')::int), 'feature');
SELECT is(
    pggit.current_branch((current_setting('vars.repo_id')::int)),
    'feature',
    'checkout switches the current branch'
);

SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'f.txt', 'two'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c2') AS c2 \gset
SELECT set_config('vars.c2', :'c2', false);

SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD'),
    current_setting('vars.c2'),
    'committing advances the current branch'
);
SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'feature'),
    current_setting('vars.c2'),
    'feature moved to the new commit'
);
-- The crux: master did NOT move even though it shared c1 with feature.
SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'master'),
    current_setting('vars.c1'),
    'master is untouched by a commit on feature'
);

-- Detached HEAD: committing moves HEAD itself, no branch.
SELECT pggit.set_head_detached((current_setting('vars.repo_id')::int), current_setting('vars.c1'));
SELECT is(
    pggit.current_branch((current_setting('vars.repo_id')::int)),
    NULL,
    'set_head_detached leaves no current branch'
);

SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'f.txt', 'three'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c3') AS c3 \gset
SELECT set_config('vars.c3', :'c3', false);

SELECT is(
    pggit.resolve_ref((current_setting('vars.repo_id')::int), 'HEAD'),
    current_setting('vars.c3'),
    'a detached HEAD advances itself on commit'
);
-- Neither branch moved during the detached commit.
SELECT results_eq(
    $$SELECT pggit.resolve_ref((current_setting('vars.repo_id')::int), 'master'),
             pggit.resolve_ref((current_setting('vars.repo_id')::int), 'feature')$$,
    $$SELECT current_setting('vars.c1'), current_setting('vars.c2')$$,
    'branches are untouched while HEAD is detached'
);

SELECT * FROM finish();
ROLLBACK;
