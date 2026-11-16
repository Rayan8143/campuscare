-- S2_B_verify_readonly.sql  (READ-ONLY; run as admin immediately after S2_B in the same session)
-- No GRANT/REVOKE/DDL/DML. SHOW CREATE USER is filtered through mysql.user so no
-- authentication string is ever printed.

SELECT 'V1 account lock / plugin / password presence (no secrets shown)' AS step;
SELECT user, host, account_locked, plugin,
       IF(authentication_string = '', 'no password set', 'password set (hidden)') AS password_state
  FROM mysql.user
 WHERE user IN ('cc_v2_dev_routine_definer', 'cc_v2_dev_trigger_definer', 'cc_v2_dev_activation_cli',
                'complaint_migrator_v2_dev', 'complaint_app_v2_dev')
 ORDER BY user;

SELECT 'V1b SHOW CREATE USER for the two definers (no password exists, so no auth string can appear)' AS step;
SHOW CREATE USER 'cc_v2_dev_routine_definer'@'localhost';
SHOW CREATE USER 'cc_v2_dev_trigger_definer'@'localhost';

SELECT 'V2 any privilege rows on the protected schema college_complaints for the five accounts (expect 0 rows)' AS step;
SELECT 'db' AS level, User, Db AS object FROM mysql.db
 WHERE Db = 'college_complaints'
   AND User IN ('cc_v2_dev_routine_definer','cc_v2_dev_trigger_definer','cc_v2_dev_activation_cli','complaint_migrator_v2_dev','complaint_app_v2_dev')
UNION ALL
SELECT 'table', User, CONCAT(Db, '.', Table_name) FROM mysql.tables_priv
 WHERE Db = 'college_complaints'
   AND User IN ('cc_v2_dev_routine_definer','cc_v2_dev_trigger_definer','cc_v2_dev_activation_cli','complaint_migrator_v2_dev','complaint_app_v2_dev')
UNION ALL
SELECT 'column', User, CONCAT(Db, '.', Table_name, '.', Column_name) FROM mysql.columns_priv
 WHERE Db = 'college_complaints'
   AND User IN ('cc_v2_dev_routine_definer','cc_v2_dev_trigger_definer','cc_v2_dev_activation_cli','complaint_migrator_v2_dev','complaint_app_v2_dev')
UNION ALL
SELECT 'routine', User, CONCAT(Db, '.', Routine_name) FROM mysql.procs_priv
 WHERE Db = 'college_complaints'
   AND User IN ('cc_v2_dev_routine_definer','cc_v2_dev_trigger_definer','cc_v2_dev_activation_cli','complaint_migrator_v2_dev','complaint_app_v2_dev');

SELECT 'V3 runtime privileges on complaints (expect only Select, no column privileges)' AS step;
SELECT Table_priv, Column_priv FROM mysql.tables_priv
 WHERE User = 'complaint_app_v2_dev' AND Db = 'college_complaints_v2_dev' AND Table_name = 'complaints';
SELECT Column_name, Column_priv FROM mysql.columns_priv
 WHERE User = 'complaint_app_v2_dev' AND Db = 'college_complaints_v2_dev' AND Table_name = 'complaints';

SELECT 'V4 runtime EXECUTE grants' AS step;
SELECT Routine_name, Proc_priv FROM mysql.procs_priv
 WHERE User = 'complaint_app_v2_dev' AND Db = 'college_complaints_v2_dev' ORDER BY Routine_name;

SELECT 'V5 global dynamic privileges of the five accounts (expect none; SET_USER_ID gone)' AS step;
SELECT USER, HOST, PRIV FROM mysql.global_grants
 WHERE USER IN ('cc_v2_dev_routine_definer','cc_v2_dev_trigger_definer','cc_v2_dev_activation_cli','complaint_migrator_v2_dev','complaint_app_v2_dev');

SELECT 'V6 schema-level grants of the five accounts' AS step;
SELECT User, Db FROM mysql.db
 WHERE User IN ('cc_v2_dev_routine_definer','cc_v2_dev_trigger_definer','cc_v2_dev_activation_cli','complaint_migrator_v2_dev','complaint_app_v2_dev')
 ORDER BY User, Db;
