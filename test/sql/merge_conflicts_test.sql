-- Path: /test/sql/merge_conflicts_test.sql
-- pg_git merge conflict detection tests

BEGIN;

SELECT plan(8);

-- can_auto_merge unit checks (three-way, blob hashes stand in for content).
SELECT ok(
    pggit.can_auto_merge('a', 'a', 'a'),
    'can_auto_merge: no side changed'
);
SELECT ok(
    pggit.can_auto_merge('a', 'b', 'a'),
    'can_auto_merge: only their side changed (take theirs)'
);
SELECT ok(
    pggit.can_auto_merge('b', 'a', 'a'),
    'can_auto_merge: only our side changed (take ours)'
);
SELECT ok(
    pggit.can_auto_merge('c', 'c', 'a'),
    'can_auto_merge: both sides made the same change'
);
SELECT ok(
    NOT pggit.can_auto_merge('b', 'c', 'a'),
    'can_auto_merge: both sides changed differently -> conflict'
);

-- Build a diverging history off a shared base:
--   base:   shared.txt='base', common.txt='keep'
--   ours:   shared.txt='ours',  common.txt unchanged, ours.txt added
--   theirs: shared.txt='their', common.txt unchanged, theirs.txt added
SELECT pggit.init_repository('conflict_repo', '/conflict/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'shared.txt', 'base'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'common.txt', 'keep'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'base') AS base \gset
SELECT set_config('vars.base', :'base', false);

-- ours
SELECT pggit.create_branch((current_setting('vars.repo_id')::int), 'ours', current_setting('vars.base'));
SELECT pggit.checkout_branch((current_setting('vars.repo_id')::int), 'ours');
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'shared.txt', 'ours'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'common.txt', 'keep'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'ours.txt', 'o'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'ours') AS ours \gset
SELECT set_config('vars.ours', :'ours', false);

-- theirs (branch off the base again)
SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.base'));
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'shared.txt', 'their'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'common.txt', 'keep'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'theirs.txt', 't'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'theirs') AS theirs \gset
SELECT set_config('vars.theirs', :'theirs', false);

-- Only shared.txt genuinely conflicts. common.txt is unchanged on both sides,
-- and ours.txt / theirs.txt are one-sided additions (auto-mergeable).
SELECT results_eq(
    $$SELECT path, conflict_type
      FROM pggit.detect_conflicts(
          (current_setting('vars.repo_id')::int),
          current_setting('vars.ours'),
          current_setting('vars.theirs'))
      ORDER BY path$$,
    $$VALUES ('shared.txt', 'content')$$,
    'detect_conflicts reports only the divergently-edited file'
);

-- Identical commits produce no conflicts.
SELECT is_empty(
    $$SELECT * FROM pggit.detect_conflicts(
          (current_setting('vars.repo_id')::int),
          current_setting('vars.ours'),
          current_setting('vars.ours'))$$,
    'detect_conflicts finds nothing when both sides are identical'
);

-- add/add: two branches independently add the same path with different content.
SELECT pggit.checkout_branch((current_setting('vars.repo_id')::int), 'ours');
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'shared.txt', 'ours'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'common.txt', 'keep'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'ours.txt', 'o'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'new.txt', 'ours-new'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'ours+new') AS ours2 \gset
SELECT set_config('vars.ours2', :'ours2', false);

SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.theirs'));
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'shared.txt', 'their'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'common.txt', 'keep'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'theirs.txt', 't'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'new.txt', 'their-new'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'their+new') AS theirs2 \gset
SELECT set_config('vars.theirs2', :'theirs2', false);

SELECT results_eq(
    $$SELECT conflict_type
      FROM pggit.detect_conflicts(
          (current_setting('vars.repo_id')::int),
          current_setting('vars.ours2'),
          current_setting('vars.theirs2'))
      WHERE path = 'new.txt'$$,
    $$VALUES ('add_add')$$,
    'detect_conflicts classifies an independent same-path add as add_add'
);

SELECT * FROM finish();
ROLLBACK;
