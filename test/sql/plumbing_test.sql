-- Path: /test/sql/plumbing_test.sql
-- pg_git plumbing/traversal command tests
-- Regression coverage: these commands previously errored at runtime
-- (ambiguous OUT-parameter columns; wrong-arity internal calls).

BEGIN;

SELECT plan(9);

SELECT pggit.init_repository('plumb_repo', '/plumb/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Two commits on one line of history.
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', E'l1\nl2'::bytea)
    AS blob1 \gset
SELECT set_config('vars.blob1', :'blob1', false);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c1') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);

SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', E'l1\nl2\nl3'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c2') AS c2 \gset
SELECT set_config('vars.c2', :'c2', false);
SELECT tree_hash AS tree2 FROM commits WHERE hash = :'c2' \gset
SELECT set_config('vars.tree2', :'tree2', false);

-- cat_file: a staged blob is reported as a blob with its content.
SELECT is(
    (SELECT object_type FROM pggit.cat_file(
        (current_setting('vars.repo_id')::int), current_setting('vars.blob1'))),
    'blob',
    'cat_file reports a blob object type'
);
SELECT is(
    (SELECT content FROM pggit.cat_file(
        (current_setting('vars.repo_id')::int), current_setting('vars.blob1'))),
    E'l1\nl2',
    'cat_file returns the blob content'
);
SELECT is(
    (SELECT object_type FROM pggit.cat_file(
        (current_setting('vars.repo_id')::int), current_setting('vars.c2'))),
    'commit',
    'cat_file reports a commit object type'
);

-- ls_tree (recursive): the tree holds a single blob entry, a.txt.
SELECT results_eq(
    $$SELECT type, path FROM pggit.ls_tree(
        (current_setting('vars.repo_id')::int), current_setting('vars.tree2'), true)$$,
    $$VALUES ('blob', 'a.txt')$$,
    'ls_tree lists the tree entries'
);

-- rev_list: initial commit + c1 + c2 are reachable from c2.
SELECT is(
    (SELECT count(*)::int FROM pggit.rev_list(
        (current_setting('vars.repo_id')::int), current_setting('vars.c2'))),
    3,
    'rev_list walks the full ancestry from a commit'
);
SELECT ok(
    EXISTS (SELECT 1 FROM pggit.rev_list(
        (current_setting('vars.repo_id')::int), current_setting('vars.c2')) rl
        WHERE rl.hash = current_setting('vars.c1')),
    'rev_list includes an ancestor commit'
);

-- merge_base: c1 is an ancestor of c2, so it is their merge base.
SELECT is(
    pggit.merge_base(
        (current_setting('vars.repo_id')::int),
        current_setting('vars.c1'),
        current_setting('vars.c2')),
    current_setting('vars.c1'),
    'merge_base returns the common ancestor'
);

-- bisect commands are callable end-to-end (they consume rev_list).
SELECT lives_ok(
    $$SELECT pggit.bisect_start(
        (current_setting('vars.repo_id')::int),
        current_setting('vars.c2'),
        current_setting('vars.c1'))$$,
    'bisect_start runs without error'
);
SELECT lives_ok(
    $$SELECT pggit.bisect_good((current_setting('vars.repo_id')::int))$$,
    'bisect_good runs without error'
);

SELECT * FROM finish();
ROLLBACK;
