-- Migration: 007_enforce_complainant_not_null.sql
-- Purpose: Dedicated post-backfill DDL enforcing NOT NULL on complaints.complainant_user_id
-- Note: Executed only after migration 006 has verified zero NULLs and committed data

-- 1. Pre-validation assertion: Fail if any NULL complainant_user_id exists
SET @null_count = (SELECT COUNT(*) FROM `complaints` WHERE `complainant_user_id` IS NULL);

-- 2. Pre-validation assertion: Fail if any ownership mismatch exists
SET @mismatch_count = (
  SELECT COUNT(*) 
  FROM `complaints` c 
  JOIN `students` s ON c.`student_id` = s.`student_id` 
  WHERE c.`complainant_user_id` <> s.`user_id`
);

-- Validate assertions dynamically:
DROP PROCEDURE IF EXISTS `check_complainant_integrity`;
DELIMITER $$
CREATE PROCEDURE `check_complainant_integrity`()
BEGIN
  IF @null_count > 0 THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Assertion Failed: Cannot enforce NOT NULL; complaints still contain NULL complainant_user_id.';
  END IF;

  IF @mismatch_count > 0 THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Assertion Failed: Cannot enforce NOT NULL; complainant_user_id does not match student user_id.';
  END IF;
END$$
DELIMITER ;

CALL `check_complainant_integrity`();
DROP PROCEDURE IF EXISTS `check_complainant_integrity`;

-- 3. Enforce NOT NULL constraint on complainant_user_id
ALTER TABLE `complaints` MODIFY COLUMN `complainant_user_id` INT NOT NULL;
