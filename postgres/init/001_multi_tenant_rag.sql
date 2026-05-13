CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

CREATE SCHEMA IF NOT EXISTS rag;

DO $$
BEGIN
    CREATE TYPE rag.group_role AS ENUM ('owner', 'admin', 'member');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE rag.chat_message_role AS ENUM ('system', 'user', 'assistant', 'tool');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE rag.document_status AS ENUM ('uploaded', 'processing', 'ready', 'failed', 'archived');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE rag.ingestion_status AS ENUM ('queued', 'processing', 'completed', 'failed');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    CREATE TYPE rag.scope_type AS ENUM ('tenant', 'group', 'user', 'chat');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS rag.tenants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),
    name text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rag.app_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES rag.tenants (id) ON DELETE CASCADE,
    external_id text,
    email citext,
    display_name text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, external_id),
    UNIQUE (tenant_id, email),
    CHECK (external_id IS NOT NULL OR email IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS rag.groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES rag.tenants (id) ON DELETE CASCADE,
    slug text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),
    name text NOT NULL,
    created_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, slug)
);

CREATE TABLE IF NOT EXISTS rag.group_memberships (
    tenant_id uuid NOT NULL,
    group_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role rag.group_role NOT NULL DEFAULT 'member',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, user_id),
    FOREIGN KEY (tenant_id, group_id) REFERENCES rag.groups (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, user_id) REFERENCES rag.app_users (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.chats (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES rag.tenants (id) ON DELETE CASCADE,
    owner_user_id uuid NOT NULL,
    group_id uuid,
    title text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    archived_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, owner_user_id) REFERENCES rag.app_users (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, group_id) REFERENCES rag.groups (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.chat_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    chat_id uuid NOT NULL,
    user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    role rag.chat_message_role NOT NULL,
    content text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, chat_id) REFERENCES rag.chats (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES rag.tenants (id) ON DELETE CASCADE,
    uploaded_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    source_uri text,
    original_filename text,
    mime_type text,
    sha256 text,
    size_bytes bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
    status rag.document_status NOT NULL DEFAULT 'uploaded',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, sha256)
);

