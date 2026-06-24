-- Path: /sql/functions/014-https.sql
-- pg_git HTTPS transport

CREATE TABLE pggit.credentials (
    repo_id INTEGER REFERENCES pggit.repositories(id),
    host TEXT NOT NULL,
    username TEXT NOT NULL,
    password BYTEA NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, host)
);

CREATE OR REPLACE FUNCTION pggit.store_credentials(
    p_repo_id INTEGER,
    p_host TEXT,
    p_username TEXT,
    p_password TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_key TEXT := current_setting('pggit.credential_key', true);
BEGIN
    INSERT INTO pggit.credentials (repo_id, host, username, password)
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

CREATE OR REPLACE FUNCTION pggit.http_fetch(
    p_repo_id INTEGER,
    p_url TEXT
) RETURNS BYTEA SET search_path = pggit, public AS $$import base64
import ssl
from urllib.parse import urlparse
import urllib.request
import urllib.error

host = urlparse(p_url).hostname
key = plpy.execute("SELECT current_setting('pggit.credential_key', true) AS k")[0]['k'] or 'pg_git_default_key'
# Parameterized queries require a prepared plan; plpy.execute(query, x) treats x
# as a row limit, not bind parameters.
cred_plan = plpy.prepare(
    "SELECT username, pgp_sym_decrypt(password, $1) AS pw FROM pggit.credentials WHERE repo_id = $2 AND host = $3",
    ["text", "integer", "text"]
)
cred = plpy.execute(cred_plan, [key, p_repo_id, host])

context = ssl.create_default_context()

username = None
password = None
if len(cred) > 0:
    username = cred[0]['username']
    password = cred[0]['pw']

req = urllib.request.Request(p_url)
if username:
    token = f"{username}:{password}".encode('utf-8')
    req.add_header('Authorization', 'Basic ' + base64.b64encode(token).decode('ascii'))

try:
    with urllib.request.urlopen(req, context=context, timeout=10) as resp:
        data = resp.read()
except urllib.error.HTTPError as e:
    raise plpy.Error(f"Failed to fetch {p_url}: HTTP {e.code} {e.reason}")
except urllib.error.URLError as e:
    raise plpy.Error(f"Failed to fetch {p_url}: {e.reason}")

return data
$$ LANGUAGE plpython3u;
