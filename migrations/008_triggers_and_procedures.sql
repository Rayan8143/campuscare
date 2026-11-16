-- Migration: 008_triggers_and_procedures.sql
-- Purpose : All CampusCare 2.0 stored routines, complaint triggers and the four upgraded views.
-- Type    : DDL only. Fully re-runnable: every object is DROP ... IF EXISTS + CREATE, or
--           CREATE OR REPLACE VIEW.
--
-- PRECONDITIONS (see STAGE2_EXECUTION_GUIDE.md / migrations/admin/S2_A_pre_migration_accounts.sql)
--   * Locked definer accounts exist:
--       'cc_v2_dev_routine_definer'@'localhost'  -- definer of every procedure
--       'cc_v2_dev_trigger_definer'@'localhost'  -- definer of every trigger
--   * The migrator temporarily holds SET_USER_ID (needed to name another account as
--     DEFINER). It must NOT hold SYSTEM_USER, so it can never name root as a definer.
--     SET_USER_ID is revoked again in S2_B.
--   * Table/column/EXECUTE privileges of the definer accounts are granted AFTER this file
--     (S2_B), because MySQL checks definer privileges at execution time, not creation time.
--
-- SECURITY MODEL / TRUST BOUNDARY (read before changing anything here)
--   * The Flask runtime account (complaint_app_v2_dev) has NO INSERT and NO UPDATE privilege
--     on complaints at all (revision 3, decision R13). Complaints are created only by
--     submit_complaint (complainant derived from the authenticated actor, never from a
--     client-supplied complainant_user_id), details change only through
--     update_complaint_details, and status / assignment / department / level / ownership /
--     archive columns change only through the workflow procedures below. This privilege
--     boundary is THE security control.
--   * Separation of duties (R16): nobody approves a resolution they submitted; a Level 4
--     officer determination is recorded as OFFICER_FINAL_DECISION, never as a verification.
--   * Workflow authority comes ONLY from roles/permissions, staff_workflow_assignments
--     memberships, the active assignment ledger and the Primary Officer singleton - never
--     from staff.designation. An assignee may handle a complaint only while holding an exact
--     membership (complaint department, complaint's current level 1..3); Level 4 belongs
--     exclusively to the Primary Officer, who also keeps a global oversight exception.
--   * Account tokens: issue_account_token (runtime) requires an authenticated actor (self
--     password reset, system:manage_users, or staff:verify_account for staff activation);
--     issue_account_token_operator is granted ONLY to the development CLI account
--     cc_v2_dev_activation_cli, never to the Flask runtime account.
--   * @app_status_transition_authorized is a user-defined session variable. Any client can
--     SET it, so it is NOT a security mechanism. The guard trigger uses it only to stop
--     accidental direct status edits by privileged human/migration accounts.
--   * All application traffic shares one MySQL account, so MySQL cannot prove WHICH website
--     user caused a call. Flask must authenticate the user, derive p_actor_user_id from the
--     server-side session (never from request data) and authorize the action first. These
--     procedures then independently re-validate that actor's account state, roles,
--     permissions, department workflow membership, assignment and workflow level, so a bug
--     in one layer is not sufficient to perform an unauthorized transition.
--   * Procedures manage their own transaction (START TRANSACTION ... COMMIT). Callers must
--     invoke them with autocommit enabled and NO open transaction; START TRANSACTION inside
--     a procedure implicitly commits any work the caller left pending.
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 008): every point of the
-- original file was rewritten; the list is in the review document.

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

-- =====================================================================================
-- 0. Remove legacy and superseded objects
-- =====================================================================================
DROP PROCEDURE IF EXISTS `update_complaint_status`;          -- v1 procedure (DEFINER root@localhost)
DROP PROCEDURE IF EXISTS `transition_complaint_status`;
DROP PROCEDURE IF EXISTS `reassign_complaint`;
DROP PROCEDURE IF EXISTS `transfer_primary_officer`;
DROP PROCEDURE IF EXISTS `escalate_complaint`;
DROP PROCEDURE IF EXISTS `soft_delete_complaint`;
DROP PROCEDURE IF EXISTS `issue_account_token`;
DROP PROCEDURE IF EXISTS `issue_account_token_operator`;
DROP PROCEDURE IF EXISTS `redeem_account_token`;
DROP PROCEDURE IF EXISTS `submit_complaint`;
DROP PROCEDURE IF EXISTS `update_complaint_details`;
DROP PROCEDURE IF EXISTS `request_escalation`;
DROP PROCEDURE IF EXISTS `cc_auth_has_permission`;
DROP PROCEDURE IF EXISTS `cc_auth_is_primary_officer`;
DROP PROCEDURE IF EXISTS `cc_auth_department_authority`;
DROP PROCEDURE IF EXISTS `cc_auth_staff_eligible`;
DROP PROCEDURE IF EXISTS `cc_auth_is_assigned_staff`;
DROP PROCEDURE IF EXISTS `cc_token_issue_core`;

-- Explicitly remove the original v1 history trigger BEFORE installing its replacement,
-- so two history triggers can never coexist (no duplicate complaint_history rows).
DROP TRIGGER IF EXISTS `trg_complaint_status_history`;
DROP TRIGGER IF EXISTS `trg_guard_complaint_status_direct_update`;   -- name used by the pre-review draft
DROP TRIGGER IF EXISTS `trg_guard_complaint_sensitive_update`;
DROP TRIGGER IF EXISTS `trg_validate_complaint_identity_insert`;
DROP TRIGGER IF EXISTS `trg_validate_complaint_identity_update`;

DELIMITER $$

-- =====================================================================================
-- 1. Internal authorization helpers (no EXECUTE grant to the runtime account)
--    Implemented as procedures with OUT parameters, not stored functions: creating stored
--    functions with binary logging enabled needs SUPER or log_bin_trust_function_creators.
-- =====================================================================================

CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `cc_auth_has_permission`(
    IN  p_user_id        INT,
    IN  p_permission_key VARCHAR(100),
    OUT p_ok             BOOLEAN
)
READS SQL DATA
SQL SECURITY DEFINER
COMMENT 'Internal: active user in good standing holding the permission through an active role'
BEGIN
    SET p_ok = COALESCE(
        p_user_id IS NOT NULL
        AND p_permission_key IS NOT NULL
        AND EXISTS (
            SELECT 1
              FROM `users` u
              JOIN `user_roles` ur       ON ur.`user_id` = u.`user_id` AND ur.`is_active` = TRUE
              JOIN `role_permissions` rp ON rp.`role_id` = ur.`role_id`
              JOIN `permissions` p       ON p.`permission_id` = rp.`permission_id`
             WHERE u.`user_id` = p_user_id
               AND u.`is_active` = TRUE
               AND p.`permission_key` = p_permission_key)
        AND NOT EXISTS (
            SELECT 1 FROM `staff` st
             WHERE st.`user_id` = p_user_id
               AND (st.`is_active` = FALSE OR st.`verification_status` <> 'VERIFIED')),
        FALSE);
END$$

CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `cc_auth_is_primary_officer`(
    IN  p_user_id INT,
    OUT p_ok      BOOLEAN
)
READS SQL DATA
SQL SECURITY DEFINER
COMMENT 'Internal: actor is the singleton Primary Officer: active account, active officer role, VERIFIED active staff profile'
BEGIN
    SET p_ok = COALESCE(
        p_user_id IS NOT NULL
        AND EXISTS (
            SELECT 1
              FROM `primary_officer_assignment` poa
              JOIN `users` u       ON u.`user_id` = poa.`user_id` AND u.`is_active` = TRUE
              JOIN `user_roles` ur ON ur.`user_id` = poa.`user_id` AND ur.`is_active` = TRUE
              JOIN `roles` r       ON r.`role_id` = ur.`role_id` AND r.`role_name` = 'PRIMARY_COMPLAINT_OFFICER'
              JOIN `staff` st      ON st.`user_id` = poa.`user_id`
                                  AND st.`is_active` = TRUE AND st.`verification_status` = 'VERIFIED'
             WHERE poa.`singleton_id` = 1
               AND poa.`user_id` = p_user_id),
        FALSE);
END$$

