-- Path: /test/sql/diagnose_test.sql
-- pg_git diagnostics tests
-- Regression: collect_diagnostics referenced a non-existent pggit.config table
-- (and mixed aggregates without a GROUP BY), so it errored on every call. It
-- also counted objects across all repositories rather than the requested one.

BEGIN;

SELECT plan(5);

-- Two repositories with different object counts, to prove per-repo scoping.
SELECT pggit.init_repository('diag_one', '/diag/one') AS r1 \gset
SELECT set_config('vars.r1', :'r1', false);
SELECT pggit.init_repository('diag_two', '/diag/two') AS r2 \gset
SELECT set_config('vars.r2', :'r2', false);

-- r1: a single commit (plus the initial commit created by init).
SELECT pggit.stage_file((current_setting('vars.r1')::int), 'a.txt', 'aaa'::bytea);
SELECT pggit.commit_index((current_setting('vars.r1')::int), 'tester', 'r1c1');

-- r2: two extra commits and more blobs.
SELECT pggit.stage_file((current_setting('vars.r2')::int), 'x.txt', 'xxx'::bytea);
SELECT pggit.commit_index((current_setting('vars.r2')::int), 'tester', 'r2c1');
SELECT pggit.stage_file((current_setting('vars.r2')::int), 'y.txt', 'yyy'::bytea);
SELECT pggit.commit_index((current_setting('vars.r2')::int), 'tester', 'r2c2');

-- collect_diagnostics runs and returns a report id.
SELECT pggit.collect_diagnostics((current_setting('vars.r1')::int)) AS report_id \gset
SELECT set_config('vars.report_id', :'report_id', false);
SELECT isnt(
    (SELECT :'report_id'::int), NULL,
    'collect_diagnostics returns a report id'
);

-- A report row was stored.
SELECT is(
    (SELECT count(*)::int FROM pggit.diagnostic_reports
     WHERE id = (current_setting('vars.report_id')::int)),
    1,
    'collect_diagnostics stores the report'
);

-- Counts are scoped to r1 (init commit + one commit == 2), not the whole install.
SELECT is(
    (SELECT (report_data->'repository'->>'commit_count')::int
     FROM pggit.diagnostic_reports WHERE id = (current_setting('vars.report_id')::int)),
    2,
    'commit_count is scoped to the target repository'
);
SELECT is(
    (SELECT (report_data->'repository'->>'blob_count')::int
     FROM pggit.diagnostic_reports WHERE id = (current_setting('vars.report_id')::int)),
    1,
    'blob_count is scoped to the target repository'
);

-- get_diagnostic_report renders the stored sections.
SELECT isnt_empty(
    $$SELECT * FROM pggit.get_diagnostic_report((current_setting('vars.report_id')::int))
      WHERE section = 'Repository Info'$$,
    'get_diagnostic_report returns the repository section'
);

SELECT * FROM finish();
ROLLBACK;
