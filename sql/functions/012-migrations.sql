-- Path: /sql/functions/012-migrations.sql
-- pg_git schema migrations

CREATE TABLE pg_git.schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pg_git.get_current_schema_version()
RETURNS INTEGER AS $$
    SELECT COALESCE(MAX(version), 0) FROM pg_git.schema_migrations;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pg_git.run_migration(
    p_version INTEGER,
    p_up TEXT,
    p_down TEXT
) RETURNS VOID AS $$
BEGIN
    IF p_version > pg_git.get_current_schema_version() THEN
        EXECUTE p_up;
        INSERT INTO pg_git.schema_migrations (version) VALUES (p_version);
    END IF;
END;
$$ LANGUAGE plpgsql;