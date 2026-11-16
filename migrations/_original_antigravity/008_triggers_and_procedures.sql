-- Migration: 008_triggers_and_procedures.sql
-- Purpose: Install upgraded triggers, identity integrity guards, authoritative status procedure, status bypass guard, and external-aware views

-- 1. Retire and Drop Legacy Stored Procedure
DROP PROCEDURE IF EXISTS `update_complaint_status`;

-- 2. Create Authoritative transition_complaint_status Procedure
DROP PROCEDURE IF EXISTS `transition_complaint_status`;
DELIMITER $$
CREATE PROCEDURE `transition_complaint_status`(
    IN p_complaint_id INT,
    IN p_new_status VARCHAR(40),
    IN p_actor_user_id INT,
    IN p_remarks TEXT
)
BEGIN
    DECLARE v_current_status VARCHAR(40);
    DECLARE v_is_deleted BOOLEAN;
    DECLARE v_assigned_staff_id INT;
    DECLARE v_is_primary_officer BOOLEAN DEFAULT FALSE;
    DECLARE v_is_reviewer_or_admin BOOLEAN DEFAULT FALSE;
    DECLARE v_is_assigned_staff BOOLEAN DEFAULT FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_status_transition_authorized = NULL;
        SET @app_current_user_id = NULL;
        SET @app_action_type = NULL;
        SET @app_status_remarks = NULL;
        ROLLBACK;
        RESIGNAL;
    END;

    -- 1. Strict validation of actor
    IF p_actor_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Authenticated actor user ID is required for status transitions.';
    END IF;

    -- 2. Check if complaint exists and retrieve state
    SELECT `status`, `is_deleted`, `assigned_staff_id` 
    INTO v_current_status, v_is_deleted, v_assigned_staff_id
    FROM `complaints`
    WHERE `complaint_id` = p_complaint_id;

    IF v_current_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;

    IF v_is_deleted = TRUE THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot transition status on an archived or deleted complaint.';
    END IF;

    -- 3. Validate target status domain
    IF p_new_status NOT IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification', 'Resolved', 'Rejected') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Invalid complaint status.';
    END IF;

    -- 4. Enforce finality: Resolved/Rejected cannot be transitioned directly via standard route
    IF v_current_status IN ('Resolved', 'Rejected') AND p_new_status <> v_current_status THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cannot modify a closed or finalized complaint.';
    END IF;

    -- 5. Role and Authorization Validation:
    -- Check if actor is the designated Primary Officer
    IF EXISTS (
        SELECT 1 FROM `primary_officer_assignment` 
        WHERE `singleton_id` = 1 AND `user_id` = p_actor_user_id
    ) THEN
        SET v_is_primary_officer = TRUE;
    END IF;

    -- Check if actor is Department Reviewer or System Admin
    IF EXISTS (
        SELECT 1 FROM `user_roles` ur 
        JOIN `roles` r ON ur.`role_id` = r.`role_id` 
        WHERE ur.`user_id` = p_actor_user_id AND ur.`is_active` = TRUE 
          AND r.`role_name` IN ('DEPARTMENT_REVIEWER', 'SYSTEM_ADMIN')
    ) THEN
        SET v_is_reviewer_or_admin = TRUE;
    END IF;

    -- Check if actor is the currently assigned staff member
    IF v_assigned_staff_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM `staff` st 
        WHERE st.`user_id` = p_actor_user_id AND st.`staff_id` = v_assigned_staff_id
    ) THEN
        SET v_is_assigned_staff = TRUE;
    END IF;

    -- Rule A: Only the Primary Officer can transition a ticket to 'Resolved'
    IF p_new_status = 'Resolved' AND v_is_primary_officer = FALSE THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Authorization Denied: Only the Primary Complaint Officer can approve resolution into Resolved status.';
    END IF;

    -- Rule B: Non-primary actors must be either assigned staff or authorized reviewer/admin
    IF v_is_primary_officer = FALSE AND v_is_reviewer_or_admin = FALSE AND v_is_assigned_staff = FALSE THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Authorization Denied: Actor is not authorized to update status on this complaint.';
    END IF;

    START TRANSACTION;

    -- Set connection session variables for authorization guard & trigger capture
    SET @app_status_transition_authorized = TRUE;
    SET @app_current_user_id = p_actor_user_id;
    SET @app_action_type = 'STATUS_CHANGE';
    SET @app_status_remarks = p_remarks;

    -- Execute status update (guarded by trg_guard_complaint_status_direct_update)
    UPDATE `complaints`
    SET `status` = p_new_status,
        `resolved_at` = CASE WHEN p_new_status = 'Resolved' THEN COALESCE(`resolved_at`, NOW()) ELSE NULL END
    WHERE `complaint_id` = p_complaint_id;

    -- Clear session variables immediately
    SET @app_status_transition_authorized = NULL;
    SET @app_current_user_id = NULL;
    SET @app_action_type = NULL;
    SET @app_status_remarks = NULL;

    COMMIT;
