-- Path: /test/sql/archive_test.sql
-- pg_git archive tests
-- Regression: create_archive errored on every call. The tar path hit an
-- operator-precedence bug (tf.path || '/' || e->>'name' parsed as
-- (... || e) ->> 'name'); the zip path used malformed bytea hex literals
-- ('\x50\x4B...' repeats the \x prefix).

BEGIN;

SELECT plan(5);

SELECT pggit.init_repository('archive_repo', '/archive/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'a.txt', 'hello'::bytea);
SELECT pggit.stage_file((current_setting('vars.repo_id')::int), 'b.txt', 'world'::bytea);
SELECT pggit.commit_index((current_setting('vars.repo_id')::int), 'tester', 'c1') AS c1 \gset
SELECT set_config('vars.c1', :'c1', false);

-- tar archive of HEAD is produced and non-empty.
SELECT cmp_ok(
    octet_length(pggit.create_archive((current_setting('vars.repo_id')::int))),
    '>', 0,
    'create_archive (tar, HEAD) produces a non-empty archive'
);

-- The tar stream embeds the file paths.
SELECT ok(
    position('a.txt' in encode(
        pggit.create_archive((current_setting('vars.repo_id')::int)), 'escape')) > 0,
    'tar archive contains the first file path'
);
SELECT ok(
    position('b.txt' in encode(
        pggit.create_archive((current_setting('vars.repo_id')::int)), 'escape')) > 0,
    'tar archive contains the second file path'
);

-- An explicit commit argument works too.
SELECT cmp_ok(
    octet_length(pggit.create_archive(
        (current_setting('vars.repo_id')::int), current_setting('vars.c1'), 'tar')),
    '>', 0,
    'create_archive accepts an explicit commit'
);

-- The zip archive begins with the PK\x03\x04 local-file-header magic.
SELECT is(
    substring(pggit.create_archive(
        (current_setting('vars.repo_id')::int), current_setting('vars.c1'), 'zip')
        from 1 for 4),
    '\x504b0304'::bytea,
    'zip archive starts with the PK signature'
);

SELECT * FROM finish();
ROLLBACK;
