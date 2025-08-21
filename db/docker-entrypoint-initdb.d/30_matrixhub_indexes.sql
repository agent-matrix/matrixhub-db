CREATE INDEX IF NOT EXISTS ix_entity_type_name
  ON entity (type, name);

CREATE INDEX IF NOT EXISTS ix_entity_created_at
  ON entity (created_at);

CREATE INDEX IF NOT EXISTS ix_embedding_chunk_updated_at
  ON embedding_chunk (updated_at);
