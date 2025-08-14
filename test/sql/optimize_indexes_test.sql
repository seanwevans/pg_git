-- Path: /test/sql/optimize_indexes_test.sql
-- pg_git optimize indexes tests

BEGIN;

SELECT plan(3);

-- Initialize repository
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset;

-- Determine expected number of indexes
SELECT count(*) AS total_indexes
FROM pg_indexes i
JOIN pg_tables t ON i.tablename = t.tablename
WHERE t.schemaname = 'pg_git'
\gset

-- Successful reindex run
SELECT results_eq(
    $$SELECT count(*) FROM pg_git.optimize_indexes(:repo_id)$$,
    $$SELECT :total_indexes$$,
    'Returned one row per index'
);

SELECT is_empty(
    $$SELECT * FROM pg_git.optimize_indexes(:repo_id) WHERE NOT success$$,
    'All indexes reindexed successfully'
);

-- Setup failure to simulate errors
CREATE OR REPLACE FUNCTION fail_all_reindex() RETURNS event_trigger AS $$
BEGIN
    RAISE EXCEPTION 'simulated failure';
END;
$$ LANGUAGE plpgsql;

CREATE EVENT TRIGGER fail_reindex
    ON ddl_command_start
    WHEN TAG IN ('REINDEX INDEX')
    EXECUTE PROCEDURE fail_all_reindex();

-- Failure scenario run
SELECT is_empty(
    $$SELECT * FROM pg_git.optimize_indexes(:repo_id) WHERE success$$,
    'Reindex failures captured'
);

DROP EVENT TRIGGER fail_reindex;
DROP FUNCTION fail_all_reindex();

SELECT * FROM finish();
ROLLBACK;
