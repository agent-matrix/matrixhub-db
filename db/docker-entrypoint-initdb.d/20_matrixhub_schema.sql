-- MatrixHub schema (matches Alembic upgrade)

-- 1) entity
CREATE TABLE IF NOT EXISTS entity (
  uid                   text PRIMARY KEY,
  type                  text NOT NULL CHECK (type in ('agent','tool','mcp_server')),
  name                  text NOT NULL,
  version               text NOT NULL,

  summary               text,
  description           text,

  license               text,
  homepage              text,
  source_url            text,

  tenant_id             text NOT NULL DEFAULT 'public',

  capabilities          jsonb NOT NULL DEFAULT '[]'::jsonb,
  frameworks            jsonb NOT NULL DEFAULT '[]'::jsonb,
  providers             jsonb NOT NULL DEFAULT '[]'::jsonb,

  readme_blob_ref       text,

  quality_score         double precision NOT NULL DEFAULT 0.0,
  release_ts            timestamptz,

  created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- Track gateway registration state and errors
  gateway_registered_at timestamptz,
  gateway_error         text,

  -- Persist manifest’s mcp_registration block
  mcp_registration      jsonb
);

-- 2) remote
CREATE TABLE IF NOT EXISTS remote (
  url text PRIMARY KEY
);

-- 3) embedding_chunk
CREATE TABLE IF NOT EXISTS embedding_chunk (
  entity_uid      text NOT NULL REFERENCES entity(uid) ON DELETE CASCADE,
  chunk_id        text NOT NULL,

  vector          jsonb,

  caps_text       text,
  frameworks_text text,
  providers_text  text,

  quality_score   double precision,
  embed_model     text,
  raw_ref         text,

  updated_at      timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (entity_uid, chunk_id)
);