END$$
DELIMITER ;

-- 3. Trigger Guard: Prevent Direct SQL UPDATE on complaints.status bypassing the procedure
DROP TRIGGER IF EXISTS `trg_guard_complaint_status_direct_update`;
DELIMITER $$
CREATE TRIGGER `trg_guard_complaint_status_direct_update`
BEFORE UPDATE ON `complaints` FOR EACH ROW
BEGIN
  IF OLD.status <> NEW.status THEN
    IF @app_status_transition_authorized IS NULL OR @app_status_transition_authorized <> TRUE THEN
      SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Direct UPDATE on complaints.status is prohibited. All status transitions must call transition_complaint_status procedure.';
    END IF;
  END IF;
END$$
DELIMITER ;

-- 4. Replace Legacy complaint_history Trigger (Clean Deduplication)
DROP TRIGGER IF EXISTS `trg_complaint_status_history`;
DELIMITER $$
CREATE TRIGGER `trg_complaint_status_history` AFTER UPDATE ON `complaints` FOR EACH ROW
BEGIN
  IF OLD.status <> NEW.status THEN
    INSERT INTO `complaint_history` (
      `complaint_id`,
      `old_status`,
      `new_status`,
      `changed_at`,
      `changed_by_user_id`,
      `action_type`,
      `remarks`
    ) VALUES (
      NEW.complaint_id,
      OLD.status,
      NEW.status,
      NOW(),
      @app_current_user_id,
      COALESCE(@app_action_type, 'STATUS_CHANGE'),
      COALESCE(@app_status_remarks, 'Status updated via application workflow')
    );
  END IF;
END$$
DELIMITER ;

-- 5. Create Complainant Identity Integrity Triggers (Reject NULL User IDs)
DROP TRIGGER IF EXISTS `trg_validate_complaint_identity_insert`;
DELIMITER $$
CREATE TRIGGER `trg_validate_complaint_identity_insert`
BEFORE INSERT ON `complaints` FOR EACH ROW
BEGIN
  DECLARE v_student_user_id INT;
  DECLARE v_external_user_id INT;

  -- 1. Explicitly reject NULL complainant_user_id
  IF NEW.complainant_user_id IS NULL THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Integrity Error: complainant_user_id cannot be null.';
  END IF;

  -- 2. Verify student ownership alignment
  IF NEW.student_id IS NOT NULL THEN
    SELECT `user_id` INTO v_student_user_id FROM `students` WHERE `student_id` = NEW.student_id;
    IF v_student_user_id IS NULL OR v_student_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: student_id does not belong to complainant_user_id.';
    END IF;
  END IF;

  -- 3. Verify external complainant ownership alignment
  IF NEW.external_id IS NOT NULL THEN
    SELECT `user_id` INTO v_external_user_id FROM `external_complainants` WHERE `external_id` = NEW.external_id;
    IF v_external_user_id IS NULL OR v_external_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: external_id does not belong to complainant_user_id.';
    END IF;
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS `trg_validate_complaint_identity_update`;
DELIMITER $$
CREATE TRIGGER `trg_validate_complaint_identity_update`
BEFORE UPDATE ON `complaints` FOR EACH ROW
BEGIN
  DECLARE v_student_user_id INT;
  DECLARE v_external_user_id INT;

  -- 1. Explicitly reject NULL complainant_user_id
  IF NEW.complainant_user_id IS NULL THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Integrity Error: complainant_user_id cannot be null.';
  END IF;

  -- 2. Immutability guard: complainant_user_id cannot be changed
  IF NEW.complainant_user_id <> OLD.complainant_user_id THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Security Violation: complainant_user_id cannot be altered.';
  END IF;

  -- 3. Verify student ownership alignment
  IF NEW.student_id IS NOT NULL THEN
    SELECT `user_id` INTO v_student_user_id FROM `students` WHERE `student_id` = NEW.student_id;
    IF v_student_user_id IS NULL OR v_student_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: student_id does not belong to complainant_user_id.';
    END IF;
  END IF;

  -- 4. Verify external complainant ownership alignment
  IF NEW.external_id IS NOT NULL THEN
    SELECT `user_id` INTO v_external_user_id FROM `external_complainants` WHERE `external_id` = NEW.external_id;
    IF v_external_user_id IS NULL OR v_external_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: external_id does not belong to complainant_user_id.';
    END IF;
  END IF;
