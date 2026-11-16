-- S2_A_pre_migration_accounts.sql
-- Run ONCE as a MySQL administrative account (e.g. root) BEFORE
--   python migrations/run_migrations.py --execute ...
-- NOT executed by run_migrations.py. Touches only accounts and privileges for
-- college_complaints_v2_dev; it never grants anything on college_complaints.
--
-- Effect:
--   1. RECONCILES the migrator's privileges. Stage 1 granted it
--      ALL PRIVILEGES ON college_complaints_v2_dev.*; GRANT is additive and cannot narrow
--      that, so every privilege is revoked first and only the explicit Stage 2 set is
--      re-granted. The account itself (and its password) is unchanged.
--   2. Creates two LOCKED definer accounts (cannot log in; can own routines/triggers).
--   3. Creates the LOCKED development activation-CLI account. It receives EXECUTE grants in
--      S2_B and is unlocked with a random password only when the operator needs it
--      (STAGE2_EXECUTION_GUIDE.md, Step 8). No password appears in this file.
--   4. TEMPORARILY grants SET_USER_ID to the migrator so 008 can set DEFINER to the locked
--      accounts. Revoked in S2_B. Without SYSTEM_USER the migrator can never name root or
--      another system account as definer.

-- 1. Migrator: revoke everything (schema ALL, any table/routine grants, GRANT OPTION) ...
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'complaint_migrator_v2_dev'@'localhost';

-- ... then grant exactly what migrations 000-008 and the runner's checkpoints need.
--   SELECT/INSERT/UPDATE : 002/003 seeds, 006 backfill, ledger writes, preflight reads, mysqldump
--   CREATE/ALTER/INDEX/REFERENCES : 000-005 tables, 005/007 ALTERs, foreign keys
--   DROP                 : 008 DROP ... IF EXISTS / CREATE OR REPLACE VIEW, 007 temp procedure
--   CREATE VIEW/SHOW VIEW: 008 views; mysqldump of views
--   TRIGGER              : 008 triggers; mysqldump --triggers
--   CREATE/ALTER ROUTINE, EXECUTE : 007 temporary assertion procedure, 008 routines
-- Deliberately NOT granted: DELETE (no migration deletes rows), LOCK TABLES (dumps use
-- --single-transaction), CREATE TEMPORARY TABLES, EVENT, FILE, PROCESS, SUPER,
-- SYSTEM_USER, GRANT OPTION, and nothing on any other schema.
GRANT SELECT, INSERT, UPDATE, CREATE, ALTER, DROP, INDEX, REFERENCES,
      CREATE VIEW, SHOW VIEW, TRIGGER, CREATE ROUTINE, ALTER ROUTINE, EXECUTE
   ON `college_complaints_v2_dev`.* TO 'complaint_migrator_v2_dev'@'localhost';

-- 2. Definer accounts (privileges granted in S2_B, after the objects exist)
CREATE USER IF NOT EXISTS 'cc_v2_dev_routine_definer'@'localhost' ACCOUNT LOCK;
CREATE USER IF NOT EXISTS 'cc_v2_dev_trigger_definer'@'localhost' ACCOUNT LOCK;
ALTER USER 'cc_v2_dev_routine_definer'@'localhost' ACCOUNT LOCK;
ALTER USER 'cc_v2_dev_trigger_definer'@'localhost' ACCOUNT LOCK;

-- 3. Development activation-CLI account (locked until Step 8 of the guide)
CREATE USER IF NOT EXISTS 'cc_v2_dev_activation_cli'@'localhost' ACCOUNT LOCK;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'cc_v2_dev_activation_cli'@'localhost';

-- 4. Temporary definer-impersonation privilege for 008
GRANT SET_USER_ID ON *.* TO 'complaint_migrator_v2_dev'@'localhost';

-- 5. Verification (read-only). Expected:
--    * migrator: exactly "GRANT USAGE ON *.*", "GRANT SET_USER_ID ON *.*", and the 14
--      schema privileges above on `college_complaints_v2_dev`.* - no ALL, DELETE, FILE,
--      PROCESS, SUPER, SYSTEM_USER, GRANT OPTION, nothing on `college_complaints`.
--    * definers and CLI account: USAGE only, account_locked = 'Y'.
--    * no anonymous accounts (empty user name) exist.
SHOW GRANTS FOR 'complaint_migrator_v2_dev'@'localhost';
SHOW GRANTS FOR 'cc_v2_dev_routine_definer'@'localhost';
SHOW GRANTS FOR 'cc_v2_dev_trigger_definer'@'localhost';
SHOW GRANTS FOR 'cc_v2_dev_activation_cli'@'localhost';
SELECT user, host, account_locked
  FROM mysql.user
 WHERE user IN ('cc_v2_dev_routine_definer', 'cc_v2_dev_trigger_definer', 'cc_v2_dev_activation_cli',
                'complaint_migrator_v2_dev', 'complaint_app_v2_dev');
SELECT COUNT(*) AS anonymous_accounts FROM mysql.user WHERE user = '';
SELECT GRANTEE, PRIVILEGE_TYPE FROM information_schema.SCHEMA_PRIVILEGES
 WHERE TABLE_SCHEMA = 'college_complaints'
   AND GRANTEE LIKE '%complaint_migrator_v2_dev%';   -- expected: no rows
