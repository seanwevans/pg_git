-- Path: /test/sql/https_fetch_test.sql
-- Tests for pg_git.http_fetch authentication handling

BEGIN;

SELECT plan(2);

-- Setup test repository
SELECT pg_git.init_repository('test_repo', '/test/path') AS repo_id \gset

-- Unauthenticated fetch should succeed without stored credentials
SELECT like(
    encode(pg_git.http_fetch(:repo_id, 'https://httpbin.org/get'), 'escape'),
    '%"url": "https://httpbin.org/get"%',
    'Unauthenticated fetch returns expected content'
);

-- Authenticated fetch using stored credentials
SET pg_git.credential_key = 'test_key';
SELECT pg_git.store_credentials(:repo_id, 'httpbin.org', 'user', 'pass');
SELECT like(
    encode(pg_git.http_fetch(:repo_id, 'https://httpbin.org/basic-auth/user/pass'), 'escape'),
    '%"authenticated": true%',
    'Authenticated fetch returns expected content'
);

SELECT * FROM finish();
ROLLBACK;