CREATE TABLE IF NOT EXISTS rag.document_tenant_scopes (
    tenant_id uuid NOT NULL,
    document_id uuid NOT NULL,
    granted_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, document_id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES rag.documents (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.document_group_scopes (
    tenant_id uuid NOT NULL,
    document_id uuid NOT NULL,
    group_id uuid NOT NULL,
    granted_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, group_id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES rag.documents (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, group_id) REFERENCES rag.groups (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.document_user_scopes (
    tenant_id uuid NOT NULL,
    document_id uuid NOT NULL,
    user_id uuid NOT NULL,
    granted_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, user_id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES rag.documents (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, user_id) REFERENCES rag.app_users (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.document_chat_scopes (
    tenant_id uuid NOT NULL,
    document_id uuid NOT NULL,
    chat_id uuid NOT NULL,
    granted_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, chat_id),
    FOREIGN KEY (tenant_id, document_id) REFERENCES rag.documents (tenant_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, chat_id) REFERENCES rag.chats (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.document_chunks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    document_id uuid NOT NULL,
    chunk_index integer NOT NULL CHECK (chunk_index >= 0),
    content text NOT NULL,
    token_count integer CHECK (token_count IS NULL OR token_count >= 0),
    embedding vector(768),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index),
    FOREIGN KEY (tenant_id, document_id) REFERENCES rag.documents (tenant_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS rag.ingestion_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES rag.tenants (id) ON DELETE CASCADE,
    document_id uuid NOT NULL REFERENCES rag.documents (id) ON DELETE CASCADE,
    requested_by_user_id uuid REFERENCES rag.app_users (id) ON DELETE SET NULL,
    status rag.ingestion_status NOT NULL DEFAULT 'queued',
    error_message text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz
);

CREATE OR REPLACE VIEW rag.document_scopes AS
SELECT tenant_id, document_id, 'tenant'::rag.scope_type AS scope_type, tenant_id AS scope_id, created_at
FROM rag.document_tenant_scopes
UNION ALL
SELECT tenant_id, document_id, 'group'::rag.scope_type AS scope_type, group_id AS scope_id, created_at
FROM rag.document_group_scopes
UNION ALL
SELECT tenant_id, document_id, 'user'::rag.scope_type AS scope_type, user_id AS scope_id, created_at
FROM rag.document_user_scopes
UNION ALL
SELECT tenant_id, document_id, 'chat'::rag.scope_type AS scope_type, chat_id AS scope_id, created_at
FROM rag.document_chat_scopes;

CREATE INDEX IF NOT EXISTS app_users_tenant_idx ON rag.app_users (tenant_id);
CREATE INDEX IF NOT EXISTS groups_tenant_idx ON rag.groups (tenant_id);
CREATE INDEX IF NOT EXISTS group_memberships_user_idx ON rag.group_memberships (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS chats_owner_idx ON rag.chats (tenant_id, owner_user_id);
CREATE INDEX IF NOT EXISTS chats_group_idx ON rag.chats (tenant_id, group_id);
CREATE INDEX IF NOT EXISTS documents_tenant_status_idx ON rag.documents (tenant_id, status);
CREATE INDEX IF NOT EXISTS document_group_scopes_group_idx ON rag.document_group_scopes (tenant_id, group_id);
CREATE INDEX IF NOT EXISTS document_user_scopes_user_idx ON rag.document_user_scopes (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS document_chat_scopes_chat_idx ON rag.document_chat_scopes (tenant_id, chat_id);
CREATE INDEX IF NOT EXISTS document_chunks_document_idx ON rag.document_chunks (tenant_id, document_id, chunk_index);
CREATE INDEX IF NOT EXISTS document_chunks_embedding_hnsw_idx
    ON rag.document_chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE OR REPLACE FUNCTION rag.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS touch_updated_at ON rag.tenants;
CREATE TRIGGER touch_updated_at
BEFORE UPDATE ON rag.tenants
FOR EACH ROW EXECUTE FUNCTION rag.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON rag.app_users;
CREATE TRIGGER touch_updated_at
BEFORE UPDATE ON rag.app_users
FOR EACH ROW EXECUTE FUNCTION rag.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON rag.groups;
CREATE TRIGGER touch_updated_at
BEFORE UPDATE ON rag.groups
FOR EACH ROW EXECUTE FUNCTION rag.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON rag.chats;
CREATE TRIGGER touch_updated_at
BEFORE UPDATE ON rag.chats
FOR EACH ROW EXECUTE FUNCTION rag.touch_updated_at();

DROP TRIGGER IF EXISTS touch_updated_at ON rag.documents;
CREATE TRIGGER touch_updated_at
BEFORE UPDATE ON rag.documents
FOR EACH ROW EXECUTE FUNCTION rag.touch_updated_at();

CREATE OR REPLACE FUNCTION rag.user_can_access_chat(
    p_tenant_id uuid,
    p_user_id uuid,
    p_chat_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM rag.chats c
        WHERE c.tenant_id = p_tenant_id
          AND c.id = p_chat_id
          AND c.archived_at IS NULL
          AND (
              c.owner_user_id = p_user_id
              OR (
                  c.group_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM rag.group_memberships gm
                      WHERE gm.tenant_id = p_tenant_id
                        AND gm.group_id = c.group_id
                        AND gm.user_id = p_user_id
                  )
              )
          )
    );
$$;

CREATE OR REPLACE FUNCTION rag.allowed_document_ids(
    p_tenant_id uuid,
    p_user_id uuid,
    p_chat_id uuid
)
RETURNS TABLE (document_id uuid)
LANGUAGE sql
STABLE
AS $$
    WITH chat_context AS (
        SELECT c.id AS chat_id, c.group_id
        FROM rag.chats c
        WHERE c.tenant_id = p_tenant_id
          AND c.id = p_chat_id
          AND rag.user_can_access_chat(p_tenant_id, p_user_id, p_chat_id)
    ),
    scoped_documents AS (
        SELECT dts.document_id
        FROM rag.document_tenant_scopes dts
        WHERE dts.tenant_id = p_tenant_id
          AND EXISTS (SELECT 1 FROM chat_context)

        UNION

        SELECT dcs.document_id
        FROM rag.document_chat_scopes dcs
        JOIN chat_context cc ON cc.chat_id = dcs.chat_id
        WHERE dcs.tenant_id = p_tenant_id

        UNION

        SELECT dgs.document_id
        FROM rag.document_group_scopes dgs
        JOIN chat_context cc ON cc.group_id = dgs.group_id
        WHERE dgs.tenant_id = p_tenant_id

        UNION

        SELECT dus.document_id
        FROM rag.document_user_scopes dus
        JOIN chat_context cc ON cc.group_id IS NULL
        WHERE dus.tenant_id = p_tenant_id
          AND dus.user_id = p_user_id
    )
    SELECT DISTINCT sd.document_id
    FROM scoped_documents sd;
$$;

CREATE OR REPLACE FUNCTION rag.match_chunks(
    p_tenant_id uuid,
    p_user_id uuid,
    p_chat_id uuid,
    p_query_embedding vector(768),
    p_match_count integer DEFAULT 8,
    p_min_similarity double precision DEFAULT 0.0
)
RETURNS TABLE (
    chunk_id uuid,
    document_id uuid,
    chunk_index integer,
    content text,
    similarity double precision,
    source_uri text,
    original_filename text,
    document_metadata jsonb,
    chunk_metadata jsonb
)
LANGUAGE sql
STABLE
AS $$
    WITH allowed AS (
        SELECT document_id
        FROM rag.allowed_document_ids(p_tenant_id, p_user_id, p_chat_id)
    ),
    ranked AS (
        SELECT
            dc.id AS chunk_id,
            dc.document_id,
            dc.chunk_index,
            dc.content,
            1 - (dc.embedding <=> p_query_embedding) AS similarity,
            d.source_uri,
            d.original_filename,
            d.metadata AS document_metadata,
            dc.metadata AS chunk_metadata
        FROM rag.document_chunks dc
        JOIN allowed a ON a.document_id = dc.document_id
        JOIN rag.documents d ON d.tenant_id = dc.tenant_id AND d.id = dc.document_id
        WHERE dc.tenant_id = p_tenant_id
          AND dc.embedding IS NOT NULL
          AND d.status = 'ready'
    )
    SELECT
        ranked.chunk_id,
        ranked.document_id,
        ranked.chunk_index,
        ranked.content,
        ranked.similarity,
        ranked.source_uri,
        ranked.original_filename,
        ranked.document_metadata,
        ranked.chunk_metadata
    FROM ranked
    WHERE ranked.similarity >= p_min_similarity
    ORDER BY ranked.similarity DESC
    LIMIT LEAST(GREATEST(p_match_count, 1), 50);
$$;

CREATE OR REPLACE FUNCTION rag.attach_document_to_chat(
    p_tenant_id uuid,
    p_user_id uuid,
    p_chat_id uuid,
    p_document_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_group_id uuid;
BEGIN
    SELECT c.group_id
    INTO v_group_id
    FROM rag.chats c
    WHERE c.tenant_id = p_tenant_id
      AND c.id = p_chat_id
      AND rag.user_can_access_chat(p_tenant_id, p_user_id, p_chat_id);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % cannot access chat % in tenant %', p_user_id, p_chat_id, p_tenant_id
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM rag.documents d
        WHERE d.tenant_id = p_tenant_id
          AND d.id = p_document_id
          AND (
              d.uploaded_by_user_id = p_user_id
              OR EXISTS (
                  SELECT 1
                  FROM rag.document_tenant_scopes dts
                  WHERE dts.tenant_id = p_tenant_id
                    AND dts.document_id = p_document_id
              )
              OR EXISTS (
                  SELECT 1
                  FROM rag.document_user_scopes dus
                  WHERE dus.tenant_id = p_tenant_id
                    AND dus.document_id = p_document_id
                    AND dus.user_id = p_user_id
              )
              OR (
                  v_group_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM rag.document_group_scopes dgs
                      WHERE dgs.tenant_id = p_tenant_id
                        AND dgs.document_id = p_document_id
                        AND dgs.group_id = v_group_id
                  )
              )
              OR EXISTS (
                  SELECT 1
                  FROM rag.document_chat_scopes dcs
                  WHERE dcs.tenant_id = p_tenant_id
                    AND dcs.document_id = p_document_id
                    AND dcs.chat_id = p_chat_id
              )
          )
    ) THEN
        RAISE EXCEPTION 'Document % is not attachable by user % in tenant %', p_document_id, p_user_id, p_tenant_id
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO rag.document_chat_scopes (tenant_id, document_id, chat_id, granted_by_user_id)
    VALUES (p_tenant_id, p_document_id, p_chat_id, p_user_id)
    ON CONFLICT DO NOTHING;
END;
$$;

COMMENT ON TABLE rag.document_tenant_scopes IS 'Documents available to all chats in a tenant.';
COMMENT ON TABLE rag.document_group_scopes IS 'Documents available only to chats for the matching group.';
COMMENT ON TABLE rag.document_user_scopes IS 'Documents available only to private chats for the matching user unless explicitly attached to a chat.';
COMMENT ON TABLE rag.document_chat_scopes IS 'Documents explicitly attached to one chat.';
COMMENT ON FUNCTION rag.match_chunks(uuid, uuid, uuid, vector, integer, double precision) IS 'Vector search with tenant/user/chat scope filtering. The default vector size is 768 for local Ollama embedding models such as nomic-embed-text.';
