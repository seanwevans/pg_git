-- Path: /sql/functions/028-instaweb.sql
-- Instaweb functionality for repository browsing

CREATE TABLE pg_git.instaweb_config (
    repo_id INTEGER REFERENCES repositories(id),
    port INTEGER NOT NULL DEFAULT 1234,
    host TEXT NOT NULL DEFAULT 'localhost',
    theme TEXT NOT NULL DEFAULT 'default',
    auth_required BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id)
);

CREATE TABLE pg_git.instaweb_users (
    repo_id INTEGER REFERENCES repositories(id),
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_admin BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, username)
);

CREATE TABLE pg_git.instaweb_sessions (
    repo_id INTEGER REFERENCES repositories(id),
    session_id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    FOREIGN KEY (repo_id, username) REFERENCES pg_git.instaweb_users(repo_id, username)
);

-- HTML Template for repository view
CREATE OR REPLACE FUNCTION pg_git.get_instaweb_template(
    p_repo_id INTEGER
) RETURNS TEXT AS $$
BEGIN
    RETURN '
<!DOCTYPE html>
<html>
<head>
    <title>{{repo_name}} - pg_git web</title>
    <style>
        body { font-family: sans-serif; margin: 0; padding: 20px; }
        .header { background: #f0f0f0; padding: 10px; }
        .commit-list { list-style: none; padding: 0; }
        .commit { border-bottom: 1px solid #eee; padding: 10px 0; }
        .file-tree { margin: 20px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>{{repo_name}}</h1>
        <div class="nav">
            <a href="/tree">Files</a> |
            <a href="/commits">History</a> |
            <a href="/branches">Branches</a>
        </div>
    </div>
    <div class="content">
        {{content}}
    </div>
</body>
</html>';
END;
$$ LANGUAGE plpgsql;

-- Generate repository view
CREATE OR REPLACE FUNCTION pg_git.generate_repo_view(
    p_repo_id INTEGER,
    p_ref TEXT DEFAULT 'HEAD'
) RETURNS TEXT AS $$
DECLARE
    v_template TEXT;
    v_content TEXT;
    v_repo_name TEXT;
BEGIN
    SELECT name INTO v_repo_name
    FROM repositories
    WHERE id = p_repo_id;

    -- Get history
    WITH commit_list AS (
        SELECT c.hash, 
               c.message,
               c.author,
               c.timestamp
        FROM pg_git.get_log(p_repo_id, 10) c
    )
    SELECT string_agg(
        format(
            '<div class="commit">
                <div class="commit-hash">%s</div>
                <div class="commit-message">%s</div>
                <div class="commit-author">%s</div>
                <div class="commit-date">%s</div>
            </div>',
            substr(hash, 1, 8),
            message,
            author,
            timestamp
        ),
        E'\n'
    ) INTO v_content
    FROM commit_list;

    -- Get template and replace placeholders
    v_template := pg_git.get_instaweb_template(p_repo_id);
    v_template := replace(v_template, '{{repo_name}}', v_repo_name);
    v_template := replace(v_template, '{{content}}', v_content);

    RETURN v_template;
END;
$$ LANGUAGE plpgsql;

-- Start instaweb server
CREATE OR REPLACE FUNCTION pg_git.start_instaweb(
    p_repo_id INTEGER,
    p_port INTEGER DEFAULT 1234,
    p_host TEXT DEFAULT 'localhost',
    p_auth_required BOOLEAN DEFAULT FALSE
) RETURNS TEXT AS $$
BEGIN
    INSERT INTO pg_git.instaweb_config (
        repo_id, port, host, auth_required
    ) VALUES (
        p_repo_id, p_port, p_host, p_auth_required
    )
    ON CONFLICT (repo_id) DO UPDATE
    SET port = p_port,
        host = p_host,
        auth_required = p_auth_required;

    -- In a real implementation, this would start a web server
    -- For now, just return the URL
    RETURN format('http://%s:%s', p_host, p_port);
END;
$$ LANGUAGE plpgsql;

-- Stop instaweb server
CREATE OR REPLACE FUNCTION pg_git.stop_instaweb(
    p_repo_id INTEGER
) RETURNS VOID AS $$
BEGIN
    DELETE FROM pg_git.instaweb_config
    WHERE repo_id = p_repo_id;
    
    -- Clean up sessions
    DELETE FROM pg_git.instaweb_sessions
    WHERE repo_id = p_repo_id;
END;
$$ LANGUAGE plpgsql;