END$$
DELIMITER ;

-- 6. Upgrade All 4 Database Views (Support External Users & Filter Soft-Deleted)

-- View 1: complaint_details
CREATE OR REPLACE VIEW `complaint_details` AS
SELECT 
  c.`complaint_id`,
  c.`title`,
  c.`description`,
  c.`category`,
  c.`priority`,
  c.`status`,
  c.`current_level_id`,
  wl.`level_name` AS `current_level_name`,
  c.`created_at`,
  c.`resolved_at`,
  c.`is_deleted`,
  -- Complainant metadata
  c.`complainant_user_id`,
  CASE 
    WHEN c.`student_id` IS NOT NULL THEN 'STUDENT'
    WHEN c.`external_id` IS NOT NULL THEN 'EXTERNAL'
    ELSE 'UNKNOWN'
  END AS `complainant_type`,
  u.`full_name` AS `complainant_name`,
  u.`email` AS `complainant_email`,
  COALESCE(s.`phone`, ec.`phone`) AS `complainant_phone`,
  -- Student-specific fields (backward compatible)
  c.`student_id`,
  s.`full_name` AS `student_name`,
  s.`email` AS `student_email`,
  ad.`academic_department_id`,
  ad.`department_name` AS `academic_department`,
  -- External-specific fields
  c.`external_id`,
  ec.`affiliation_type` AS `external_affiliation`,
  ec.`organization_name` AS `external_organization`,
  -- Service department & assigned staff
  c.`department_id`,
  d.`department_name` AS `responsible_department`,
  c.`assigned_staff_id`,
  st.`full_name` AS `assigned_staff_name`,
  st.`email` AS `assigned_staff_email`
FROM `complaints` c
JOIN `users` u ON c.`complainant_user_id` = u.`user_id`
JOIN `departments` d ON c.`department_id` = d.`department_id`
JOIN `workflow_levels` wl ON c.`current_level_id` = wl.`level_id`
LEFT JOIN `students` s ON c.`student_id` = s.`student_id`
LEFT JOIN `academic_departments` ad ON s.`academic_department_id` = ad.`academic_department_id`
LEFT JOIN `external_complainants` ec ON c.`external_id` = ec.`external_id`
LEFT JOIN `staff` st ON c.`assigned_staff_id` = st.`staff_id`
WHERE c.`is_deleted` = FALSE;

-- View 2: open_complaints
CREATE OR REPLACE VIEW `open_complaints` AS
SELECT * FROM `complaint_details`
WHERE `status` IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification');

-- View 3: pending_complaints (Backward compatible with legacy structure, soft-delete filtered)
CREATE OR REPLACE VIEW `pending_complaints` AS
SELECT 
  c.`complaint_id`,
  c.`title`,
  c.`category`,
  c.`priority`,
  c.`status`,
  c.`created_at`,
  u.`full_name` AS `complainant_name`,
  s.`full_name` AS `student_name`,
  d.`department_name`
FROM `complaints` c
JOIN `users` u ON c.`complainant_user_id` = u.`user_id`
JOIN `departments` d ON c.`department_id` = d.`department_id`
LEFT JOIN `students` s ON c.`student_id` = s.`student_id`
WHERE c.`status` IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification')
  AND c.`is_deleted` = FALSE;

-- View 4: department_complaint_summary
CREATE OR REPLACE VIEW `department_complaint_summary` AS
SELECT 
  d.`department_name`,
  COUNT(c.`complaint_id`) AS `total_complaints`,
  COALESCE(SUM(c.`status` = 'Resolved'), 0) AS `resolved_complaints`,
  COALESCE(SUM(c.`status` IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification')), 0) AS `pending_complaints`
FROM `departments` d
LEFT JOIN `complaints` c ON d.`department_id` = c.`department_id` AND c.`is_deleted` = FALSE
GROUP BY d.`department_id`, d.`department_name`;