-- Department authority = a workflow membership (NOT a job designation) in the complaint's
-- department at a level >= max(2, the complaint's current level). Level 4 can never be
-- satisfied here (memberships are limited to levels 1..3): Level 4 is the officer alone.
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `cc_auth_department_authority`(
    IN  p_user_id          INT,
    IN  p_department_id    INT,
    IN  p_min_level_number INT,
    IN  p_require_escalate BOOLEAN,
    OUT p_ok               BOOLEAN
)
READS SQL DATA
SQL SECURITY DEFINER
COMMENT 'Internal: department-scoped workflow membership at or above the required level'
BEGIN
    SET p_ok = COALESCE(
        p_user_id IS NOT NULL
        AND p_department_id IS NOT NULL
        AND EXISTS (
            SELECT 1
              FROM `staff_workflow_assignments` swa
              JOIN `workflow_levels` wl ON wl.`level_id` = swa.`level_id`
             WHERE swa.`user_id` = p_user_id
               AND swa.`department_id` = p_department_id
               AND wl.`level_number` >= GREATEST(2, COALESCE(p_min_level_number, 1))
               AND (COALESCE(p_require_escalate, FALSE) = FALSE OR swa.`can_escalate` = TRUE)),
        FALSE);
END$$

-- Handling eligibility of a STAFF PROFILE at a workflow level (used for assignees and for
-- reassignment targets). Always required (revision 4): staff profile active, verification
-- VERIFIED, linked users account active. Levels 1..3 additionally: an ACTIVE STAFF role and an
-- EXACT membership (same department, same level) in staff_workflow_assignments, with
-- can_resolve / can_escalate when required. Level 4: the profile must belong to the current
-- Primary Officer singleton holding an ACTIVE PRIMARY_COMPLAINT_OFFICER role, and is never
-- eligible for resolution submission or escalation (there is no level above 4).
-- staff.designation is never consulted.
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `cc_auth_staff_eligible`(
    IN  p_staff_id         INT,
    IN  p_department_id    INT,
    IN  p_level_number     INT,
    IN  p_require_resolve  BOOLEAN,
    IN  p_require_escalate BOOLEAN,
    OUT p_ok               BOOLEAN
)
READS SQL DATA
SQL SECURITY DEFINER
COMMENT 'Internal: verified active staff profile holds the exact membership for this department and level'
BEGIN
    DECLARE v_user_id INT DEFAULT NULL;

    -- Active, VERIFIED staff profile linked to an ACTIVE user account.
    SET v_user_id = (SELECT st.`user_id`
                       FROM `staff` st
                       JOIN `users` u ON u.`user_id` = st.`user_id` AND u.`is_active` = TRUE
                      WHERE st.`staff_id` = p_staff_id
                        AND st.`is_active` = TRUE
                        AND st.`verification_status` = 'VERIFIED');

    IF v_user_id IS NULL OR p_department_id IS NULL OR p_level_number IS NULL THEN
        SET p_ok = FALSE;
    ELSEIF p_level_number >= 4 THEN
        -- Level 4: the active Primary Officer singleton with an active officer role.
        SET p_ok = COALESCE(
            COALESCE(p_require_resolve, FALSE) = FALSE
            AND COALESCE(p_require_escalate, FALSE) = FALSE
            AND EXISTS (SELECT 1
                          FROM `primary_officer_assignment` poa
                          JOIN `user_roles` ur ON ur.`user_id` = poa.`user_id` AND ur.`is_active` = TRUE
                          JOIN `roles` r       ON r.`role_id` = ur.`role_id` AND r.`role_name` = 'PRIMARY_COMPLAINT_OFFICER'
                         WHERE poa.`singleton_id` = 1 AND poa.`user_id` = v_user_id),
            FALSE);
    ELSEIF NOT EXISTS (SELECT 1
                         FROM `user_roles` ur
                         JOIN `roles` r ON r.`role_id` = ur.`role_id` AND r.`role_name` = 'STAFF'
                        WHERE ur.`user_id` = v_user_id AND ur.`is_active` = TRUE) THEN
        -- Levels 1..3 require an active STAFF role.
        SET p_ok = FALSE;
    ELSE
        SET p_ok = COALESCE(
            EXISTS (
                SELECT 1
                  FROM `staff_workflow_assignments` swa
                  JOIN `workflow_levels` wl ON wl.`level_id` = swa.`level_id`
                 WHERE swa.`user_id` = v_user_id
                   AND swa.`department_id` = p_department_id
                   AND wl.`level_number` = p_level_number
                   AND (COALESCE(p_require_resolve, FALSE)  = FALSE OR swa.`can_resolve`  = TRUE)
                   AND (COALESCE(p_require_escalate, FALSE) = FALSE OR swa.`can_escalate` = TRUE)),
            FALSE);
    END IF;
END$$

-- Actor is the currently assigned staff member AND that staff profile is eligible at the
-- complaint's department and current level (cc_auth_staff_eligible).
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `cc_auth_is_assigned_staff`(
    IN  p_user_id          INT,
    IN  p_staff_id         INT,
    IN  p_department_id    INT,
    IN  p_level_number     INT,
    IN  p_require_resolve  BOOLEAN,
    IN  p_require_escalate BOOLEAN,
    OUT p_ok               BOOLEAN
)
READS SQL DATA
SQL SECURITY DEFINER
COMMENT 'Internal: actor is the assigned staff member and holds the level membership'
BEGIN
    DECLARE v_eligible BOOLEAN DEFAULT FALSE;

    IF p_user_id IS NULL OR p_staff_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM `staff` WHERE `staff_id` = p_staff_id AND `user_id` = p_user_id) THEN
        SET p_ok = FALSE;
    ELSE
        CALL `cc_auth_staff_eligible`(p_staff_id, p_department_id, p_level_number,
                                      p_require_resolve, p_require_escalate, v_eligible);
        SET p_ok = COALESCE(v_eligible, FALSE);
    END IF;
END$$

