-- Path: /test/sql/ambiguous_column_regression_test.sql
-- Regression coverage for exported functions that previously raised
-- "column reference ... is ambiguous" (a RETURNS TABLE OUT parameter shadowing
-- an identically named table/CTE column): whatchanged, merge_trees,
-- verify_commit, verify_tag, verify_all_tags.

BEGIN;

SELECT plan(8);

SELECT pggit.init_repository('amb_repo', '/amb/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Linear history: c1 then c2 (a.txt modified, b.txt added). keep.txt is part of
-- the base so the merge_trees case below has a file that is unchanged on both
-- sides (and must therefore be omitted from the conflict report).
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'one'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'keep.txt', 'k'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c1') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);
SELECT tree_hash AS base_tree FROM commits WHERE hash = :'c1' \gset
SELECT set_config('vars.base_tree', :'base_tree', false);

SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'two'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'b.txt', 'new'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c2') AS c2 \gset
SELECT set_config('vars.c2', :'c2', false);

-- whatchanged: reports file changes across history (previously errored).
SELECT isnt_empty(
    $$SELECT * FROM pggit.whatchanged((current_setting('vars.repo_id')::int))$$,
    'whatchanged returns rows'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pggit.whatchanged((current_setting('vars.repo_id')::int)) w
            WHERE w.path = 'b.txt' AND w.change_type = 'A'),
    'whatchanged reports b.txt as added'
);
SELECT ok(
    (SELECT bool_and(w.path = 'a.txt')
     FROM pggit.whatchanged(
         (current_setting('vars.repo_id')::int), NULL, 'HEAD', ARRAY['a.txt']) w),
    'whatchanged honours a path filter'
);

-- merge_trees: divergent edits to a.txt conflict; keep.txt is unchanged.
SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.c1'));
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'ours'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'keep.txt', 'k'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'ours') AS ours \gset
SELECT tree_hash AS ours_tree FROM commits WHERE hash = :'ours' \gset
SELECT set_config('vars.ours_tree', :'ours_tree', false);

SELECT pggit.reset_soft((current_setting('vars.repo_id')::int), current_setting('vars.c1'));
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'theirs'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'keep.txt', 'k'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'theirs') AS theirs \gset
SELECT tree_hash AS theirs_tree FROM commits WHERE hash = :'theirs' \gset
SELECT set_config('vars.theirs_tree', :'theirs_tree', false);

SELECT results_eq(
    $$SELECT path, stage, status FROM pggit.merge_trees(
        current_setting('vars.base_tree'),
        current_setting('vars.ours_tree'),
        current_setting('vars.theirs_tree'))$$,
    $$VALUES ('a.txt', 2, 'both modified')$$,
    'merge_trees flags the divergent file and omits the unchanged one'
);

-- GPG verification: sign a commit and a tag, then verify.
SELECT pggit.add_gpg_key(
    (current_setting('vars.repo_id')::int), 'KEY1', 'PUBKEY', 'tester <t@e>', 'full');
SELECT pggit.sign_commit(
    (current_setting('vars.repo_id')::int), current_setting('vars.c1'), 'KEY1', 'SIG');
SELECT pggit.create_tag(
    (current_setting('vars.repo_id')::int), 'v1', current_setting('vars.c1'), 'tester', 'msg');
SELECT pggit.sign_tag((current_setting('vars.repo_id')::int), 'v1', 'KEY1', 'SIG');

SELECT results_eq(
    $$SELECT is_valid, key_id FROM pggit.verify_commit(
        (current_setting('vars.repo_id')::int), current_setting('vars.c1'))$$,
    $$VALUES (true, 'KEY1')$$,
    'verify_commit validates a signed commit'
);
SELECT results_eq(
    $$SELECT is_valid, verification_message FROM pggit.verify_commit(
        (current_setting('vars.repo_id')::int), current_setting('vars.c2'))$$,
    $$VALUES (false, 'No signature found')$$,
    'verify_commit reports an unsigned commit as invalid'
);
SELECT is(
    (SELECT is_valid FROM pggit.verify_tag(
        (current_setting('vars.repo_id')::int), 'v1')),
    true,
    'verify_tag validates a signed tag'
);
SELECT results_eq(
    $$SELECT tag_name, is_valid FROM pggit.verify_all_tags(
        (current_setting('vars.repo_id')::int))$$,
    $$VALUES ('v1', true)$$,
    'verify_all_tags reports every tag'
);

SELECT * FROM finish();
ROLLBACK;
