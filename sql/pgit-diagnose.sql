-- Path: /sql/functions/024-diagnose.sql
-- Diagnostic information collection

CREATE TABLE pggit.diagnostic_reports (
    id SERIAL PRIMARY KEY,
    repo_id INTEGER REFERENCES repositories(id),
    report_type TEXT NOT NULL,
    report_data JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION pggit.collect_diagnostics(
    p_repo_id INTEGER
) RETURNS INTEGER SET search_path = pggit, public AS $$
DECLARE
    v_report_id INTEGER;
    v_report_data JSONB;
BEGIN
    -- Collect repository info. Object counts are scoped to this repository so
    -- the report reflects the requested repo rather than the whole install.
    WITH repo_info AS (
        SELECT r.*,
               (SELECT COUNT(*) FROM commits c WHERE c.repo_id = p_repo_id) as commit_count,
               (SELECT COUNT(*) FROM blobs b WHERE b.repo_id = p_repo_id) as blob_count,
               (SELECT COUNT(*) FROM trees t WHERE t.repo_id = p_repo_id) as tree_count,
               (SELECT COUNT(*) FROM refs rf WHERE rf.repo_id = p_repo_id) as ref_count
        FROM repositories r
        WHERE id = p_repo_id
    ),
    -- Collect size info (scoped to this repository).
    size_info AS (
        SELECT 'blobs' as type, pg_size_pretty(sum(octet_length(content))) as total_size
        FROM blobs
        WHERE repo_id = p_repo_id
        UNION ALL
        SELECT 'trees', pg_size_pretty(sum(octet_length(entries::text)))
        FROM trees
        WHERE repo_id = p_repo_id
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
        FROM pggit.verify_integrity(p_repo_id)
        GROUP BY status
    )
    -- Each section is built with a scalar subquery so the aggregated sections
    -- (sizes, errors) do not have to share a GROUP BY with the single-row
    -- repository/performance sections.
    SELECT jsonb_build_object(
        'repository', (SELECT row_to_json(repo_info) FROM repo_info),
        'sizes',      (SELECT jsonb_agg(to_jsonb(size_info)) FROM size_info),
        'performance',(SELECT to_jsonb(perf_metrics) FROM perf_metrics),
        'errors',     (SELECT jsonb_agg(to_jsonb(error_info)) FROM error_info)
    )
    INTO v_report_data;

    -- Store report
    INSERT INTO pggit.diagnostic_reports (repo_id, report_type, report_data)
    VALUES (p_repo_id, 'full', v_report_data)
    RETURNING id INTO v_report_id;

    RETURN v_report_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.get_diagnostic_report(
    p_report_id INTEGER
) RETURNS TABLE (
    section TEXT,
    content TEXT
) SET search_path = pggit, public AS $$
BEGIN
    RETURN QUERY
    WITH report AS (
        SELECT report_data
        FROM pggit.diagnostic_reports
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
    FROM report;
END;
$$ LANGUAGE plpgsql;
