-- Ensure the private schema exists
CREATE SCHEMA IF NOT EXISTS private;

ALTER DATABASE postgres
SET
   timezone TO 'Europe/Istanbul';

-- The build assumes Supabase's legacy default ACL in public: whatever postgres creates there is open
-- to anon and authenticated until 048/064 take it back. Newer hosted projects ship without those
-- defaults (postgres's table ACL holds only postgres and service_role), and then every grant derived
-- from a base table comes out different: private.enable_field_security copies INSERT/UPDATE/DELETE
-- onto each api view from its base table, so the writable views would end up SELECT-only. State the
-- defaults here so local and hosted builds produce the same grants; 064 revokes them from tables and
-- sequences again, and the 064 test asserts on every relation's ACL.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
