# CampusCare 2.0 – Stage 2 Proposed MySQL Accounts and Grants (revision 5)

These grants are **proposals**. Nothing here has been executed. The exact statements are in:

- `migrations/admin/S2_A_pre_migration_accounts.sql`: run before the migrations.
- `migrations/admin/S2_B_post_migration_grants.sql`: run after migration 008.

A MySQL administrator runs both scripts. `run_migrations.py` runs neither. Every grant is scoped to `college_complaints_v2_dev`. No statement grants anything on `college_complaints`.

Revision 3 implements the approved decisions **R13–R16**: complaint detail editing only via `update_complaint_details`, exact-level handling with separate permission families, escalation that closes the assignment, and separation of duties with `OFFICER_FINAL_DECISION`. Revision 2 incorporated the independent-review corrections:

- migrator reconciliation;
- workflow-level authorization;
- `submit_complaint`;
- token-issuance boundary;
- officer eligibility;
- the corrected locking-read explanation.

## 1. Accounts

| Account | Purpose | Login | Root? |
|---|---|---|---|
| `complaint_migrator_v2_dev@localhost` | Runs migrations 000–008 | Yes (dev only) | No |
| `complaint_app_v2_dev@localhost` | Flask runtime | Yes | No |
| `cc_v2_dev_routine_definer@localhost` | DEFINER of every stored procedure | **No** (`ACCOUNT LOCK`) | No |
| `cc_v2_dev_trigger_definer@localhost` | DEFINER of every trigger | **No** (`ACCOUNT LOCK`) | No |
| `cc_v2_dev_activation_cli@localhost` | **Development-only** token issuer used by `cli_activation.py`; never by Flask | Locked until the operator unlocks it with a random password (guide, Step 8) | No |

Why separate, locked definers:

- Root is never a definer, and the migrator cannot name root as one because it lacks SYSTEM_USER.
- Routines don't run with migration authority.
- Nobody can log in as a definer.
- Triggers get read-only lookups plus a single history INSERT.

## 2. Migrator: reconciled least privilege

Stage 1 granted `ALL PRIVILEGES ON college_complaints_v2_dev.*`. **GRANT is additive and cannot narrow an existing grant**, so S2_A first runs:

```sql
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'complaint_migrator_v2_dev'@'localhost';
```

It then grants exactly this set:

| Privilege (on `college_complaints_v2_dev`.*) | Why |
|---|---|
| SELECT | preflight and post-flight assertions, ledger reads, 006 reads, mysqldump |
| INSERT, UPDATE | 002 and 003 seeds, 006 backfill, `schema_migrations` rows |
| CREATE, ALTER, INDEX, REFERENCES | 000–005 tables, the 005 and 007 ALTERs, foreign keys |
| DROP | 008 `DROP … IF EXISTS`, `CREATE OR REPLACE VIEW`, the 007 temporary procedure |
| CREATE VIEW, SHOW VIEW | 008 views; dumping views |
| TRIGGER | 008 triggers; `mysqldump --triggers` |
| CREATE ROUTINE, ALTER ROUTINE, EXECUTE | the 007 temporary assertion procedure, the 008 routines |
| **SET_USER_ID** (global, **temporary**) | lets 008 write `DEFINER = cc_v2_dev_*`; revoked in S2_B |

**Not granted:**

- **DELETE.** No migration deletes rows.
- **LOCK TABLES.** Dumps use `--single-transaction`.
- **CREATE TEMPORARY TABLES and EVENT.**
- **FILE, PROCESS, SUPER, SYSTEM_USER and GRANT OPTION.**
- **Anything on another schema.**

The runner enforces this with an **exact allowlist** (`review_migrator_grants`). It rejects:

- `ALL PRIVILEGES ON college_complaints_v2_dev.*`;
- any privilege outside the set above;
- any global privilege other than USAGE and SET_USER_ID;
- GRANT OPTION, granted roles, and grants on other schemas.

It requires SET_USER_ID before 008 and halts `--preflight` if SET_USER_ID is still held after Stage 2. Per-routine `EXECUTE`/`ALTER ROUTINE` lines are tolerated only for this schema, because `automatic_sp_privileges` may add them.

