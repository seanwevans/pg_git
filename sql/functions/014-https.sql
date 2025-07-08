-- Path: /sql/functions/014-https.sql
-- pg_git HTTPS transport

CREATE TABLE pg_git.credentials (
    repo_id INTEGER REFERENCES repositories(id),
    host TEXT NOT NULL,
    username TEXT NOT NULL,
    password BYTEA NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, host)
);

CREATE OR REPLACE FUNCTION pg_git.store_credentials(
    p_repo_id INTEGER,
    p_host TEXT,
    p_username TEXT,
    p_password TEXT
) RETURNS VOID AS $$
DECLARE
    v_key TEXT := current_setting('pg_git.credential_key', true);
BEGIN
    INSERT INTO pg_git.credentials (repo_id, host, username, password)
    VALUES (
        p_repo_id,
        p_host,
        p_username,
        pgp_sym_encrypt(p_password, coalesce(v_key, 'pg_git_default_key'))
    )
    ON CONFLICT (repo_id, host) DO UPDATE
    SET username = EXCLUDED.username,
        password = pgp_sym_encrypt(p_password, coalesce(v_key, 'pg_git_default_key'));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.http_fetch(
    p_repo_id INTEGER,
    p_url TEXT,
    p_ref TEXT
) RETURNS BYTEA AS $$import base64
from urllib.parse import urlparse
import urllib.request

host = urlparse(p_url).hostname
key = plpy.execute("SELECT current_setting('pg_git.credential_key', true) AS k")[0]['k'] or 'pg_git_default_key'
cred = plpy.execute(
    "SELECT username, pgp_sym_decrypt(password, $1) AS pw FROM pg_git.credentials WHERE repo_id = $2 AND host = $3",
    [key, p_repo_id, host]
)

username = cred[0]['username'] if cred else None
password = cred[0]['pw'] if cred else None

req = urllib.request.Request(p_url)
if username:
    token = f"{username}:{password}".encode('utf-8')
    req.add_header('Authorization', 'Basic ' + base64.b64encode(token).decode('ascii'))

with urllib.request.urlopen(req) as resp:
    data = resp.read()

return data
$$ LANGUAGE plpython3u;

