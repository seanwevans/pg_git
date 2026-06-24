-- Path: /test/sql/https_fetch_test.sql
-- Tests for pggit.http_fetch error handling

BEGIN;

SELECT plan(3);

-- Setup test repository
SELECT pggit.init_repository('test_repo', '/test/path') AS repo_id \gset
SELECT set_config('vars.repo_id', :'repo_id', false);

-- Successful fetch should return data
SELECT alike(
    encode(pggit.http_fetch((current_setting('vars.repo_id')::int), 'https://httpbin.org/get'), 'escape'),
    '%"url": "https://httpbin.org/get"%',
    'Successful fetch returns expected content'
);

-- Timeout scenario
SELECT throws_like(
    $$SELECT pggit.http_fetch((current_setting('vars.repo_id')::int), 'https://httpbin.org/delay/20')$$,
    'timed out',
    'Timeout raises error'
);

-- Certificate verification error scenario
SELECT throws_like(
    $$SELECT pggit.http_fetch((current_setting('vars.repo_id')::int), 'https://self-signed.badssl.com/')$$,
    'certificate verify failed',
    'Certificate error raises exception'
);

SELECT * FROM finish();
ROLLBACK;

