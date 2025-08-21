-- Create minimal monitoring role with pg_monitor for postgres_exporter
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = current_setting('metrics.user', true)) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', current_setting('metrics.user', true), current_setting('metrics.password', true));
    EXECUTE format('GRANT pg_monitor TO %I', current_setting('metrics.user', true));
  END IF;
END$$;
