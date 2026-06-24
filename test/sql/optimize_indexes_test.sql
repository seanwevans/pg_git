-- Path: /test/sql/optimize_indexes_test.sql
-- pg_git optimize indexes tests

BEGIN;

SELECT plan(3);

-- Initialize repository
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Determine expected number of indexes
SELECT count(*) AS total_indexes
FROM pg_indexes i
JOIN pg_tables t ON i.schemaname = t.schemaname AND i.tablename = t.tablename
WHERE t.schemaname = 'pggit'
\gset
SELECT set_config('vars.total_indexes', :'total_indexes', false);

-- Successful reindex run
SELECT results_eq(
    $$SELECT count(*)::int FROM pggit.optimize_indexes((current_setting('vars.repo_id')::int))$$,
    $$SELECT (current_setting('vars.total_indexes')::int)$$,
    'Returned one row per index'
);

SELECT is_empty(
    $$SELECT * FROM pggit.optimize_indexes((current_setting('vars.repo_id')::int)) WHERE NOT success$$,
    'All indexes reindexed successfully'
);

-- Simulate reindex errors: an unprivileged role owns none of the pggit indexes,
-- so every REINDEX it attempts is rejected and captured with success = FALSE.
-- The function runs as that role; the captured rows are asserted as the test
-- role so pgTAP's own bookkeeping is unaffected.
CREATE ROLE pggit_test_unpriv;
GRANT USAGE ON SCHEMA pggit TO pggit_test_unpriv;

SET LOCAL ROLE pggit_test_unpriv;
CREATE TEMP TABLE optimize_results AS
    SELECT * FROM pggit.optimize_indexes((current_setting('vars.repo_id')::int));
RESET ROLE;

-- Failure scenario run
SELECT is_empty(
    $$SELECT * FROM optimize_results WHERE success$$,
    'Reindex failures captured'
);

SELECT * FROM finish();
ROLLBACK;