-- =====================================================================================
-- 2. transition_complaint_status
--    "Eligible assignee" = the assigned staff profile holds an EXACT membership for the
--    complaint's department and current level (1..3); at Level 4 only the officer's profile
--    (decision R14). Supervisors never "start" work themselves: they assign, and the
--    eligible assignee accepts (decision R15).
--    Allowed transitions (anything else is rejected):
--      Submitted   -> In Progress : the eligible ASSIGNEE accepts (update_investigation)       ASSIGNMENT_ACCEPTED
--      Escalated   -> In Progress : the eligible ASSIGNEE at the new level accepts              ESCALATION_ACCEPTED
--      In Progress -> Resolution Pending Verification : eligible assignee with can_resolve
--                                   (submit_resolution), Levels 1..3; notes required           RESOLUTION_SUBMITTED
--      RPV         -> Resolved    : Primary Officer (verify_resolution); the officer may NOT
--                                   approve a resolution they submitted themselves (R16)        RESOLUTION_APPROVED
--      RPV         -> In Progress : Primary Officer (verify_resolution); remarks required       RESOLUTION_RETURNED
--      In Progress -> Resolved    : Level 4 only; the officer, as the Level 4 assignee
--                                   (verify_resolution); reason required; NO verification row
--                                   is written (it is not an independent verification)          OFFICER_FINAL_DECISION
--      Submitted | In Progress | Escalated -> Rejected : dept authority or officer (reject);
--                                   reason required; at Level 4 recorded as                     OFFICER_FINAL_DECISION
--                                   otherwise                                                    REJECTION
--      * -> Escalated : only via escalate_complaint.   Resolved / Rejected : final.
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `transition_complaint_status`(
    IN p_complaint_id  INT,
    IN p_new_status    VARCHAR(40),
    IN p_actor_user_id INT,
    IN p_remarks       TEXT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Authoritative complaint status state machine with actor re-validation'
BEGIN
    DECLARE v_not_found       BOOLEAN DEFAULT FALSE;
    DECLARE v_status          VARCHAR(40) DEFAULT NULL;
    DECLARE v_is_deleted      BOOLEAN DEFAULT NULL;
    DECLARE v_assigned_staff  INT DEFAULT NULL;
    DECLARE v_department_id   INT DEFAULT NULL;
    DECLARE v_level_number    INT DEFAULT NULL;
    DECLARE v_is_officer      BOOLEAN DEFAULT FALSE;
    DECLARE v_dept_authority  BOOLEAN DEFAULT FALSE;
    DECLARE v_is_assigned     BOOLEAN DEFAULT FALSE;
    DECLARE v_perm            BOOLEAN DEFAULT FALSE;
    DECLARE v_perm2           BOOLEAN DEFAULT FALSE;
    DECLARE v_allowed         BOOLEAN DEFAULT FALSE;
    DECLARE v_action          VARCHAR(40) DEFAULT NULL;
    DECLARE v_remarks         TEXT DEFAULT NULL;
    DECLARE v_history_remarks VARCHAR(255) DEFAULT NULL;
    DECLARE v_rows            INT DEFAULT 0;
    DECLARE v_assignee_ok     BOOLEAN DEFAULT FALSE;
    DECLARE v_submitter_user  INT DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
            @app_action_type = NULL, @app_status_remarks = NULL;
        RESIGNAL;
    END;

    -- Never trust session context left behind by the caller.
    SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
        @app_action_type = NULL, @app_status_remarks = NULL;
    SET v_remarks = NULLIF(TRIM(p_remarks), '');

    IF p_actor_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authenticated actor user ID is required.';
    END IF;
    IF p_complaint_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint ID is required.';
    END IF;
    IF p_new_status IS NULL
       OR p_new_status NOT IN ('In Progress', 'Resolution Pending Verification', 'Resolved', 'Rejected') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid target status (use escalate_complaint for escalations; Submitted is initial only).';
    END IF;

    START TRANSACTION;

    -- Lock the complaint row for the whole decision (prevents concurrent double transitions).
    SELECT c.`status`, c.`is_deleted`, c.`assigned_staff_id`, c.`department_id`, wl.`level_number`
      INTO v_status, v_is_deleted, v_assigned_staff, v_department_id, v_level_number
      FROM `complaints` c
      JOIN `workflow_levels` wl ON wl.`level_id` = c.`current_level_id`
     WHERE c.`complaint_id` = p_complaint_id
       FOR UPDATE OF c;

    IF v_not_found OR v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;
    IF v_is_deleted IS TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot transition an archived complaint.';
    END IF;
    IF v_status IN ('Resolved', 'Rejected') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot modify a closed or finalized complaint.';
    END IF;
    IF v_status = p_new_status THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint is already in the requested status.';
    END IF;

    CALL `cc_auth_is_primary_officer`(p_actor_user_id, v_is_officer);
    CALL `cc_auth_department_authority`(p_actor_user_id, v_department_id, v_level_number, FALSE, v_dept_authority);
    CALL `cc_auth_is_assigned_staff`(p_actor_user_id, v_assigned_staff, v_department_id, v_level_number,
                                     FALSE, FALSE, v_is_assigned);

    -- Work starts or resumes: there must be an assignee eligible at the current level.
    IF p_new_status = 'In Progress' THEN
        IF v_assigned_staff IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint is awaiting assignment at its current workflow level.';
        END IF;
        CALL `cc_auth_staff_eligible`(v_assigned_staff, v_department_id, v_level_number, FALSE, FALSE, v_assignee_ok);
        IF v_assignee_ok IS NOT TRUE THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Assignee lacks membership at the current workflow level; reassign first.';
        END IF;
    END IF;

    IF p_new_status = 'In Progress' AND v_status IN ('Submitted', 'Escalated') THEN
        -- Acceptance is by the eligible assignee only (R15).
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:update_investigation', v_perm);
        SET v_allowed = v_is_assigned AND v_perm;
        SET v_action = IF(v_status = 'Escalated', 'ESCALATION_ACCEPTED', 'ASSIGNMENT_ACCEPTED');

    ELSEIF p_new_status = 'Resolution Pending Verification' AND v_status = 'In Progress' THEN
        IF v_remarks IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Resolution notes are required.';
        END IF;
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:submit_resolution', v_perm);
        -- can_resolve on the exact level membership is required (Level 4 never qualifies).
        CALL `cc_auth_is_assigned_staff`(p_actor_user_id, v_assigned_staff, v_department_id, v_level_number,
                                         TRUE, FALSE, v_perm2);
        SET v_allowed = v_perm2 AND v_perm;
        SET v_action = 'RESOLUTION_SUBMITTED';

    ELSEIF p_new_status = 'Resolved' AND v_status = 'In Progress' AND v_level_number >= 4 THEN
        IF v_remarks IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A decision reason is required.';
        END IF;
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:verify_resolution', v_perm);
        SET v_allowed = v_is_officer AND v_is_assigned AND v_perm;
        SET v_action = 'OFFICER_FINAL_DECISION';

    ELSEIF p_new_status = 'Resolved' AND v_status = 'Resolution Pending Verification' THEN
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:verify_resolution', v_perm);
        SET v_allowed = v_is_officer AND v_perm;
        SET v_action = 'RESOLUTION_APPROVED';
        -- Separation of duties (R16): nobody approves a resolution they submitted.
        SET v_submitter_user = (SELECT st.`user_id`
                                  FROM `resolution_verifications` rv
                                  JOIN `staff` st ON st.`staff_id` = rv.`submitted_by_staff_id`
                                 WHERE rv.`complaint_id` = p_complaint_id AND rv.`decision` = 'PENDING');
        IF v_submitter_user <=> p_actor_user_id THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Separation of duties: a resolution cannot be approved by its submitter.';
        END IF;

    ELSEIF p_new_status = 'In Progress' AND v_status = 'Resolution Pending Verification' THEN
        IF v_remarks IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Remarks are required when returning a resolution.';
        END IF;
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:verify_resolution', v_perm);
        SET v_allowed = v_is_officer AND v_perm;
        SET v_action = 'RESOLUTION_RETURNED';

    ELSEIF p_new_status = 'Rejected' AND v_status IN ('Submitted', 'In Progress', 'Escalated') THEN
        IF v_remarks IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A rejection reason is required.';
        END IF;
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:reject', v_perm);
        SET v_allowed = (v_is_officer OR v_dept_authority) AND v_perm;
        SET v_action = IF(v_level_number >= 4, 'OFFICER_FINAL_DECISION', 'REJECTION');

    ELSE
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This status transition is not permitted.';
    END IF;

    IF v_allowed IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied for this complaint transition.';
    END IF;

    IF v_action = 'OFFICER_FINAL_DECISION' AND CHAR_LENGTH(v_remarks) > 200 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Decision reason must not exceed 200 characters.';
    END IF;
    IF v_action NOT IN ('RESOLUTION_SUBMITTED', 'OFFICER_FINAL_DECISION')
       AND v_remarks IS NOT NULL AND CHAR_LENGTH(v_remarks) > 255 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Remarks must not exceed 255 characters.';
    END IF;

    -- Ledgers. An officer final decision is recorded ONLY in the timeline (action, decision,
    -- reason, actor, time); it never fabricates a staff submission or an independent verification.
    IF v_action = 'RESOLUTION_SUBMITTED' THEN
        INSERT INTO `resolution_verifications` (`complaint_id`, `submitted_by_staff_id`, `resolution_notes`)
        VALUES (p_complaint_id, v_assigned_staff, v_remarks);
        SET v_history_remarks = 'Resolution submitted for Primary Officer verification';
    ELSEIF v_action = 'OFFICER_FINAL_DECISION' THEN
        SET v_history_remarks = CONCAT('Decision: ', p_new_status, '. Reason: ', v_remarks);
    ELSEIF v_action IN ('RESOLUTION_APPROVED', 'RESOLUTION_RETURNED') THEN
        UPDATE `resolution_verifications`
           SET `decision`        = IF(v_action = 'RESOLUTION_APPROVED', 'APPROVED', 'RETURNED'),
               `officer_user_id` = p_actor_user_id,
               `officer_remarks` = v_remarks,
               `reviewed_at`     = NOW()
         WHERE `complaint_id` = p_complaint_id
           AND `decision` = 'PENDING';
        SET v_rows = ROW_COUNT();
        IF v_rows <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No pending resolution verification exists for this complaint.';
        END IF;
        SET v_history_remarks = COALESCE(v_remarks,
            IF(v_action = 'RESOLUTION_APPROVED', 'Resolution approved by the Primary Complaint Officer',
                                                'Resolution returned for reinvestigation'));
    ELSE
        SET v_history_remarks = COALESCE(v_remarks, 'Status updated via application workflow');
    END IF;

    -- Context for the history trigger (attribution only; see header).
    SET @app_status_transition_authorized = TRUE,
        @app_current_user_id = p_actor_user_id,
        @app_action_type     = v_action,
        @app_status_remarks  = v_history_remarks;

    UPDATE `complaints`
       SET `status`      = p_new_status,
           `resolved_at` = IF(p_new_status = 'Resolved', NOW(), NULL)
     WHERE `complaint_id` = p_complaint_id;

    SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
        @app_action_type = NULL, @app_status_remarks = NULL;

    COMMIT;
END$$

-- =====================================================================================
-- 3. escalate_complaint  (the only path that changes complaints.current_level_id)
--    Officer (escalate_tier): any higher level.
--    Department authority with can_escalate at >= max(2, current level) (escalate_tier):
--    exactly one level up. Level 4 targets therefore come from a Level 3 member or the officer.
--    R15 sequence: (1) escalation row with reason and actor, (2) workflow level updated,
--    (3) previous active assignment closed, (4) status 'Escalated' + unassigned = awaiting
--    assignment, (5) reassign_complaint to an exact member of the new level, (6) that assignee
--    accepts (Escalated -> In Progress). The ledger and timeline keep the full trail.
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `escalate_complaint`(
    IN p_complaint_id  INT,
    IN p_to_level_id   INT,
    IN p_actor_user_id INT,
    IN p_reason        TEXT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Escalate a complaint to a higher workflow level and record the escalation ledger row'
BEGIN
    DECLARE v_not_found      BOOLEAN DEFAULT FALSE;
    DECLARE v_status         VARCHAR(40) DEFAULT NULL;
    DECLARE v_is_deleted     BOOLEAN DEFAULT NULL;
    DECLARE v_department_id  INT DEFAULT NULL;
    DECLARE v_level_id       INT DEFAULT NULL;
    DECLARE v_level_number   INT DEFAULT NULL;
    DECLARE v_to_number      INT DEFAULT NULL;
    DECLARE v_is_officer     BOOLEAN DEFAULT FALSE;
    DECLARE v_dept_authority BOOLEAN DEFAULT FALSE;
    DECLARE v_perm           BOOLEAN DEFAULT FALSE;
    DECLARE v_allowed        BOOLEAN DEFAULT FALSE;
    DECLARE v_reason         TEXT DEFAULT NULL;
    DECLARE v_history        VARCHAR(255) DEFAULT NULL;
    DECLARE v_closed         INT DEFAULT 0;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
            @app_action_type = NULL, @app_status_remarks = NULL;
        RESIGNAL;
    END;

    SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
        @app_action_type = NULL, @app_status_remarks = NULL;
    SET v_reason = NULLIF(TRIM(p_reason), '');

    IF p_actor_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authenticated actor user ID is required.';
    END IF;
    IF p_complaint_id IS NULL OR p_to_level_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint ID and target level are required.';
    END IF;
    IF v_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An escalation reason is required.';
    END IF;

    START TRANSACTION;

    SELECT c.`status`, c.`is_deleted`, c.`department_id`, c.`current_level_id`, wl.`level_number`
      INTO v_status, v_is_deleted, v_department_id, v_level_id, v_level_number
      FROM `complaints` c
      JOIN `workflow_levels` wl ON wl.`level_id` = c.`current_level_id`
     WHERE c.`complaint_id` = p_complaint_id
       FOR UPDATE OF c;

    IF v_not_found OR v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;
    IF v_is_deleted IS TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot escalate an archived complaint.';
    END IF;
    IF v_status NOT IN ('Submitted', 'In Progress', 'Escalated') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only open complaints not awaiting verification can be escalated.';
    END IF;

    SET v_to_number = (SELECT `level_number` FROM `workflow_levels` WHERE `level_id` = p_to_level_id);
    IF v_to_number IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown workflow level.';
    END IF;
    IF v_to_number <= v_level_number THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Escalation must move to a higher workflow level.';
    END IF;

    CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:escalate_tier', v_perm);
    CALL `cc_auth_is_primary_officer`(p_actor_user_id, v_is_officer);
    SET v_allowed = v_is_officer AND v_perm;
    IF v_allowed IS NOT TRUE THEN
        CALL `cc_auth_department_authority`(p_actor_user_id, v_department_id, v_level_number, TRUE, v_dept_authority);
        SET v_allowed = v_dept_authority AND v_perm AND (v_to_number = v_level_number + 1);
    END IF;
    IF v_allowed IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied for this escalation.';
    END IF;

    INSERT INTO `complaint_escalations`
        (`complaint_id`, `from_level_id`, `to_level_id`, `escalated_by_user_id`, `escalation_reason`)
    VALUES (p_complaint_id, v_level_id, p_to_level_id, p_actor_user_id, v_reason);

    -- R15: the previous assignee loses the investigation. Close the active ledger row (kept as
    -- history, attributed to the escalating actor); the complaint then waits, status
    -- 'Escalated' and unassigned, for an eligible member of the new level to be assigned
    -- (reassign_complaint) and to accept it (transition_complaint_status -> In Progress).
    UPDATE `complaint_assignments`
       SET `is_active` = FALSE,
           `unassigned_at` = NOW(),
           `unassigned_by_user_id` = p_actor_user_id
     WHERE `complaint_id` = p_complaint_id
       AND `is_active` = TRUE;
    SET v_closed = ROW_COUNT();

    SET v_history = CONCAT('Escalated from workflow level ', v_level_number, ' to level ', v_to_number,
                           IF(v_closed > 0, '; previous assignment closed, awaiting assignment', '; awaiting assignment'));

    SET @app_status_transition_authorized = TRUE,
        @app_current_user_id = p_actor_user_id,
        @app_action_type     = 'ESCALATION',
        @app_status_remarks  = v_history;

    UPDATE `complaints`
       SET `current_level_id`  = p_to_level_id,
           `status`            = 'Escalated',
           `assigned_staff_id` = NULL
     WHERE `complaint_id` = p_complaint_id;

    -- Status unchanged (already Escalated): the history trigger does not fire, so record the
    -- escalation in the timeline here. Exactly one history row per escalation either way.
    IF v_status = 'Escalated' THEN
        INSERT INTO `complaint_history`
            (`complaint_id`, `old_status`, `new_status`, `changed_by_user_id`, `action_type`, `remarks`)
        VALUES (p_complaint_id, 'Escalated', 'Escalated', p_actor_user_id, 'ESCALATION', v_history);
    END IF;

    SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
        @app_action_type = NULL, @app_status_remarks = NULL;

    COMMIT;
END$$

-- =====================================================================================
-- 3b. request_escalation  (assigned staff ASK for escalation; executing it is escalate_complaint)
--     Requires complaint:request_escalation AND an exact membership at the complaint's
--     current level with can_escalate = TRUE. Writes one timeline row; status, level and
--     assignment are unchanged. No new table is introduced (22-table design preserved).
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `request_escalation`(
    IN p_complaint_id  INT,
    IN p_actor_user_id INT,
    IN p_reason        VARCHAR(255)
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Record an escalation request by the eligible assigned staff member (can_escalate)'
BEGIN
    DECLARE v_not_found      BOOLEAN DEFAULT FALSE;
    DECLARE v_status         VARCHAR(40) DEFAULT NULL;
    DECLARE v_is_deleted     BOOLEAN DEFAULT NULL;
    DECLARE v_assigned_staff INT DEFAULT NULL;
    DECLARE v_department_id  INT DEFAULT NULL;
    DECLARE v_level_number   INT DEFAULT NULL;
    DECLARE v_is_assigned    BOOLEAN DEFAULT FALSE;
    DECLARE v_perm           BOOLEAN DEFAULT FALSE;
    DECLARE v_reason         VARCHAR(255) DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_reason = NULLIF(TRIM(p_reason), '');
    IF p_actor_user_id IS NULL OR p_complaint_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint ID and authenticated actor user ID are required.';
    END IF;
    IF v_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An escalation request reason is required.';
    END IF;

    START TRANSACTION;

    SELECT c.`status`, c.`is_deleted`, c.`assigned_staff_id`, c.`department_id`, wl.`level_number`
      INTO v_status, v_is_deleted, v_assigned_staff, v_department_id, v_level_number
      FROM `complaints` c
      JOIN `workflow_levels` wl ON wl.`level_id` = c.`current_level_id`
     WHERE c.`complaint_id` = p_complaint_id
       FOR UPDATE OF c;

    IF v_not_found OR v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;
    IF v_is_deleted IS TRUE OR v_status NOT IN ('Submitted', 'In Progress') OR v_level_number >= 4 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Escalation cannot be requested for this complaint.';
    END IF;

    CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:request_escalation', v_perm);
    CALL `cc_auth_is_assigned_staff`(p_actor_user_id, v_assigned_staff, v_department_id, v_level_number,
                                     FALSE, TRUE, v_is_assigned);
    IF (v_perm AND v_is_assigned) IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Authorization denied: assigned staff with can_escalate at this level only.';
    END IF;

    INSERT INTO `complaint_history`
        (`complaint_id`, `old_status`, `new_status`, `changed_by_user_id`, `action_type`, `remarks`)
    VALUES (p_complaint_id, v_status, v_status, p_actor_user_id, 'ESCALATION_REQUESTED', v_reason);

    COMMIT;
END$$

-- =====================================================================================
-- 4. reassign_complaint  (the only path that changes assigned_staff_id / department_id)
--    Same department : department authority (assign_staff if unassigned, else reassign_staff)
--    Any department  : Primary Officer (reassign_global); department_id follows the staff member.
--    Ledger first, cache second; the guard trigger rejects any cache value that does not
--    equal the active ledger row.
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `reassign_complaint`(
    IN p_complaint_id   INT,
    IN p_new_staff_id   INT,
    IN p_acting_user_id INT,
    IN p_reason         VARCHAR(255)
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Assign or reassign a complaint through the canonical assignment ledger'
BEGIN
    DECLARE v_not_found      BOOLEAN DEFAULT FALSE;
    DECLARE v_status         VARCHAR(40) DEFAULT NULL;
    DECLARE v_is_deleted     BOOLEAN DEFAULT NULL;
    DECLARE v_current_staff  INT DEFAULT NULL;
    DECLARE v_department_id  INT DEFAULT NULL;
    DECLARE v_level_number   INT DEFAULT NULL;
    DECLARE v_staff_dept     INT DEFAULT NULL;
    DECLARE v_staff_verified VARCHAR(20) DEFAULT NULL;
    DECLARE v_staff_active   BOOLEAN DEFAULT NULL;
    DECLARE v_staff_user     INT DEFAULT NULL;
    DECLARE v_is_officer     BOOLEAN DEFAULT FALSE;
    DECLARE v_dept_authority BOOLEAN DEFAULT FALSE;
    DECLARE v_perm           BOOLEAN DEFAULT FALSE;
    DECLARE v_allowed        BOOLEAN DEFAULT FALSE;
    DECLARE v_rows           INT DEFAULT 0;
    DECLARE v_reason         VARCHAR(255) DEFAULT NULL;
    DECLARE v_action         VARCHAR(40) DEFAULT NULL;
    DECLARE v_target_ok      BOOLEAN DEFAULT FALSE;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_reason = NULLIF(TRIM(p_reason), '');

    IF p_acting_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authenticated user ID is required for assignments.';
    END IF;
    IF p_complaint_id IS NULL OR p_new_staff_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint ID and staff ID are required.';
    END IF;
    IF v_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An assignment reason is required.';
    END IF;

    START TRANSACTION;

    SELECT c.`status`, c.`is_deleted`, c.`assigned_staff_id`, c.`department_id`, wl.`level_number`
      INTO v_status, v_is_deleted, v_current_staff, v_department_id, v_level_number
      FROM `complaints` c
      JOIN `workflow_levels` wl ON wl.`level_id` = c.`current_level_id`
     WHERE c.`complaint_id` = p_complaint_id
       FOR UPDATE OF c;

    IF v_not_found OR v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;
    IF v_is_deleted IS TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot assign an archived complaint.';
    END IF;
    IF v_status IN ('Resolved', 'Rejected', 'Resolution Pending Verification') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint cannot be reassigned in its current status.';
    END IF;

    SET v_not_found = FALSE;
    SELECT `department_id`, `verification_status`, `is_active`, `user_id`
      INTO v_staff_dept, v_staff_verified, v_staff_active, v_staff_user
      FROM `staff`
     WHERE `staff_id` = p_new_staff_id
       FOR SHARE;
    IF v_not_found THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Target staff member does not exist.';
    END IF;
    IF v_staff_verified <> 'VERIFIED' OR v_staff_active IS NOT TRUE OR v_staff_user IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Target staff member must be verified, active and linked to a user.';
    END IF;
    -- The target must be fully eligible (cc_auth_staff_eligible): active VERIFIED profile, active
    -- users account, active STAFF role and an exact membership for its department at the
    -- complaint's CURRENT level (Level 4: only the active Primary Officer). At Level 4 the complaint
    -- keeps its responsible department (the officer acts globally, not as a department member).
    IF v_level_number >= 4 THEN
        SET v_staff_dept = v_department_id;
    END IF;
    CALL `cc_auth_staff_eligible`(p_new_staff_id, v_staff_dept, v_level_number, FALSE, FALSE, v_target_ok);
    IF v_target_ok IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Target staff not eligible: inactive account/role or no membership at the current level.';
    END IF;
    IF v_current_staff <=> p_new_staff_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint is already assigned to this staff member.';
    END IF;

    CALL `cc_auth_is_primary_officer`(p_acting_user_id, v_is_officer);
    CALL `cc_auth_has_permission`(p_acting_user_id, 'complaint:reassign_global', v_perm);
    SET v_allowed = v_is_officer AND v_perm;
    IF v_allowed IS NOT TRUE THEN
        IF v_staff_dept <> v_department_id THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cross-department reassignment requires the Primary Complaint Officer.';
        END IF;
        CALL `cc_auth_department_authority`(p_acting_user_id, v_department_id, v_level_number, FALSE, v_dept_authority);
        CALL `cc_auth_has_permission`(p_acting_user_id,
             IF(v_current_staff IS NULL, 'complaint:assign_staff', 'complaint:reassign_staff'), v_perm);
        SET v_allowed = v_dept_authority AND v_perm;
    END IF;
    IF v_allowed IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied for this assignment.';
    END IF;

    -- 1. Close the current ledger row (must match the cached pointer exactly).
    UPDATE `complaint_assignments`
       SET `is_active` = FALSE,
           `unassigned_at` = NOW(),
           `unassigned_by_user_id` = p_acting_user_id
     WHERE `complaint_id` = p_complaint_id
       AND `is_active` = TRUE
       AND `assigned_staff_id` <=> v_current_staff;
    SET v_rows = ROW_COUNT();
    IF (v_current_staff IS NULL AND v_rows <> 0) OR (v_current_staff IS NOT NULL AND v_rows <> 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Assignment ledger does not match the complaint; reconcile manually.';
    END IF;

    -- 2. Open the new ledger row (uq_single_active_assignment makes a second active row impossible).
    INSERT INTO `complaint_assignments`
        (`complaint_id`, `assigned_staff_id`, `assigned_by_user_id`, `assignment_source`,
         `assignment_reason`, `assigned_at`, `is_active`)
    VALUES (p_complaint_id, p_new_staff_id, p_acting_user_id, 'WORKFLOW', v_reason, NOW(), TRUE);

    -- 3. Synchronize the cached pointer (validated against the ledger by the guard trigger).
    UPDATE `complaints`
       SET `assigned_staff_id` = p_new_staff_id,
           `department_id`     = v_staff_dept
     WHERE `complaint_id` = p_complaint_id;

    -- 4. Timeline entry (status unchanged, so the status-history trigger does not fire).
    SET v_action = CASE
        WHEN v_staff_dept <> v_department_id THEN 'REASSIGNMENT_CROSS_DEPARTMENT'
        WHEN v_current_staff IS NULL         THEN 'ASSIGNMENT'
        ELSE 'REASSIGNMENT'
    END;
    INSERT INTO `complaint_history`
        (`complaint_id`, `old_status`, `new_status`, `changed_by_user_id`, `action_type`, `remarks`)
    VALUES (p_complaint_id, v_status, v_status, p_acting_user_id, v_action, v_reason);

    COMMIT;
END$$

-- =====================================================================================
-- 4b. update_complaint_details  (decision R13; the runtime account has NO UPDATE on complaints)
--     Editable fields: title, description, category, priority (NULL argument = unchanged).
--     Owner path      : actor is the complainant, holds complaint:edit_own, and the complaint
--                       is still 'Submitted' (no investigation has been accepted).
--     Supervisory path: Primary Officer, or department authority at >= max(2, current level),
--                       holding complaint:edit_details; any non-final status; reason required.
--     Audit           : one complaint_history row DETAILS_EDITED with editor, time, the list of
--                       modified fields and the reason.
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `update_complaint_details`(
    IN p_complaint_id  INT,
    IN p_actor_user_id INT,
    IN p_title         VARCHAR(180),
    IN p_description   TEXT,
    IN p_category      VARCHAR(50),
    IN p_priority      VARCHAR(10),
    IN p_reason        VARCHAR(150)
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Authorized, audited edit of complaint title/description/category/priority'
BEGIN
    DECLARE v_not_found      BOOLEAN DEFAULT FALSE;
    DECLARE v_status         VARCHAR(40) DEFAULT NULL;
    DECLARE v_is_deleted     BOOLEAN DEFAULT NULL;
    DECLARE v_owner          INT DEFAULT NULL;
    DECLARE v_department_id  INT DEFAULT NULL;
    DECLARE v_level_number   INT DEFAULT NULL;
    DECLARE v_old_title      VARCHAR(180) DEFAULT NULL;
    DECLARE v_old_desc       TEXT DEFAULT NULL;
    DECLARE v_old_category   VARCHAR(50) DEFAULT NULL;
    DECLARE v_old_priority   VARCHAR(10) DEFAULT NULL;
    DECLARE v_title          VARCHAR(180) DEFAULT NULL;
    DECLARE v_description    TEXT DEFAULT NULL;
    DECLARE v_reason         VARCHAR(150) DEFAULT NULL;
    DECLARE v_is_officer     BOOLEAN DEFAULT FALSE;
    DECLARE v_dept_authority BOOLEAN DEFAULT FALSE;
    DECLARE v_perm_own       BOOLEAN DEFAULT FALSE;
    DECLARE v_perm_sup       BOOLEAN DEFAULT FALSE;
    DECLARE v_owner_path     BOOLEAN DEFAULT FALSE;
    DECLARE v_sup_path       BOOLEAN DEFAULT FALSE;
    DECLARE v_fields         VARCHAR(60) DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_title = NULLIF(TRIM(p_title), '');
    SET v_description = NULLIF(TRIM(p_description), '');
    SET v_reason = NULLIF(TRIM(p_reason), '');

    IF p_actor_user_id IS NULL OR p_complaint_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint ID and authenticated actor user ID are required.';
    END IF;
    IF v_title IS NULL AND v_description IS NULL AND p_category IS NULL AND p_priority IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No editable field was supplied.';
    END IF;
    IF p_category IS NOT NULL
       AND p_category NOT IN ('Infrastructure', 'Hostel', 'Laboratory', 'Network', 'Cleanliness', 'Other') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid complaint category.';
    END IF;
    IF p_priority IS NOT NULL AND p_priority NOT IN ('Low', 'Medium', 'High') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid complaint priority.';
    END IF;

    START TRANSACTION;

    SELECT c.`status`, c.`is_deleted`, c.`complainant_user_id`, c.`department_id`, wl.`level_number`,
           c.`title`, c.`description`, c.`category`, c.`priority`
      INTO v_status, v_is_deleted, v_owner, v_department_id, v_level_number,
           v_old_title, v_old_desc, v_old_category, v_old_priority
      FROM `complaints` c
      JOIN `workflow_levels` wl ON wl.`level_id` = c.`current_level_id`
     WHERE c.`complaint_id` = p_complaint_id
       FOR UPDATE OF c;

    IF v_not_found OR v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;
    IF v_is_deleted IS TRUE OR v_status IN ('Resolved', 'Rejected') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Archived or finalized complaints cannot be edited.';
    END IF;

    CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:edit_own', v_perm_own);
    CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:edit_details', v_perm_sup);
    CALL `cc_auth_is_primary_officer`(p_actor_user_id, v_is_officer);
    CALL `cc_auth_department_authority`(p_actor_user_id, v_department_id, v_level_number, FALSE, v_dept_authority);

    SET v_owner_path = (v_owner = p_actor_user_id) AND v_perm_own AND v_status = 'Submitted';
    SET v_sup_path   = (v_is_officer OR v_dept_authority) AND v_perm_sup;

    IF (v_owner_path OR v_sup_path) IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Authorization denied: owner edits only while Submitted; others need edit_details authority.';
    END IF;
    IF v_owner_path IS NOT TRUE AND v_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reason is required for supervisory edits.';
    END IF;

    SET v_fields = CONCAT_WS(',',
        IF(v_title IS NOT NULL AND NOT (v_title <=> v_old_title), 'title', NULL),
        IF(v_description IS NOT NULL AND NOT (v_description <=> v_old_desc), 'description', NULL),
        IF(p_category IS NOT NULL AND NOT (p_category <=> v_old_category), 'category', NULL),
        IF(p_priority IS NOT NULL AND NOT (p_priority <=> v_old_priority), 'priority', NULL));
    IF v_fields IS NULL OR v_fields = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The supplied values do not change the complaint.';
    END IF;

    UPDATE `complaints`
       SET `title`       = COALESCE(v_title, `title`),
           `description` = COALESCE(v_description, `description`),
           `category`    = COALESCE(p_category, `category`),
           `priority`    = COALESCE(p_priority, `priority`)
     WHERE `complaint_id` = p_complaint_id;

    INSERT INTO `complaint_history`
        (`complaint_id`, `old_status`, `new_status`, `changed_by_user_id`, `action_type`, `remarks`)
    VALUES (p_complaint_id, v_status, v_status, p_actor_user_id, 'DETAILS_EDITED',
            CONCAT('Fields: ', v_fields,
                   IF(v_owner_path, ' (complainant edit)', ' (supervisory edit)'),
                   IF(v_reason IS NULL, '', CONCAT('; reason: ', v_reason))));

    COMMIT;
END$$

-- =====================================================================================
-- 5. soft_delete_complaint  (the only path that sets is_deleted; audit rows are retained)
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `soft_delete_complaint`(
    IN p_complaint_id  INT,
    IN p_actor_user_id INT,
    IN p_reason        VARCHAR(255)
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Archive a complaint (Primary Officer only); history, assignments, escalations and verifications are kept'
BEGIN
    DECLARE v_not_found  BOOLEAN DEFAULT FALSE;
    DECLARE v_status     VARCHAR(40) DEFAULT NULL;
    DECLARE v_is_deleted BOOLEAN DEFAULT NULL;
    DECLARE v_is_officer BOOLEAN DEFAULT FALSE;
    DECLARE v_perm       BOOLEAN DEFAULT FALSE;
    DECLARE v_reason     VARCHAR(255) DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_reason = NULLIF(TRIM(p_reason), '');
    IF p_actor_user_id IS NULL OR p_complaint_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint ID and authenticated actor user ID are required.';
    END IF;
    IF v_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An archive reason is required.';
    END IF;

    START TRANSACTION;

    SELECT `status`, `is_deleted` INTO v_status, v_is_deleted
      FROM `complaints` WHERE `complaint_id` = p_complaint_id FOR UPDATE;
    IF v_not_found OR v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist.';
    END IF;
    IF v_is_deleted IS TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint is already archived.';
    END IF;

    CALL `cc_auth_is_primary_officer`(p_actor_user_id, v_is_officer);
    CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:soft_delete', v_perm);
    IF (v_is_officer AND v_perm) IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied: only the Primary Complaint Officer can archive complaints.';
    END IF;

    UPDATE `complaints`
       SET `is_deleted` = TRUE, `deleted_at` = NOW(), `deleted_by_user_id` = p_actor_user_id
     WHERE `complaint_id` = p_complaint_id;

    INSERT INTO `complaint_history`
        (`complaint_id`, `old_status`, `new_status`, `changed_by_user_id`, `action_type`, `remarks`)
    VALUES (p_complaint_id, v_status, v_status, p_actor_user_id, 'SOFT_DELETE', v_reason);

    COMMIT;
END$$

-- =====================================================================================
-- 6. transfer_primary_officer  (bootstrap when the singleton is empty, transfer otherwise)
--    Concurrency: the singleton row (or, when empty, the PK gap) is locked FOR UPDATE; two
--    concurrent bootstraps cannot both commit (deadlock / duplicate PK -> one rolls back).
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `transfer_primary_officer`(
    IN p_new_officer_user_id   INT,
    IN p_acting_admin_user_id  INT,
    IN p_reason                VARCHAR(255)
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Appoint or transfer the singleton Primary Complaint Officer with history'
BEGIN
    DECLARE v_not_found        BOOLEAN DEFAULT FALSE;
    DECLARE v_admin_ok         BOOLEAN DEFAULT FALSE;
    DECLARE v_officer_role_id  INT DEFAULT NULL;
    DECLARE v_new_active       BOOLEAN DEFAULT NULL;
    DECLARE v_has_row          BOOLEAN DEFAULT FALSE;
    DECLARE v_current_user_id  INT DEFAULT NULL;
    DECLARE v_current_started  DATETIME DEFAULT NULL;
    DECLARE v_current_by       INT DEFAULT NULL;
    DECLARE v_current_reason   VARCHAR(255) DEFAULT NULL;
    DECLARE v_reason           VARCHAR(255) DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_reason = NULLIF(TRIM(p_reason), '');
    IF p_new_officer_user_id IS NULL OR p_acting_admin_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'New officer and authenticated administrator IDs are required.';
    END IF;
    IF v_reason IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A transition reason is required.';
    END IF;
    IF p_new_officer_user_id = p_acting_admin_user_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An administrator cannot appoint themselves as Primary Officer.';
    END IF;

    START TRANSACTION;

    CALL `cc_auth_has_permission`(p_acting_admin_user_id, 'system:manage_roles', v_admin_ok);
    IF v_admin_ok IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied: system:manage_roles is required.';
    END IF;

    SET v_officer_role_id = (SELECT `role_id` FROM `roles` WHERE `role_name` = 'PRIMARY_COMPLAINT_OFFICER');
    IF v_officer_role_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'PRIMARY_COMPLAINT_OFFICER role is missing.';
    END IF;

    SET v_not_found = FALSE;
    SELECT `is_active` INTO v_new_active FROM `users` WHERE `user_id` = p_new_officer_user_id FOR UPDATE;
    IF v_not_found THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proposed officer user does not exist.';
    END IF;
    IF v_new_active IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proposed officer must have an activated account.';
    END IF;
    -- Eligibility: a valid, active, VERIFIED staff profile is mandatory; student and external
    -- complainant accounts can never hold Level 4 authority. No exception path exists.
    IF NOT EXISTS (SELECT 1 FROM `staff` WHERE `user_id` = p_new_officer_user_id
                    AND `is_active` = TRUE AND `verification_status` = 'VERIFIED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proposed officer must have an active, VERIFIED staff profile.';
    END IF;
    IF EXISTS (SELECT 1 FROM `students` WHERE `user_id` = p_new_officer_user_id)
       OR EXISTS (SELECT 1 FROM `external_complainants` WHERE `user_id` = p_new_officer_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student or external complainant accounts cannot be appointed Primary Officer.';
    END IF;

    -- Lock the singleton row (or the empty-table gap) before deciding bootstrap vs transfer.
    SET v_not_found = FALSE;
    SELECT `user_id`, `assigned_at`, `assigned_by_user_id`, `transition_reason`
      INTO v_current_user_id, v_current_started, v_current_by, v_current_reason
      FROM `primary_officer_assignment`
     WHERE `singleton_id` = 1
       FOR UPDATE;
    SET v_has_row = NOT v_not_found;

    IF v_has_row THEN
        IF v_current_user_id = p_new_officer_user_id THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is already the Primary Officer.';
        END IF;

        INSERT INTO `primary_officer_history`
            (`officer_user_id`, `appointed_by_user_id`, `appointment_reason`, `started_at`,
             `ended_at`, `ended_by_user_id`, `end_reason`)
        VALUES (v_current_user_id, v_current_by, v_current_reason, v_current_started,
                NOW(), p_acting_admin_user_id, v_reason);

        UPDATE `user_roles`
           SET `is_active` = FALSE
         WHERE `user_id` = v_current_user_id AND `role_id` = v_officer_role_id;

        UPDATE `primary_officer_assignment`
           SET `user_id`                  = p_new_officer_user_id,
               `assigned_by_user_id`      = p_acting_admin_user_id,
               `previous_officer_user_id` = v_current_user_id,
               `transition_reason`        = v_reason,
               `assigned_at`              = NOW()
         WHERE `singleton_id` = 1;
    ELSE
        INSERT INTO `primary_officer_assignment`
            (`singleton_id`, `user_id`, `assigned_at`, `assigned_by_user_id`, `previous_officer_user_id`, `transition_reason`)
        VALUES (1, p_new_officer_user_id, NOW(), p_acting_admin_user_id, NULL, v_reason);
    END IF;

    INSERT INTO `user_roles` (`user_id`, `role_id`, `is_active`, `assigned_at`)
    VALUES (p_new_officer_user_id, v_officer_role_id, TRUE, CURRENT_TIMESTAMP)
    ON DUPLICATE KEY UPDATE `is_active` = TRUE, `assigned_at` = CURRENT_TIMESTAMP;

    COMMIT;
END$$

-- =====================================================================================
-- 7. Account token lifecycle
--    Only SHA-256 hex digests reach the database; raw tokens are never stored. Times are UTC.
--    Authorization boundary:
--      issue_account_token          -> Flask runtime; requires an authenticated actor:
--                                      * self-service PASSWORD_RESET (actor = target, active), or
--                                      * system:manage_users (any target / purpose), or
--                                      * staff:verify_account for ACTIVATION of a staff account.
--      issue_account_token_operator -> granted ONLY to cc_v2_dev_activation_cli (dev CLI);
--                                      never to the runtime account (privilege-enforced).
--      redeem_account_token         -> the token itself is the credential.
--    A student therefore cannot issue or revoke tokens for any account but their own.
-- =====================================================================================

-- Internal core (no transaction of its own; called inside the wrappers' transaction).
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `cc_token_issue_core`(
    IN p_user_id     INT,
    IN p_token_hash  CHAR(64),
    IN p_purpose     VARCHAR(20),
    IN p_ttl_minutes INT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Internal: validate target state, revoke live tokens, store the hash of a fresh one'
BEGIN
    DECLARE v_not_found BOOLEAN DEFAULT FALSE;
    DECLARE v_active    BOOLEAN DEFAULT NULL;
    DECLARE v_has_pw    BOOLEAN DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;

    IF p_user_id IS NULL OR p_token_hash IS NULL
       OR NOT REGEXP_LIKE(p_token_hash, '^[0-9a-f]{64}$', 'c') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A user ID and a lowercase SHA-256 hex digest are required.';
    END IF;
    IF p_purpose IS NULL OR p_purpose NOT IN ('ACTIVATION', 'PASSWORD_RESET') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid token purpose.';
    END IF;
    IF p_ttl_minutes IS NULL OR p_ttl_minutes < 5 OR p_ttl_minutes > 10080 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Token lifetime must be between 5 minutes and 7 days.';
    END IF;

    SELECT `is_active`, (`password_hash` IS NOT NULL) INTO v_active, v_has_pw
      FROM `users` WHERE `user_id` = p_user_id FOR UPDATE;
    IF v_not_found THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User does not exist.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM `user_roles` WHERE `user_id` = p_user_id AND `is_active` = TRUE) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User has no active role.';
    END IF;
    IF EXISTS (SELECT 1 FROM `staff` WHERE `user_id` = p_user_id
                AND (`verification_status` <> 'VERIFIED' OR `is_active` = FALSE)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Staff account is not verified or is deactivated.';
    END IF;
    IF p_purpose = 'ACTIVATION' AND (v_active IS TRUE OR v_has_pw IS TRUE) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Activation tokens are only issued to never-activated accounts.';
    END IF;
    IF p_purpose = 'PASSWORD_RESET' AND v_active IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Password reset tokens are only issued to active accounts.';
    END IF;

    -- Invalidate every previously issued, still-live token of this user.
    UPDATE `account_activations`
       SET `revoked_at` = UTC_TIMESTAMP()
     WHERE `user_id` = p_user_id AND `used_at` IS NULL AND `revoked_at` IS NULL;

    INSERT INTO `account_activations` (`user_id`, `purpose`, `token_hash`, `created_at`, `expires_at`)
    VALUES (p_user_id, p_purpose, p_token_hash, UTC_TIMESTAMP(), UTC_TIMESTAMP() + INTERVAL p_ttl_minutes MINUTE);
END$$

-- Runtime (Flask) entry point: authenticated actor required.
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `issue_account_token`(
    IN p_user_id       INT,
    IN p_token_hash    CHAR(64),
    IN p_purpose       VARCHAR(20),
    IN p_ttl_minutes   INT,
    IN p_actor_user_id INT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Issue a token on behalf of an authenticated actor (self reset, user admin, or staff verifier)'
BEGIN
    DECLARE v_manage_users BOOLEAN DEFAULT FALSE;
    DECLARE v_verify_staff BOOLEAN DEFAULT FALSE;
    DECLARE v_self_active  BOOLEAN DEFAULT FALSE;
    DECLARE v_allowed      BOOLEAN DEFAULT FALSE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_actor_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authenticated actor user ID is required to issue tokens.';
    END IF;

    START TRANSACTION;

    CALL `cc_auth_has_permission`(p_actor_user_id, 'system:manage_users', v_manage_users);
    CALL `cc_auth_has_permission`(p_actor_user_id, 'staff:verify_account', v_verify_staff);
    SET v_self_active = EXISTS (SELECT 1 FROM `users` WHERE `user_id` = p_actor_user_id AND `is_active` = TRUE);

    SET v_allowed =
           v_manage_users
        OR (p_actor_user_id = p_user_id AND p_purpose = 'PASSWORD_RESET' AND v_self_active)
        OR (v_verify_staff AND p_purpose = 'ACTIVATION'
            AND EXISTS (SELECT 1 FROM `staff` WHERE `user_id` = p_user_id));
    IF v_allowed IS NOT TRUE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied: actor may not issue a token for this account.';
    END IF;

    CALL `cc_token_issue_core`(p_user_id, p_token_hash, p_purpose, p_ttl_minutes);

    COMMIT;
END$$

-- Development operator entry point: EXECUTE granted ONLY to 'cc_v2_dev_activation_cli'@'localhost'.
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `issue_account_token_operator`(
    IN p_user_id     INT,
    IN p_token_hash  CHAR(64),
    IN p_purpose     VARCHAR(20),
    IN p_ttl_minutes INT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'DEV ONLY: operator token issuance for cli_activation.py; never granted to the Flask runtime account'
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    CALL `cc_token_issue_core`(p_user_id, p_token_hash, p_purpose, p_ttl_minutes);
    COMMIT;
END$$

CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `redeem_account_token`(
    IN  p_token_hash    CHAR(64),
    IN  p_password_hash VARCHAR(255),
    OUT p_user_id       INT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Verify a live token, then set the password hash and activate the account atomically'
BEGIN
    DECLARE v_not_found     BOOLEAN DEFAULT FALSE;
    DECLARE v_activation_id INT DEFAULT NULL;
    DECLARE v_user_id       INT DEFAULT NULL;
    DECLARE v_purpose       VARCHAR(20) DEFAULT NULL;
    DECLARE v_expires_at    DATETIME DEFAULT NULL;
    DECLARE v_used_at       DATETIME DEFAULT NULL;
    DECLARE v_revoked_at    DATETIME DEFAULT NULL;
    DECLARE v_active        BOOLEAN DEFAULT NULL;
    DECLARE v_has_pw        BOOLEAN DEFAULT NULL;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_not_found = TRUE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_user_id = NULL;
        RESIGNAL;
    END;

    SET p_user_id = NULL;

    IF p_token_hash IS NULL OR NOT REGEXP_LIKE(p_token_hash, '^[0-9a-f]{64}$', 'c') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid or expired token.';
    END IF;
    -- Accept only real password-hash formats, never a plaintext password or a placeholder.
    IF p_password_hash IS NULL OR CHAR_LENGTH(p_password_hash) < 40
       OR NOT (p_password_hash LIKE 'scrypt:%$%$%'
               OR p_password_hash LIKE 'pbkdf2:%$%$%'
               OR p_password_hash LIKE '$argon2id$%') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A Werkzeug scrypt/pbkdf2 or Argon2id password hash is required.';
    END IF;

    START TRANSACTION;

    SELECT `activation_id`, `user_id`, `purpose`, `expires_at`, `used_at`, `revoked_at`
      INTO v_activation_id, v_user_id, v_purpose, v_expires_at, v_used_at, v_revoked_at
      FROM `account_activations`
     WHERE `token_hash` = CONVERT(p_token_hash USING ascii) COLLATE ascii_bin
       FOR UPDATE;

    -- One generic message for every failure, so the response is not an oracle.
    IF v_not_found OR v_used_at IS NOT NULL OR v_revoked_at IS NOT NULL OR v_expires_at <= UTC_TIMESTAMP() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid or expired token.';
    END IF;

    SET v_not_found = FALSE;
    SELECT `is_active`, (`password_hash` IS NOT NULL) INTO v_active, v_has_pw
      FROM `users` WHERE `user_id` = v_user_id FOR UPDATE;
    IF v_not_found THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid or expired token.';
    END IF;
    IF EXISTS (SELECT 1 FROM `staff` WHERE `user_id` = v_user_id
                AND (`verification_status` <> 'VERIFIED' OR `is_active` = FALSE)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid or expired token.';
    END IF;
    IF (v_purpose = 'ACTIVATION' AND (v_active IS TRUE OR v_has_pw IS TRUE))
       OR (v_purpose = 'PASSWORD_RESET' AND v_active IS NOT TRUE) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid or expired token.';
    END IF;

    UPDATE `account_activations` SET `used_at` = UTC_TIMESTAMP() WHERE `activation_id` = v_activation_id;
    UPDATE `users` SET `password_hash` = p_password_hash, `is_active` = TRUE WHERE `user_id` = v_user_id;

    COMMIT;
    SET p_user_id = v_user_id;
END$$

-- =====================================================================================
-- 7b. submit_complaint  (the ONLY way to create a complaint; the runtime account has no
--     INSERT privilege on complaints). The complainant is DERIVED from the authenticated
--     actor's own student or external profile; no complainant_user_id / student_id /
--     external_id is accepted from the caller, so nobody can submit on behalf of another
--     account through this interface. Validates: active account in good standing, active
--     role holding the matching submit permission, profile ownership, existing service
--     department, field domains, and the initial state (Submitted, unassigned, Level 1).
-- =====================================================================================
CREATE DEFINER = `cc_v2_dev_routine_definer`@`localhost`
PROCEDURE `submit_complaint`(
    IN  p_actor_user_id    INT,
    IN  p_complainant_type VARCHAR(10),
    IN  p_department_id    INT,
    IN  p_title            VARCHAR(180),
    IN  p_description      TEXT,
    IN  p_category         VARCHAR(50),
    IN  p_priority         VARCHAR(10),
    OUT p_complaint_id     INT
)
MODIFIES SQL DATA
SQL SECURITY DEFINER
COMMENT 'Create a complaint for the authenticated actor''s own student or external profile'
BEGIN
    DECLARE v_perm        BOOLEAN DEFAULT FALSE;
    DECLARE v_student_id  INT DEFAULT NULL;
    DECLARE v_external_id INT DEFAULT NULL;
    DECLARE v_title       VARCHAR(180) DEFAULT NULL;
    DECLARE v_description TEXT DEFAULT NULL;
    DECLARE v_new_id      INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_complaint_id = NULL;
        RESIGNAL;
    END;

    SET p_complaint_id = NULL;
    SET v_title = NULLIF(TRIM(p_title), '');
    SET v_description = NULLIF(TRIM(p_description), '');

    IF p_actor_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authenticated actor user ID is required.';
    END IF;
    IF p_complainant_type IS NULL OR p_complainant_type NOT IN ('STUDENT', 'EXTERNAL') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complainant type must be STUDENT or EXTERNAL.';
    END IF;
    IF v_title IS NULL OR v_description IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Title and description are required.';
    END IF;
    IF p_category IS NULL
       OR p_category NOT IN ('Infrastructure', 'Hostel', 'Laboratory', 'Network', 'Cleanliness', 'Other') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid complaint category.';
    END IF;
    IF p_priority IS NULL OR p_priority NOT IN ('Low', 'Medium', 'High') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid complaint priority.';
    END IF;

    START TRANSACTION;

    IF p_complainant_type = 'STUDENT' THEN
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:submit_student', v_perm);
        SET v_student_id = (SELECT `student_id` FROM `students` WHERE `user_id` = p_actor_user_id);
        IF v_perm IS NOT TRUE OR v_student_id IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied: no active student profile and permission for this account.';
        END IF;
    ELSE
        CALL `cc_auth_has_permission`(p_actor_user_id, 'complaint:submit_external', v_perm);
        SET v_external_id = (SELECT `external_id` FROM `external_complainants` WHERE `user_id` = p_actor_user_id);
        IF v_perm IS NOT TRUE OR v_external_id IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Authorization denied: no active external profile and permission for this account.';
        END IF;
    END IF;

    IF p_department_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM `departments` WHERE `department_id` = p_department_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown service department.';
    END IF;

    -- Initial state comes from column defaults (status 'Submitted', current_level_id 1,
    -- assigned_staff_id NULL, is_deleted FALSE) and is re-asserted by the INSERT trigger.
    INSERT INTO `complaints`
        (`student_id`, `external_id`, `complainant_user_id`, `department_id`,
         `title`, `description`, `category`, `priority`)
    VALUES (v_student_id, v_external_id, p_actor_user_id, p_department_id,
            v_title, v_description, p_category, p_priority);
    SET v_new_id = LAST_INSERT_ID();

    INSERT INTO `complaint_history`
        (`complaint_id`, `old_status`, `new_status`, `changed_by_user_id`, `action_type`, `remarks`)
    VALUES (v_new_id, NULL, 'Submitted', p_actor_user_id, 'SUBMISSION', 'Complaint submitted by the complainant');

    COMMIT;
    SET p_complaint_id = v_new_id;
END$$

-- =====================================================================================
-- 8. Triggers on complaints (definer: cc_v2_dev_trigger_definer)
--    Scalar subqueries are used instead of SELECT ... INTO so a missing row yields NULL
--    rather than a NOT FOUND condition.
-- =====================================================================================

-- 8a. Identity + initial-state integrity on INSERT
CREATE DEFINER = `cc_v2_dev_trigger_definer`@`localhost`
TRIGGER `trg_validate_complaint_identity_insert`
BEFORE INSERT ON `complaints` FOR EACH ROW
BEGIN
    DECLARE v_owner INT DEFAULT NULL;

    IF NEW.`complainant_user_id` IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Integrity Error: complainant_user_id cannot be null.';
    END IF;

    IF NEW.`student_id` IS NOT NULL THEN
        SET v_owner = (SELECT `user_id` FROM `students` WHERE `student_id` = NEW.`student_id`);
        IF v_owner IS NULL OR v_owner <> NEW.`complainant_user_id` THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Integrity Error: student_id does not belong to complainant_user_id.';
        END IF;
    END IF;

    IF NEW.`external_id` IS NOT NULL THEN
        SET v_owner = (SELECT `user_id` FROM `external_complainants` WHERE `external_id` = NEW.`external_id`);
        IF v_owner IS NULL OR v_owner <> NEW.`complainant_user_id` THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Integrity Error: external_id does not belong to complainant_user_id.';
        END IF;
    END IF;

    IF NEW.`status` <> 'Submitted'
       OR NEW.`assigned_staff_id` IS NOT NULL
       OR NEW.`current_level_id` <> 1
       OR NEW.`is_deleted` <> FALSE
       OR NEW.`deleted_at` IS NOT NULL
       OR NEW.`deleted_by_user_id` IS NOT NULL
       OR NEW.`resolved_at` IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'New complaints must start Submitted, unassigned, at Level 1 and not archived.';
    END IF;
END$$

-- 8b. Identity immutability on UPDATE
CREATE DEFINER = `cc_v2_dev_trigger_definer`@`localhost`
TRIGGER `trg_validate_complaint_identity_update`
BEFORE UPDATE ON `complaints` FOR EACH ROW
BEGIN
    DECLARE v_owner INT DEFAULT NULL;

    IF NEW.`complainant_user_id` IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Integrity Error: complainant_user_id cannot be null.';
    END IF;
    IF NOT (NEW.`complainant_user_id` <=> OLD.`complainant_user_id`) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Security Violation: complainant_user_id cannot be altered.';
    END IF;
    IF NOT (NEW.`student_id` <=> OLD.`student_id`) OR NOT (NEW.`external_id` <=> OLD.`external_id`) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Security Violation: complainant links cannot be altered.';
    END IF;

    IF NEW.`student_id` IS NOT NULL THEN
        SET v_owner = (SELECT `user_id` FROM `students` WHERE `student_id` = NEW.`student_id`);
        IF v_owner IS NULL OR v_owner <> NEW.`complainant_user_id` THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Integrity Error: student_id does not belong to complainant_user_id.';
        END IF;
    END IF;

    IF NEW.`external_id` IS NOT NULL THEN
        SET v_owner = (SELECT `user_id` FROM `external_complainants` WHERE `external_id` = NEW.`external_id`);
        IF v_owner IS NULL OR v_owner <> NEW.`complainant_user_id` THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Integrity Error: external_id does not belong to complainant_user_id.';
        END IF;
    END IF;
END$$

-- 8c. Sensitive-column guard on UPDATE.
--     Rules 2-4 are real integrity checks against ledgers the runtime account cannot write.
--     Rule 1 is an ACCIDENT guard only: the marker is a forgeable session variable; the
--     runtime account is stopped by missing UPDATE privilege on complaints.status.
CREATE DEFINER = `cc_v2_dev_trigger_definer`@`localhost`
TRIGGER `trg_guard_complaint_sensitive_update`
BEFORE UPDATE ON `complaints` FOR EACH ROW
BEGIN
    DECLARE v_active_staff INT DEFAULT NULL;
    DECLARE v_esc_from     INT DEFAULT NULL;
    DECLARE v_esc_to       INT DEFAULT NULL;

    -- 1. Status changes must come through a workflow procedure (accident guard).
    IF NOT (OLD.`status` <=> NEW.`status`) AND (@app_status_transition_authorized IS NOT TRUE) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Direct UPDATE of complaints.status is prohibited; call transition_complaint_status.';
    END IF;

    -- 2. Cached assignee must equal the active row of the canonical assignment ledger.
    IF NOT (OLD.`assigned_staff_id` <=> NEW.`assigned_staff_id`) THEN
        SET v_active_staff = (SELECT `assigned_staff_id` FROM `complaint_assignments`
                               WHERE `active_complaint_id` = NEW.`complaint_id`);
        IF NOT (v_active_staff <=> NEW.`assigned_staff_id`) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'assigned_staff_id must match the active complaint_assignments row; use reassign_complaint.';
        END IF;
    END IF;

    -- 3. Workflow level changes must match the latest escalation ledger row.
    IF NOT (OLD.`current_level_id` <=> NEW.`current_level_id`) THEN
        SET v_esc_from = (SELECT `from_level_id` FROM `complaint_escalations`
                           WHERE `complaint_id` = NEW.`complaint_id`
                           ORDER BY `escalation_id` DESC LIMIT 1);
        SET v_esc_to   = (SELECT `to_level_id` FROM `complaint_escalations`
                           WHERE `complaint_id` = NEW.`complaint_id`
                           ORDER BY `escalation_id` DESC LIMIT 1);
        IF NOT ((v_esc_from <=> OLD.`current_level_id`) AND (v_esc_to <=> NEW.`current_level_id`)) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'current_level_id must match the latest complaint_escalations row; use escalate_complaint.';
        END IF;
    END IF;

    -- 4. Archiving is one-way and attributed.
    IF OLD.`is_deleted` = TRUE AND NEW.`is_deleted` = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Archived complaints cannot be restored by UPDATE.';
    END IF;
    IF OLD.`is_deleted` = FALSE AND NEW.`is_deleted` = TRUE
       AND (NEW.`deleted_by_user_id` IS NULL OR NEW.`deleted_at` IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Archiving requires deleted_by_user_id and deleted_at; use soft_delete_complaint.';
    END IF;
END$$

-- 8d. Replacement status-history trigger (same canonical name as v1; v1 dropped above).
CREATE DEFINER = `cc_v2_dev_trigger_definer`@`localhost`
TRIGGER `trg_complaint_status_history`
AFTER UPDATE ON `complaints` FOR EACH ROW
BEGIN
    IF NOT (OLD.`status` <=> NEW.`status`) THEN
        INSERT INTO `complaint_history`
            (`complaint_id`, `old_status`, `new_status`, `changed_at`, `changed_by_user_id`, `action_type`, `remarks`)
        VALUES
            (NEW.`complaint_id`, OLD.`status`, NEW.`status`, NOW(),
             @app_current_user_id,
             COALESCE(@app_action_type, 'STATUS_CHANGE'),
             COALESCE(@app_status_remarks, 'Status updated outside the application workflow'));
    END IF;
END$$

DELIMITER ;

-- =====================================================================================
-- 9. Views: SQL SECURITY INVOKER (the reader's own privileges apply; no definer escalation,
--    no dependency on the migrator account). Soft-deleted complaints are filtered out.
--    All original columns are preserved (backward compatible) and external users supported.
-- =====================================================================================

CREATE OR REPLACE SQL SECURITY INVOKER VIEW `complaint_details` AS
SELECT
  c.`complaint_id`,
  c.`title`,
  c.`description`,
  c.`category`,
  c.`priority`,
  c.`status`,
  c.`current_level_id`,
  wl.`level_name`             AS `current_level_name`,
  c.`created_at`,
  c.`resolved_at`,
  c.`is_deleted`,
  c.`complainant_user_id`,
  CASE
    WHEN c.`student_id`  IS NOT NULL THEN 'STUDENT'
    WHEN c.`external_id` IS NOT NULL THEN 'EXTERNAL'
    ELSE 'UNKNOWN'
  END                          AS `complainant_type`,
  u.`full_name`                AS `complainant_name`,
  u.`email`                    AS `complainant_email`,
  COALESCE(s.`phone`, ec.`phone`) AS `complainant_phone`,
  c.`student_id`,
  s.`full_name`                AS `student_name`,
  s.`email`                    AS `student_email`,
  ad.`academic_department_id`,
  ad.`department_name`         AS `academic_department`,
  c.`external_id`,
  ec.`affiliation_type`        AS `external_affiliation`,
  ec.`organization_name`       AS `external_organization`,
  c.`department_id`,
  d.`department_name`          AS `responsible_department`,
  c.`assigned_staff_id`,
  st.`full_name`               AS `assigned_staff_name`,
  st.`email`                   AS `assigned_staff_email`
FROM `complaints` c
JOIN `users` u              ON c.`complainant_user_id` = u.`user_id`
JOIN `departments` d        ON c.`department_id` = d.`department_id`
JOIN `workflow_levels` wl   ON c.`current_level_id` = wl.`level_id`
LEFT JOIN `students` s      ON c.`student_id` = s.`student_id`
LEFT JOIN `academic_departments` ad ON s.`academic_department_id` = ad.`academic_department_id`
LEFT JOIN `external_complainants` ec ON c.`external_id` = ec.`external_id`
LEFT JOIN `staff` st        ON c.`assigned_staff_id` = st.`staff_id`
WHERE c.`is_deleted` = FALSE;

CREATE OR REPLACE SQL SECURITY INVOKER VIEW `open_complaints` AS
SELECT * FROM `complaint_details`
WHERE `status` IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification');

CREATE OR REPLACE SQL SECURITY INVOKER VIEW `pending_complaints` AS
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
JOIN `users` u        ON c.`complainant_user_id` = u.`user_id`
JOIN `departments` d  ON c.`department_id` = d.`department_id`
LEFT JOIN `students` s ON c.`student_id` = s.`student_id`
WHERE c.`status` IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification')
  AND c.`is_deleted` = FALSE;

CREATE OR REPLACE SQL SECURITY INVOKER VIEW `department_complaint_summary` AS
SELECT
  d.`department_name`,
  COUNT(c.`complaint_id`) AS `total_complaints`,
  COALESCE(SUM(c.`status` = 'Resolved'), 0) AS `resolved_complaints`,
  COALESCE(SUM(c.`status` IN ('Submitted', 'In Progress', 'Escalated', 'Resolution Pending Verification')), 0) AS `pending_complaints`
FROM `departments` d
LEFT JOIN `complaints` c ON d.`department_id` = c.`department_id` AND c.`is_deleted` = FALSE
GROUP BY d.`department_id`, d.`department_name`;
