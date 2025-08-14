-- Path: /test/sql/https_fetch_test.sql
-- Tests for pg_git.http_fetch error handling

BEGIN;

SELECT plan(3);

-- Setup test repository
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset

-- Successful fetch should return data
SELECT like(
    encode(pg_git.http_fetch(:repo_id, 'https://httpbin.org/get'), 'escape'),
    '%"url": "https://httpbin.org/get"%',
    'Successful fetch returns expected content'
);

-- Timeout scenario
SELECT throws_like(
    $$SELECT pg_git.http_fetch(:repo_id, 'https://httpbin.org/delay/20')$$,
    'timed out',
    'Timeout raises error'
);

-- Certificate verification error scenario
SELECT throws_like(
    $$SELECT pg_git.http_fetch(:repo_id, 'https://self-signed.badssl.com/')$$,
    'certificate verify failed',
    'Certificate error raises exception'
);

SELECT * FROM finish();
ROLLBACK;

