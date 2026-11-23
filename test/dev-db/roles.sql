-- The dev Postgres's IntegreSQL roles, as infra-bootstrap's
-- gitops/platform/dev-services/roles-job.yaml makes them (minus the
-- timescaledb/vector extensions, which plain postgres lacks): neither is a
-- superuser, and this one is deliberately stricter than live (no CREATEROLE), so the self-test proves the action works without one.
CREATE ROLE integresql LOGIN NOSUPERUSER CREATEDB PASSWORD 'mgrpass';
CREATE ROLE integresql_test LOGIN NOSUPERUSER NOCREATEDB PASSWORD 'testpass';
GRANT integresql_test TO integresql WITH SET TRUE, INHERIT TRUE;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
GRANT CONNECT ON DATABASE postgres TO integresql;
