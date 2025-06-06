-- Path: /test/sql/advanced_test.sql
-- pg_git advanced command tests

BEGIN;

SELECT plan(10);

-- Setup repository with an initial commit
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT pg_git.stage_file(:repo_id, 'test.txt', 'content'::bytea);
SELECT pg_git.commit_index(:repo_id, 'author', 'init commit');

-- Stash save
SELECT lives_ok(
    $$SELECT pg_git.stash_save(:repo_id, 'WIP changes')$$,
    'Can create stash'
);

SELECT results_eq(
    $$SELECT COUNT(*) FROM pg_git.stash WHERE repo_id = :repo_id$$,
    $$VALUES (1)$$,
    'Stash record created'
);

-- Stash pop
SELECT lives_ok(
    $$SELECT pg_git.stash_pop(:repo_id)$$,
    'Can apply stash'
);

SELECT is_empty(
    $$SELECT * FROM pg_git.stash WHERE repo_id = :repo_id$$,
    'Stash cleared after pop'
);

-- Pack refs
SELECT lives_ok(
    $$SELECT pg_git.pack_refs(:repo_id, TRUE)$$,
    'Can pack refs'
);

SELECT results_eq(
    $$SELECT COUNT(*) FROM pg_git.packed_refs WHERE repo_id = :repo_id$$,
    $$VALUES (1)$$,
    'Packed refs created'
);

-- Repack objects
SELECT lives_ok(
    $$SELECT * FROM pg_git.repack(:repo_id)$$,
    'Can repack objects'
);

-- Blame
SELECT results_eq(
    $$SELECT line_content FROM pg_git.blame(:repo_id, 'test.txt') LIMIT 1$$,
    $$VALUES ('content')$$,
    'Blame returns line content'
);

-- Grep
SELECT results_eq(
    $$SELECT line_content FROM pg_git.grep(:repo_id, 'content') LIMIT 1$$,
    $$VALUES ('content')$$,
    'Grep finds pattern'
);

SELECT * FROM finish();
ROLLBACK;

