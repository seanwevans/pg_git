-- Path: /sql/functions/024-diagnose.sql
-- Diagnostic information collection

CREATE TABLE pg_git.diagnostic_reports (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    report_type TEXT NOT NULL,
    report_data JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pg_git.collect_diagnostics(
    p_repo_id INTEGER
) RETURNS INTEGER AS $$
DECLARE
    v_report_id INTEGER;
    v_report_data JSONB;
BEGIN
    -- Collect repository info
    WITH repo_info AS (
        SELECT r.*,
               (SELECT COUNT(*) FROM commits c) as commit_count,
               (SELECT COUNT(*) FROM blobs b) as blob_count,
               (SELECT COUNT(*) FROM trees t) as tree_count,
               (SELECT COUNT(*) FROM refs rf) as ref_count
        FROM repositories r
        WHERE id = p_repo_id
    ),
    -- Collect size info
    size_info AS (
        SELECT 'blobs' as type, pg_size_pretty(sum(octet_length(content))) as total_size
        FROM blobs
        UNION ALL
        SELECT 'trees', pg_size_pretty(sum(octet_length(entries::text)))
        FROM trees
    ),
    -- Collect performance metrics
    perf_metrics AS (
        SELECT obj_description(oid) as last_gc_run
        FROM pg_class
        WHERE relname = 'blobs'
    ),
    -- Collect error info
    error_info AS (
        SELECT status, count(*) as count
        FROM pg_git.verify_integrity(p_repo_id)
        GROUP BY status
    )
    SELECT jsonb_build_object(
        'repository', row_to_json(repo_info),
        'sizes', jsonb_agg(to_jsonb(size_info)),
        'performance', to_jsonb(perf_metrics),
        'errors', jsonb_agg(to_jsonb(error_info)),
        'configs', (
            SELECT jsonb_object_agg(key, value)
            FROM pg_git.config
            WHERE repo_id = p_repo_id
        )
    )
    INTO v_report_data
    FROM repo_info, size_info, perf_metrics, error_info;

    -- Store report
    INSERT INTO pg_git.diagnostic_reports (repo_id, report_type, report_data)
    VALUES (p_repo_id, 'full', v_report_data)
    RETURNING id INTO v_report_id;

    RETURN v_report_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.get_diagnostic_report(
    p_report_id INTEGER
) RETURNS TABLE (
    section TEXT,
    content TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH report AS (
        SELECT report_data
        FROM pg_git.diagnostic_reports
        WHERE id = p_report_id
    )
    SELECT 'Repository Info' as section,
           jsonb_pretty(report_data->'repository') as content
    FROM report
    UNION ALL
    SELECT 'Storage Usage',
           jsonb_pretty(report_data->'sizes')
    FROM report
    UNION ALL
    SELECT 'Performance Metrics',
           jsonb_pretty(report_data->'performance')
    FROM report
    UNION ALL
    SELECT 'Error Summary',
           jsonb_pretty(report_data->'errors')
    FROM report
    UNION ALL
    SELECT 'Configuration',
           jsonb_pretty(report_data->'configs')
    FROM report;
END;
$$ LANGUAGE plpgsql;