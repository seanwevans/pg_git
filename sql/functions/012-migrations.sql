-- Path: /sql/functions/012-migrations.sql
-- pg_git schema migrations

CREATE TABLE pggit.schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.get_current_schema_version()
RETURNS INTEGER SET search_path = pggit, public AS $$
    SELECT COALESCE(MAX(version), 0) FROM pggit.schema_migrations;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION pggit.run_migration(
    p_version INTEGER,
    p_up TEXT,
    p_down TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
BEGIN
    IF p_version > pggit.get_current_schema_version() THEN
        EXECUTE p_up;
        INSERT INTO pggit.schema_migrations (version) VALUES (p_version);
    END IF;
END;$$ LANGUAGE plpgsql;
