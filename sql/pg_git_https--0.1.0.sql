-- pg_git_https 0.1.0 -- HTTPS transport for pg_git.
--
-- Optional companion extension. HTTPS fetching is the only part of the project
-- that needs plpython3u, and plpython3u is untrusted: it requires superuser and
-- is not offered on managed PostgreSQL (RDS, Cloud SQL, Supabase, Neon). Keeping
-- it here lets core pg_git install everywhere and lets self-hosted installs opt
-- in with CREATE EXTENSION pg_git_https.
--
-- This script is also where databases upgraded from pg_git 0.4.0 land. There
-- these objects already exist and were released from pg_git (but left in place,
-- with their stored credentials) by pg_git--0.4.0--0.5.0.sql, so the script
-- first adopts whatever is already there and then creates whatever is missing.

-- Take ownership of objects that predate the split, BEFORE creating anything.
-- On a fresh install none of them exist and every branch is a no-op. On a
-- database upgraded past pg_git 0.5.0 they exist but belong to no extension,
-- because pg_git--0.4.0--0.5.0.sql released them without dropping them so that
-- stored credentials would survive the move.
--
-- The order matters: while an extension script is running, PostgreSQL refuses
-- both CREATE ... IF NOT EXISTS and CREATE OR REPLACE against an object the
-- extension does not already own ("is not a member of extension"). Adopting
-- first makes the statements below legal in both cases.
DO $adopt$
DECLARE
    v_credentials CONSTANT oid := to_regclass('pggit.credentials');
    v_store CONSTANT oid := to_regprocedure('pggit.store_credentials(integer,text,text,text)');
    v_fetch CONSTANT oid := to_regprocedure('pggit.http_fetch(integer,text)');
BEGIN
    IF v_credentials IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_depend
        WHERE classid = 'pg_class'::regclass AND objid = v_credentials
          AND refclassid = 'pg_extension'::regclass AND deptype = 'e'
    ) THEN
        ALTER EXTENSION pg_git_https ADD TABLE pggit.credentials;
    END IF;

    IF v_store IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_depend
        WHERE classid = 'pg_proc'::regclass AND objid = v_store
          AND refclassid = 'pg_extension'::regclass AND deptype = 'e'
    ) THEN
        ALTER EXTENSION pg_git_https ADD FUNCTION pggit.store_credentials(INTEGER, TEXT, TEXT, TEXT);
    END IF;

    IF v_fetch IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_depend
        WHERE classid = 'pg_proc'::regclass AND objid = v_fetch
          AND refclassid = 'pg_extension'::regclass AND deptype = 'e'
    ) THEN
        ALTER EXTENSION pg_git_https ADD FUNCTION pggit.http_fetch(INTEGER, TEXT);
    END IF;
END
$adopt$;

CREATE TABLE IF NOT EXISTS pggit.credentials (
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

