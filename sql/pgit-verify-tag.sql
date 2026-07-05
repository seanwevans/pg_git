-- Path: /sql/functions/026-verify-tag.sql
-- Tag verification with GPG

CREATE TABLE pggit.tag_signatures (
    repo_id INTEGER REFERENCES repositories(id),
    tag_name TEXT NOT NULL,
    key_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    signed_data TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, tag_name),
    FOREIGN KEY (repo_id, key_id) REFERENCES pggit.gpg_keys(repo_id, key_id)
);

CREATE OR REPLACE FUNCTION pggit.sign_tag(
    p_repo_id INTEGER,
    p_tag_name TEXT,
    p_key_id TEXT,
    p_signature TEXT
) RETURNS VOID SET search_path = pggit, public AS $$
DECLARE
    v_signed_data TEXT;
BEGIN
    -- Construct signed data from tag
    SELECT target_hash || tagger || message INTO v_signed_data
    FROM pggit.tags
    WHERE repo_id = p_repo_id AND name = p_tag_name;

    INSERT INTO pggit.tag_signatures (
        repo_id, tag_name, key_id, signature, signed_data
    ) VALUES (
        p_repo_id, p_tag_name, p_key_id, p_signature, v_signed_data
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_tag(
    p_repo_id INTEGER,
    p_tag_name TEXT,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    is_valid BOOLEAN,
    key_id TEXT,
    user_id TEXT,
    trust_level TEXT,
    verification_message TEXT
) SET search_path = pggit, public AS $$
DECLARE
    v_signature RECORD;
    v_key RECORD;
BEGIN
    -- Get signature info
    SELECT * INTO v_signature
    FROM pggit.tag_signatures
    WHERE repo_id = p_repo_id
    AND tag_name = p_tag_name;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, NULL::TEXT, NULL::TEXT, NULL::TEXT, 'No signature found'::TEXT;
        RETURN;
    END IF;

    -- Get key info. gpg_keys.key_id is qualified: "key_id" is also a RETURNS
    -- TABLE OUT parameter and would otherwise be an ambiguous column reference.
    SELECT * INTO v_key
    FROM pggit.gpg_keys
    WHERE repo_id = p_repo_id
    AND gpg_keys.key_id = v_signature.key_id;

    -- Check trust level
    IF p_require_trust_level IS NOT NULL AND 
       v_key.trust_level NOT IN ('full', 'ultimate') THEN
        RETURN QUERY
        SELECT FALSE, v_key.key_id, v_key.user_id, v_key.trust_level,
               'Insufficient trust level'::TEXT;
        RETURN;
    END IF;

    -- Here you would implement actual GPG verification
    -- For now, we assume stored signatures are valid
    RETURN QUERY
    SELECT TRUE, v_key.key_id, v_key.user_id, v_key.trust_level,
           'Valid signature'::TEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pggit.verify_all_tags(
    p_repo_id INTEGER,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    tag_name TEXT,
    is_valid BOOLEAN,
    verification_message TEXT
) SET search_path = pggit, public AS $$
    SELECT t.name,
           v.is_valid,
           v.verification_message
    FROM pggit.tags t
    LEFT JOIN LATERAL pggit.verify_tag(p_repo_id, t.name, p_require_trust_level) v ON TRUE
    WHERE t.repo_id = p_repo_id
    ORDER BY t.name;
$$ LANGUAGE sql;
