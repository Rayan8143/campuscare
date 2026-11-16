-- S2_A2_optional_drop_root_defined_legacy_objects.sql
-- OPTIONAL. Use ONLY if migration 008 fails with an access-denied error (e.g. ERROR 1227)
-- while dropping the v1 objects that the Stage 1 restore created with DEFINER=root@localhost.
-- Some MySQL 8.0 builds require SYSTEM_USER to drop/replace objects whose definer is a
-- system account; the migrator intentionally does not hold SYSTEM_USER.
--
-- Run as an administrative account, then re-run:
--   python migrations/run_migrations.py --execute ...   (008 is re-runnable)
--
-- Safe: these objects are dropped by 008 anyway, and no application traffic may reach the
-- sandbox during Stage 2 (Flask stopped). The pre-Stage-2 admin checkpoint still contains them.

-- Every DROP below is fully schema-qualified to `college_complaints_v2_dev`, so it can never
-- resolve to college_complaints regardless of the session's current database. USE is kept as
-- an additional safeguard (it fails, and the client stops, if the dev schema is missing).
USE `college_complaints_v2_dev`;

DROP TRIGGER   IF EXISTS `college_complaints_v2_dev`.`trg_complaint_status_history`;
DROP PROCEDURE IF EXISTS `college_complaints_v2_dev`.`update_complaint_status`;
DROP VIEW      IF EXISTS `college_complaints_v2_dev`.`open_complaints`;
DROP VIEW      IF EXISTS `college_complaints_v2_dev`.`pending_complaints`;
DROP VIEW      IF EXISTS `college_complaints_v2_dev`.`department_complaint_summary`;
DROP VIEW      IF EXISTS `college_complaints_v2_dev`.`complaint_details`;
