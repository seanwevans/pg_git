-- Path: /sql/functions/014-https.sql
-- pg_git HTTPS transport

CREATE TABLE pg_git.credentials (
    repo_id INTEGER REFERENCES repositories(id),
    host TEXT NOT NULL,
    username TEXT NOT NULL,
    password TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, host)
);

CREATE OR REPLACE FUNCTION pg_git.store_credentials(
    p_repo_id INTEGER,
    p_host TEXT,
    p_username TEXT,
    p_password TEXT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pg_git.credentials (repo_id, host, username, password)
    VALUES (p_repo_id, p_host, p_username, pgcrypto.crypt(p_password, pgcrypto.gen_salt('bf')))
    ON CONFLICT (repo_id, host) DO UPDATE
    SET username = EXCLUDED.username,
        password = pgcrypto.crypt(p_password, pgcrypto.gen_salt('bf'));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.http_fetch(
    p_repo_id INTEGER,
    p_url TEXT,
    p_ref TEXT
) RETURNS BYTEA AS $$
DECLARE
    v_host TEXT;
    v_username TEXT;
    v_password TEXT;
    v_response BYTEA;
BEGIN
    -- Extract host from URL
    v_host := regexp_replace(p_url, '^https?://([^/]+).*', '\1');
    
    -- Get credentials if stored
    SELECT username, password 
    INTO v_username, v_password
    FROM pg_git.credentials
    WHERE repo_id = p_repo_id AND host = v_host;
    
    -- Here you would implement actual HTTPS request
    -- This is a placeholder for the actual implementation
    RAISE NOTICE 'Would fetch % with credentials for %', p_url, v_host;
    
    RETURN v_response;
END;
$$ LANGUAGE plpgsql;