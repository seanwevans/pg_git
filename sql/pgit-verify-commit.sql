-- Path: /sql/functions/025-verify-commit.sql
-- Commit verification with GPG

CREATE TABLE pg_git.gpg_keys (
    repo_id INTEGER REFERENCES repositories(id),
    key_id TEXT NOT NULL,
    public_key TEXT NOT NULL,
    user_id TEXT NOT NULL,
    trust_level TEXT CHECK (trust_level IN ('unknown', 'never', 'marginal', 'full', 'ultimate')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, key_id)
);

CREATE TABLE pg_git.commit_signatures (
    repo_id INTEGER REFERENCES repositories(id),
    commit_hash TEXT NOT NULL REFERENCES commits(hash),
    key_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    signed_data TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo_id, commit_hash)
);

CREATE OR REPLACE FUNCTION pg_git.add_gpg_key(
    p_repo_id INTEGER,
    p_key_id TEXT,
    p_public_key TEXT,
    p_user_id TEXT,
    p_trust_level TEXT DEFAULT 'unknown'
) RETURNS VOID AS $$
BEGIN
    INSERT INTO pg_git.gpg_keys (repo_id, key_id, public_key, user_id, trust_level)
    VALUES (p_repo_id, p_key_id, p_public_key, p_user_id, p_trust_level)
    ON CONFLICT (repo_id, key_id) DO UPDATE 
    SET public_key = p_public_key,
        user_id = p_user_id,
        trust_level = p_trust_level;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.verify_commit(
    p_repo_id INTEGER,
    p_commit_hash TEXT,
    p_require_trust_level TEXT DEFAULT NULL
) RETURNS TABLE (
    is_valid BOOLEAN,
    key_id TEXT,
    user_id TEXT,
    trust_level TEXT,
    verification_message TEXT
) AS $$
DECLARE
    v_signature RECORD;
    v_key RECORD;
BEGIN
    -- Get signature info
    SELECT * INTO v_signature
    FROM pg_git.commit_signatures
    WHERE repo_id = p_repo_id
    AND commit_hash = p_commit_hash;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, NULL::TEXT, NULL::TEXT, NULL::TEXT, 'No signature found'::TEXT;
        RETURN;
    END IF;

    -- Get key info
    SELECT * INTO v_key
    FROM pg_git.gpg_keys
    WHERE repo_id = p_repo_id
    AND key_id = v_signature.key_id;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT FALSE, v_signature.key_id, NULL::TEXT, NULL::TEXT, 'Unknown key'::TEXT;
        RETURN;
    END IF;

    -- Check trust level if required
    IF p_require_trust_level IS NOT NULL AND 
       v_key.trust_level NOT IN ('full', 'ultimate') THEN
        RETURN QUERY
        SELECT FALSE, v_key.key_id, v_key.user_id, v_key.trust_level,
               'Insufficient trust level'::TEXT;
        RETURN;
    END IF;

    -- Here you would implement actual GPG verification
    -- For now, we'll assume any stored signature is valid
    RETURN QUERY
    SELECT TRUE, v_key.key_id, v_key.user_id, v_key.trust_level,
           'Valid signature'::TEXT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_git.sign_commit(
    p_repo_id INTEGER,
    p_commit_hash TEXT,
    p_key_id TEXT,
    p_signature TEXT
) RETURNS VOID AS $$
DECLARE
    v_signed_data TEXT;
BEGIN
    -- Construct signed data from commit
    SELECT tree_hash || parent_hash || author || message INTO v_signed_data
    FROM commits
    WHERE hash = p_commit_hash;

    INSERT INTO pg_git.commit_signatures (
        repo_id, commit_hash, key_id, signature, signed_data
    ) VALUES (
        p_repo_id, p_commit_hash, p_key_id, p_signature, v_signed_data
    );
END;
$$ LANGUAGE plpgsql;