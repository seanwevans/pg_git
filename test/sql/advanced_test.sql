-- Path: /test/sql/advanced_test.sql
-- pg_git advanced command tests

BEGIN;

SELECT plan(9);

-- Setup repository with an initial commit
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'test.txt', 'content'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'author', 'init commit');

-- Stash save
SELECT lives_ok(
    $$SELECT pggit.stash_save((current_setting('vars.repo_id')::int), 'WIP changes')$$,
    'Can create stash'
);

SELECT results_eq(
    $$SELECT COUNT(*) FROM pggit.stash WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES (1::bigint)$$,
    'Stash record created'
);

-- Stash pop
SELECT lives_ok(
    $$SELECT pggit.stash_pop((current_setting('vars.repo_id')::int))$$,
    'Can apply stash'
);

SELECT is_empty(
    $$SELECT * FROM pggit.stash WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    'Stash cleared after pop'
);

-- Pack refs
SELECT lives_ok(
    $$SELECT pggit.pack_refs((current_setting('vars.repo_id')::int), TRUE)$$,
    'Can pack refs'
);

SELECT results_eq(
    $$SELECT COUNT(*) FROM pggit.packed_refs WHERE repo_id = (current_setting('vars.repo_id')::int)$$,
    $$VALUES (1::bigint)$$,
    'Packed refs created'
);

-- Repack objects
SELECT lives_ok(
    $$SELECT * FROM pggit.repack((current_setting('vars.repo_id')::int))$$,
    'Can repack objects'
);

-- Blame
SELECT results_eq(
    $$SELECT line_content FROM pggit.blame((current_setting('vars.repo_id')::int), 'test.txt') LIMIT 1$$,
    $$VALUES ('content')$$,
    'Blame returns line content'
);

-- Grep
SELECT results_eq(
    $$SELECT line_content FROM pggit.grep((current_setting('vars.repo_id')::int), 'content') LIMIT 1$$,
    $$VALUES ('content')$$,
    'Grep finds pattern'
);

SELECT * FROM finish();
ROLLBACK;

