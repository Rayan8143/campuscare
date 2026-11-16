-- root_readonly_checks.sql  - READ-ONLY (SELECT / SHOW only). Run as the local MySQL admin.
-- Section R = root privilege + DEFINER preflight; Section G = grant snapshot of the five accounts.
SELECT 'R1 CURRENT_USER' AS section, CURRENT_USER() AS value;
SHOW GRANTS FOR CURRENT_USER();
SELECT 'R2 current user dynamic privileges relevant to DEFINER' AS section;
SELECT PRIV FROM mysql.global_grants
 WHERE CONCAT(USER, '@', HOST) = CURRENT_USER() AND PRIV IN ('SET_USER_ID', 'SYSTEM_USER') ORDER BY PRIV;
SELECT 'R3 DEFINER accounts of triggers/views/routines and whether each exists' AS section;
SELECT 'TRIGGER' AS kind, t.TRIGGER_NAME AS object_name, t.DEFINER,
       (SELECT COUNT(*) FROM mysql.user u WHERE CONCAT(u.user, '@', u.host) = t.DEFINER) AS definer_exists
  FROM information_schema.TRIGGERS t WHERE t.TRIGGER_SCHEMA = 'college_complaints_v2_dev'
UNION ALL
SELECT 'VIEW', v.TABLE_NAME, v.DEFINER,
       (SELECT COUNT(*) FROM mysql.user u WHERE CONCAT(u.user, '@', u.host) = v.DEFINER)
  FROM information_schema.VIEWS v WHERE v.TABLE_SCHEMA = 'college_complaints_v2_dev'
UNION ALL
SELECT 'ROUTINE', r.ROUTINE_NAME, r.DEFINER,
       (SELECT COUNT(*) FROM mysql.user u WHERE CONCAT(u.user, '@', u.host) = r.DEFINER)
  FROM information_schema.ROUTINES r WHERE r.ROUTINE_SCHEMA = 'college_complaints_v2_dev'
ORDER BY 1, 2;
SELECT 'R4 SYSTEM_USER held by any DEFINER account (if yes, root also needs SYSTEM_USER)' AS section;
SELECT USER, HOST, PRIV FROM mysql.global_grants
 WHERE PRIV = 'SYSTEM_USER' AND USER IN ('cc_v2_dev_trigger_definer', 'cc_v2_dev_routine_definer', 'complaint_migrator_v2_dev');

SELECT 'G1 SHOW GRANTS complaint_app_v2_dev' AS section;
SHOW GRANTS FOR 'complaint_app_v2_dev'@'localhost';
SELECT 'G2 SHOW GRANTS complaint_migrator_v2_dev' AS section;
SHOW GRANTS FOR 'complaint_migrator_v2_dev'@'localhost';
SELECT 'G3 SHOW GRANTS cc_v2_dev_routine_definer' AS section;
SHOW GRANTS FOR 'cc_v2_dev_routine_definer'@'localhost';
SELECT 'G4 SHOW GRANTS cc_v2_dev_trigger_definer' AS section;
SHOW GRANTS FOR 'cc_v2_dev_trigger_definer'@'localhost';
SELECT 'G5 SHOW GRANTS cc_v2_dev_activation_cli' AS section;
SHOW GRANTS FOR 'cc_v2_dev_activation_cli'@'localhost';
SELECT 'G6 routine-level grant rows (mysql.procs_priv) for the dev schema' AS section;
SELECT User, Routine_name, Routine_type, Proc_priv FROM mysql.procs_priv
 WHERE Db = 'college_complaints_v2_dev' ORDER BY User, Routine_name;
SELECT 'G7 account lock state' AS section;
SELECT user, host, account_locked FROM mysql.user
 WHERE user IN ('cc_v2_dev_routine_definer', 'cc_v2_dev_trigger_definer', 'cc_v2_dev_activation_cli',
                'complaint_migrator_v2_dev', 'complaint_app_v2_dev') ORDER BY user;
