-- Migration: 007_enforce_complainant_not_null.sql
-- Purpose : Enforce NOT NULL on complaints.complainant_user_id after the 006 backfill.
-- Type    : Read-only assertion (temporary procedure) followed by one DDL statement.
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 007):
--   * The counts are now computed INSIDE the assertion procedure at CALL time. Previously
--     they were captured in session variables (@null_count / @mismatch_count) before the
--     procedure existed; correct for a single mysql session, but fragile and forgeable.
--   * NULL-safe comparison (<=>) for the ownership check; also asserts that every
--     complaint still references a student (no external complaints exist yet).
--   * The temporary procedure is created with the migrator as definer, used once and
--     dropped; it reads data only. If the assertion fails, the mysql client stops before
--     the ALTER (the procedure is then left behind and is dropped by the next attempt).

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

DROP PROCEDURE IF EXISTS `tmp_assert_complainant_integrity`;
DELIMITER $$
CREATE PROCEDURE `tmp_assert_complainant_integrity`()
READS SQL DATA
SQL SECURITY INVOKER
BEGIN
  IF (SELECT COUNT(*) FROM `complaints` WHERE `complainant_user_id` IS NULL) > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Assertion failed: complaints still contain NULL complainant_user_id; NOT NULL not enforced.';
  END IF;

  IF (SELECT COUNT(*)
        FROM `complaints` c
        JOIN `students` s ON c.`student_id` = s.`student_id`
       WHERE NOT (c.`complainant_user_id` <=> s.`user_id`)) > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Assertion failed: complainant_user_id does not match the student user_id.';
  END IF;

  IF (SELECT COUNT(*) FROM `complaints` WHERE `student_id` IS NULL AND `external_id` IS NULL) > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Assertion failed: complaint without any complainant link.';
  END IF;
END$$
DELIMITER ;

CALL `tmp_assert_complainant_integrity`();
DROP PROCEDURE IF EXISTS `tmp_assert_complainant_integrity`;

-- Enforce NOT NULL (strict mode would also reject this if any NULL remained).
ALTER TABLE `complaints` MODIFY COLUMN `complainant_user_id` INT NOT NULL;