The allowlist was unit-tested offline against 10 synthetic `SHOW GRANTS` cases, including the Stage 1 `ALL` grant, DELETE, FILE/PROCESS, SYSTEM_USER, GRANT OPTION, the protected database and a granted role. All 10 behaved as expected.

## 3. Routine definer (`cc_v2_dev_routine_definer`)

| Object | Privilege | Exactly why |
|---|---|---|
| `workflow_levels`, `roles`, `permissions`, `role_permissions`, `staff_workflow_assignments` | SELECT | permission checks (`cc_auth_has_permission`), level numbers, exact level memberships (`cc_auth_staff_eligible`, `cc_auth_department_authority`) |
| `staff` | SELECT | staff standing, assignee and target eligibility, officer eligibility; `FOR SHARE` in reassign |
| `departments`, `students`, `external_complainants` | SELECT | `submit_complaint` (department validity, the actor's own profile); officer eligibility (no student or external profile) |
| `complaints` | SELECT; **INSERT** (`student_id`, `external_id`, `complainant_user_id`, `department_id`, `title`, `description`, `category`, `priority`); **UPDATE** (`status`, `resolved_at`, `assigned_staff_id`, `department_id`, `current_level_id`, `is_deleted`, `deleted_at`, `deleted_by_user_id`, `title`, `description`, `category`, `priority`) | `submit_complaint` creates the row (the initial state comes from defaults and is re-checked by the trigger); transition, escalate (which also clears `assigned_staff_id`, R15), reassign and soft-delete change the workflow columns; `update_complaint_details` changes the four detail columns (R13); `FOR UPDATE` row locks |
| `complaint_assignments` | SELECT, INSERT, UPDATE (`is_active`, `unassigned_at`, `unassigned_by_user_id`) | ledger close, open and verify in `reassign_complaint`; closing the active assignment on escalation (R15) |
| `complaint_history` | INSERT | timeline rows for submission, detail edits (R13), assignment, escalation request, escalation and archive |
| `complaint_escalations` | INSERT | `escalate_complaint` |
| `resolution_verifications` | SELECT, INSERT, UPDATE (`decision`, `officer_user_id`, `officer_remarks`, `reviewed_at`) | the RPV submission, approval, return, and the Level 4 direct-resolution record |
| `primary_officer_assignment` | SELECT; **INSERT** (table-level, explicit statement since R5); UPDATE (`user_id`, `assigned_by_user_id`, `previous_officer_user_id`, `transition_reason`, `assigned_at`) | SELECT: the officer checks and `FOR UPDATE` on the singleton. **INSERT: the initial bootstrap row** in `transfer_primary_officer` (`singleton_id, user_id, assigned_at, assigned_by_user_id, previous_officer_user_id, transition_reason`). Column UPDATE: subsequent transfers |
| `primary_officer_history` | INSERT | archiving the ended tenure |
| `user_roles` | SELECT, INSERT, UPDATE (`is_active`, `assigned_at`) | role checks; deactivating and activating the officer role (`INSERT … ON DUPLICATE KEY UPDATE`) |
| `users` | SELECT, UPDATE (`password_hash`, `is_active`) | account-state checks; `FOR UPDATE` in issue and redeem; setting the password and activating |
| `account_activations` | SELECT, INSERT, UPDATE (`revoked_at`, `used_at`) | token revoke and insert; `FOR UPDATE` lookup at redemption |
| schema `.*` | LOCK TABLES | precaution for `FOR UPDATE` (see §4) |
| `cc_auth_has_permission`, `cc_auth_is_primary_officer`, `cc_auth_department_authority`, `cc_auth_staff_eligible`, `cc_auth_is_assigned_staff`, `cc_token_issue_core` | EXECUTE | the public procedures run as this definer and call the internal helpers |

It has no DELETE, no DDL, no `schema_migrations`, no `notifications`, and nothing outside the dev schema.

## 4. Locking reads (corrected explanation)

On MySQL 8.0.22 and later:

- **`SELECT … FOR SHARE` requires only SELECT.** It is used on `staff` in `reassign_complaint`, which the definer covers with table-level SELECT.
- **`SELECT … FOR UPDATE` requires SELECT plus at least one of UPDATE, DELETE or LOCK TABLES** on the locked table. It is used on:
  - `complaints`, in transition, escalate, request_escalation, reassign, update_complaint_details and soft-delete;
  - `users`, in transfer, issue and redeem;
  - `primary_officer_assignment`, in transfer;
  - `account_activations`, in redeem.

The definer holds **column-level** UPDATE on each of those four tables. The documentation doesn't state whether column-level UPDATE satisfies the `FOR UPDATE` check. A schema-level `LOCK TABLES` grant is therefore added as a precaution; LOCK TABLES has no table-level form.

That grant adds no reachable capability:

- the account is `ACCOUNT LOCK`ed, so nobody can log in and issue `LOCK TABLES`;
- no routine contains `LOCK TABLES`.

If execution evidence shows column-level UPDATE is sufficient, the grant can be revoked.

`transition`, `escalate`, `request_escalation`, `reassign` and `update_complaint_details` use `FOR UPDATE OF c`, so the joined `workflow_levels` rows are **not** locked and need no extra privilege.

## 5. Trigger definer (`cc_v2_dev_trigger_definer`)

| Object | Privilege | Why |
|---|---|---|
| `complaints` | TRIGGER, SELECT | MySQL requires TRIGGER on the subject table and SELECT for `OLD.`/`NEW.` references |
| `students`, `external_complainants` | SELECT | identity checks |
| `complaint_assignments`, `complaint_escalations` | SELECT | ledger-to-cache and level-to-escalation checks |
| `complaint_history` | INSERT | `trg_complaint_status_history` |

## 6. Flask runtime (`complaint_app_v2_dev`)

S2_B starts with `REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'complaint_app_v2_dev'@'localhost'`. The architecture document's `ALL PRIVILEGES` grant cannot be narrowed by a column-level REVOKE, so it has to be removed first. Then:

| Object | Privilege |
|---|---|
| 20 tables (not `schema_migrations` or `account_activations`) and 4 views | SELECT |
| `complaints` | **no INSERT and no UPDATE** (revision 3, R13) |
| `notifications` | INSERT (`user_id`, `complaint_id`, `title`, `message`), UPDATE (`is_read`) |
| `submit_complaint`, `update_complaint_details`, `request_escalation`, `transition_complaint_status`, `escalate_complaint`, `reassign_complaint`, `soft_delete_complaint`, `transfer_primary_officer`, `issue_account_token`, `redeem_account_token` | EXECUTE |

**Not granted:** the internal helpers, `cc_token_issue_core`, or the development-only `issue_account_token_operator`.

**Complaint submission ownership.** The direct INSERT is **removed**. `submit_complaint(p_actor_user_id, p_complainant_type, …)`:

- **accepts no complainant, student or external ID** from the caller;
- **derives the profile** from the actor's own row in `students` or `external_complainants`;
- **requires** an active account in good standing, an active role holding `complaint:submit_student` or `complaint:submit_external`, and an existing service department;
- **validates** the category and priority domains;
- **creates the complaint in its initial state**: Submitted, unassigned, Level 1. The INSERT trigger re-checks this.

Probes T13 and T21–T24 cover this.

**Complaint detail editing (R13).** The runtime account has no UPDATE on `complaints`. `update_complaint_details(complaint, actor, title, description, category, priority, reason)` is the only edit path:

- **Editable fields:** those four only. A NULL argument leaves the field unchanged, and the domains are validated.
- **Owner path:** the actor is the complainant, holds `complaint:edit_own`, and the complaint is still **Submitted**, meaning no investigation has been accepted.
- **Supervisory path:** the Primary Officer, or department authority at or above max(2, current level), holding `complaint:edit_details`. It works on any non-final status, and a reason is required.
- **Audit:** one `complaint_history` row `DETAILS_EDITED` records the editor (`changed_by_user_id`), the time (`changed_at`), the modified fields and the reason.

Flask still supplies the actor only from the server-side session.

## 6b. Permission families (R14)

Every permission is checked separately, always together with a structural fact: an exact workflow membership, the active assignment, department authority or the officer singleton. None is ever derived from `staff.designation`.

| Family | Permission(s) | Structural requirement |
|---|---|---|
| View | `complaint:view_own`, `complaint:view_assigned`, `complaint:view_department_queue`, `complaint:view_all` | Enforced by Flask on its SELECT queries, because MySQL has no per-website-user row security. Reviewers and HODs may *view* lower-level departmental complaints through `view_department_queue` |
| Investigation | `complaint:update_investigation` | Must be the active assignee and **fully eligible**: an active VERIFIED staff profile, an active user account, an active STAFF role, and an **exact membership** at the complaint's department and current level (Level 4: the active officer singleton with an active officer role) |
| Assignment | `complaint:assign_staff`, `complaint:reassign_staff`, `complaint:reassign_global` | Department authority at or above max(2, level) for same-department moves; officer for any department. The **target** must hold the exact level membership |
| Escalation | `complaint:request_escalation` (ask) and `complaint:escalate_tier` (execute) | Ask: the assignee with `can_escalate` on the exact membership. Execute: department authority with `can_escalate` (one level up) or the officer |
| Resolution submission | `complaint:submit_resolution` | The assignee with `can_resolve` on the exact membership, Levels 1–3 |
| Final verification | `complaint:verify_resolution` | The officer only; **never the submitter** (R16) |
| Detail editing | `complaint:edit_own`, `complaint:edit_details` | Owner while Submitted, or supervisory with a reason (R13) |

Supervisors (department authority) can supervise lower levels: viewing, assigning, rejecting, editing with a reason, and escalating. They **cannot investigate** a complaint unless they are its eligible assignee. A Level 1 assignee gains nothing at Level 2 or Level 3.

## 6c. Escalation and separation of duties (R15, R16)

- **Escalation (R15)** writes `complaint_escalations` (reason, actor), updates the level, **closes the active assignment** (`unassigned_by_user_id` = the escalating actor), clears `assigned_staff_id`, and sets status `Escalated` (awaiting assignment). Then `reassign_complaint` assigns an exact member of the new level, and only that assignee can accept (`ESCALATION_ACCEPTED`). The previous assignee loses every handling path.
- **Separation of duties (R16):** a resolution can never be approved by the user who submitted it. A Level 4 complaint handled by the officer ends with `OFFICER_FINAL_DECISION`. That action is recorded only as a timeline row (decision, reason, actor, time). No `resolution_verifications` row is written, so it is never reported as an independent staff resolution plus verification.

## 6d. Staff eligibility and combined roles (revision 4)

**Eligibility to receive or handle an assignment** (`cc_auth_staff_eligible`; applies both to reassignment targets and to assignees acting on a complaint):

| Check | Levels 1–3 | Level 4 |
|---|---|---|
| `staff.is_active = TRUE` and `verification_status = 'VERIFIED'` | required | required |
| linked `users.is_active = TRUE` | required | required |
| active role | **STAFF** | **PRIMARY_COMPLAINT_OFFICER**, and the user must be the singleton officer |
| membership | exact (department, level), plus `can_resolve`/`can_escalate` when the action needs it | none (Level 4 is never granted by membership) |

An inactive account, a deactivated STAFF role, a deactivated or unverified profile, or a missing exact membership makes the target ineligible. S2_E tests E25–E29 cover this.

**Role inheritance.** A user's permissions are the **union of the permissions of all of their active roles**. The Primary Officer is required to be staff and normally also holds an active **STAFF** role, so it inherits `complaint:submit_resolution`.

- Assigned to a Level 1–3 complaint, with an exact membership carrying `can_resolve`, the officer **can submit a resolution**.
- Separation of duties (R16) still applies: the officer **cannot approve that submission**. It must **return** it, or the approval must wait until officer authority is **transferred** to another person.
- S2_E tests E19b, E19c, E20, E21 and E21b cover this.
- Recommendation: in normal operation, give the officer no Level 1–3 handling memberships.

## 7. Development activation CLI (`cc_v2_dev_activation_cli`)

| Object | Privilege |
|---|---|
| `users` | SELECT (`user_id`, `email`, `full_name`, `is_active`), so no password hashes |
| `user_roles`, `roles` | SELECT |
| `issue_account_token_operator`, `redeem_account_token` | EXECUTE |

The account is created **locked** with no password. The operator unlocks it only when needed:

```sql
ALTER USER 'cc_v2_dev_activation_cli'@'localhost' IDENTIFIED BY RANDOM PASSWORD ACCOUNT UNLOCK;
```

MySQL shows the generated password once, on the admin's own console. The operator stores it themselves in `.env.development` as `DB_ACTIVATION_PASSWORD`. Re-lock the account with `ALTER USER … ACCOUNT LOCK` when it's not in use.

`cli_activation.py` refuses to run unless all of the following hold:

- `DB_NAME = college_complaints_v2_dev`;
- `DB_HOST` is local;
- `DB_ACTIVATION_USER = cc_v2_dev_activation_cli`;
- after connecting, `DATABASE()` and `CURRENT_USER()` match.

It never prints credentials.

## 8. Token-issuance authorization boundary

| Caller | Procedure | Allowed when |
|---|---|---|
| Flask runtime | `issue_account_token(target, hash, purpose, ttl, actor)` | the actor is required, **and** one of: (a) actor = target, purpose `PASSWORD_RESET`, the actor is active (self-service); (b) the actor holds `system:manage_users`; (c) the actor holds `staff:verify_account`, purpose `ACTIVATION`, and the target has a staff profile |
| Dev CLI account only | `issue_account_token_operator(target, hash, purpose, ttl)` | the grant itself is the control; the runtime account gets error 1370 (probe T15) |
| Either | `redeem_account_token(hash, password_hash, OUT user)` | the token is the credential: live, unexpired, unrevoked, unused; the target is in the correct state |

As a result, a student can only issue or revoke tokens for **their own** account (probe T26). Only SHA-256 digests are stored, and raw tokens never reach the database or any log.

**Not yet supported:** an unauthenticated "forgot password" request has no actor, so it can't use `issue_account_token`. Stage 3 must design that flow, including rate limiting and handling of e-mail enumeration.

## 9. Trust boundary

1. All website users share one MySQL account, so MySQL **cannot prove which human** made a call.
2. **Flask must:**
   - authenticate the user (session and CSRF);
   - take `p_actor_user_id` **only from the server-side session**;
   - authorize the route;
   - call the procedures with autocommit on and no open transaction.
3. **The procedures independently re-check, for that actor:**
   - the account is active and in good standing;
   - the active role holds the specific permission;
   - there is an **exact department and level membership**, with `can_resolve` or `can_escalate` where relevant;
   - the actor is the active assignee;
   - the actor is the officer singleton, which requires a VERIFIED, active staff profile;
   - the state transition and workflow level are valid.
4. Workflow authority **never** comes from `staff.designation`.
5. A compromised Flask process can still impersonate any actor ID. That residual risk is R6 in the review.
6. The `@app_*` session variables are attribution context only.

## 10. Verification artifacts

- **S2_B** ends with `SHOW GRANTS` for all five accounts and lists every routine, trigger and view with its definer and security type.
- **S2_C** has 34 runtime probes plus 3 CLI-account probes.
- **S2_E** has the R13–R16 and revision 4 acceptance tests (34 checks: 17 self-checking PASS rows and 17 expected errors). **It modifies data**, so it must be run between a post-Stage-2 admin backup and its restore. **S2_D** has 14 migrator integrity probes, run in a transaction that is rolled back.
- Both are designed to change nothing even if a control were missing.

## 11. R5 correction and static privilege coverage

- In S2_B, every mixed `GRANT SELECT, INSERT, UPDATE (cols)` statement for the routine definer (on `complaint_assignments`, `resolution_verifications`, `primary_officer_assignment`, `user_roles` and `account_activations`) is now split into **separate SELECT, INSERT and column-UPDATE statements**.
- MySQL already parsed the old form as table-level INSERT, so the effective privileges are unchanged. The split makes the bootstrap INSERT on `primary_officer_assignment` explicit and impossible to misread.
- A static coverage analyser (`priv_coverage.py`, session scratchpad) checked every table and column operation in all 21 routines and triggers against the grants of each object's definer. That covers SELECT (FROM/JOIN), INSERT columns, UPDATE SET columns, `FOR UPDATE` locking requirements, TRIGGER and internal `CALL` targets. **Result: no gaps.**
