# CampusCare 2.0 – Stage 2 Migration Static Review (Claude)

**Scope:** static review and correction of the Stage 2 migration artifacts only.
**Nothing was executed against MySQL.** No connection was opened to `college_complaints` or
`college_complaints_v2_dev`; the Flask app, templates and static assets were not changed;
`.env.development` was not opened; no backups were touched.

**Inputs:**

- `CAMPUSCARE_V2_AUDIT_FINAL.md`, the approved architecture. It was read but not modified.
- `STAGE2_STATIC_REVIEW.md` was named in the handover but **does not exist** in the project folder. The review therefore relies on the code itself and on the architecture document.
- The Stage 1 baseline schema in `college_complaints_baseline_20261114_185854.sql`. Only its DDL was read: table definitions, the trigger, the procedure and the views.

**Originals preserved:** Antigravity's files were copied unchanged to
`migrations/_original_antigravity/`. The folder is not a git repository, so that copy is the only diff base. Line numbers quoted below refer to those copies.

**Verification performed (offline only):**

- All Python files compiled with Python's `ast` parser.
- All SQL files went through a custom offline lint, `sql_lint.py`, kept in the session scratchpad. It checks:
  - DELIMITER pairing and BEGIN/END and IF/END IF balance per routine;
  - parenthesis and quote balance;
  - that SIGNAL `MESSAGE_TEXT` is at most 128 characters;
  - that every backticked identifier exists in the baseline schema plus the new DDL;
  - that the definer of every routine and trigger is correct, and that no root definer appears;
  - that the legacy trigger is dropped before its replacement is created;
  - that the runtime account has no write grant on sensitive complaint columns and no EXECUTE on internal helpers.

  Result: clean. The only "unknown" identifiers are the legacy objects being dropped (`update_complaint_status` and the pre-review guard-trigger name).
- **Not verifiable without a server:** MySQL-version-specific behaviour. See *Unresolved risks* (R1–R7).

---

## Revision 4: final pre-execution corrections

These are targeted static edits only. **No MySQL connection was opened, no SQL or runner was executed, and `college_complaints` and `college_complaints_v2_dev` were not touched.** The Flask app is unchanged. Where this section conflicts with earlier revisions, this section wins.

| # | Item | Finding and correction | Files |
|---|---|---|---|
| 1 | **Inactive staff assignment (critical)** | Confirmed. `cc_auth_staff_eligible` checked only `staff.is_active` and `verification_status`, so a VERIFIED profile whose **user account** or **STAFF role** was inactive could still receive an assignment. It now requires all of the following. **All levels:** an active staff profile, `VERIFIED`, and an **active linked `users` account**. **Levels 1–3:** additionally an **active STAFF role** and the exact department and level membership (with `can_resolve`/`can_escalate` where needed). **Level 4:** the profile must belong to the current Primary Officer singleton holding an **active PRIMARY_COMPLAINT_OFFICER role**. `cc_auth_is_assigned_staff` and `reassign_complaint` both use this helper, so assignees and reassignment targets are covered. The reassign error now names the cause. | `008` |
| 1 | Negative tests | **E25–E29.** Assigning to a legacy staff member with an active VERIFIED profile and a Level 1 membership but an **inactive account** is refused, and no ledger row is written. Assigning to a staff member with an active account but a **deactivated STAFF role** is refused. | `S2_E` |
| 2 | **Officer role inheritance** | Documented explicitly: a user's permissions are the **union of all active roles**. The officer must be staff, so an officer with an active STAFF role inherits `complaint:submit_resolution`. When assigned to a Level 1–3 complaint with an exact membership carrying `can_resolve`, the officer **can submit** a resolution. Under R16 it **cannot approve its own submission**: it must return it, or approval waits until officer authority is transferred. This behaviour is kept, because it is consistent with R16. New tests **E19b** (both roles active), **E19c** (submission through the inherited STAFF permission), **E20/E21** (self-approval refused) and **E21b** (return allowed; nothing approved). | `002` (comment), `S2_E`, `STAGE2_SECURITY_GRANTS.md` §6d |
| 3 | **`student_id` FK vs the CHECK constraint** | The baseline was **inspected** rather than assumed: `college_complaints_baseline_20261114_185854.sql` line 119 (identical in `schema_latest.sql` and `backup_before_v2.sql`) reads ``CONSTRAINT `complaints_ibfk_1` FOREIGN KEY (`student_id`) REFERENCES `students` (`student_id`)``. It has **no `ON DELETE`/`ON UPDATE` clause**, which means NO ACTION (behaves as RESTRICT). That is **compatible** with `chk_complaint_complainant_type`, so **no FK replacement is needed**, the FK is kept, and every student relationship is preserved. The new FK on `external_id` is declared without a referential action. Defence in depth: the runner's 005 pre-check now reads the **live** `DELETE_RULE`/`UPDATE_RULE` of every FK on `complaints.student_id`/`external_id` and halts unless the only FK is `complaints_ibfk_1` with NO ACTION/RESTRICT. | `005` (comment only), `run_migrations.py` |
| 4 | **Final static review** | The results are in the next subsection. | – |

### Final static review (revision 4)

- **R13–R16 tests against the procedure code.** All 34 S2_E checks (17 PASS rows and 17 expected errors) were re-traced by hand against the revision 4 procedures.
  - The fixture actors (A, R, O) are legacy staff who keep their 006 STAFF role and are activated by the fixture, so they satisfy the stricter eligibility rule.
  - The Level 4 officer path satisfies the active-officer-role check.
  - Without the fix, E26 and E28 would have assigned the complaint. With it they are refused before any ledger write.
  - **The tests have not been executed.**
- **Inactive-staff assignment test:** included (E25–E29).
- **Assignment and escalation audit consistency.**
  - `reassign_complaint` closes the active ledger row only if it matches the cached assignee, opens the new row, then updates the cache. The guard trigger rejects any cache value that differs from the active ledger row.
  - `escalate_complaint` writes the escalation row, closes the active assignment (`unassigned_by_user_id` = the escalating actor), and sets `assigned_staff_id = NULL` in the same transaction. The trigger's ledger and level checks hold, and exactly one timeline row is written per escalation and per assignment.
  - E14 and E17 assert the full trail.
- **Hard-coded credentials: none.** The only `IDENTIFIED BY` text is `IDENTIFIED BY RANDOM PASSWORD`, which makes MySQL generate the password; it is used in the CLI unlock instructions. The scan covered every bundled file except the preserved originals.
- **Checksums:** regenerated in the r4 bundle's `MANIFEST_SHA256.txt`. The runner records each file's checksum at execution and halts if an applied file later changes.
- **Databases:** untouched. No connection was made in any revision.
- **Offline checks:** AST parse OK. SQL lint clean, apart from the legacy names being dropped. Grant review clean, with the allowlist's 10 of 10 cases passing.

### Files changed in revision 4

- `migrations/008_triggers_and_procedures.sql` (`cc_auth_staff_eligible`, reassign message and comment)
- `migrations/005_alter_existing_tables.sql` (comment only, documenting the inspected FK)
- `migrations/002_rbac_initial_seeds.sql` (comment only, documenting role inheritance)
- `migrations/run_migrations.py` (live FK-rule pre-check before 005)
- `migrations/admin/S2_E_decision_acceptance_tests.sql` (E19b, E19c, E21b, E25–E29)
- `STAGE2_CLAUDE_REVIEW.md`, `STAGE2_SECURITY_GRANTS.md`, `STAGE2_EXECUTION_GUIDE.md`

**Unchanged:** `000`, `001`, `003`, `004`, `006`, `007`, `S2_A`, `S2_A2`, `S2_B`, `S2_C`, `S2_D`, `cli_activation.py`.

### Operational consequence (please note)

Legacy staff remain **ineligible to receive new assignments, or to resume work, until their accounts are activated**. The 200 existing legacy assignments stay in the ledger unchanged. The intended order after Stage 2 is: activate the staff accounts, configure memberships, then assign work.

---

## Revision 3: approved decisions R13–R16

This revision implements decisions R13–R16 as approved. It was static correction only. **No MySQL connection was opened, nothing was executed, and neither database was modified.** The Flask app is untouched.

Where this section conflicts with the revision 2 or revision 1 text, **this section wins**.

| Decision | Implementation | Tests |
|---|---|---|
| **R13: detail editing** | New `update_complaint_details(complaint, actor, title, description, category, priority, reason)`. **The runtime account's UPDATE on `complaints` was revoked**, so it has neither INSERT nor UPDATE on the table. Edits are allowed on two paths. **Owner:** the complainant, with `complaint:edit_own`, **only while Submitted**. **Supervisory:** the officer, or department authority at or above max(2, level), with `complaint:edit_details`, on any non-final status, with a reason required. Only the four fields can change, and NULL leaves a field unchanged. Each edit writes a `DETAILS_EDITED` timeline row with the editor, time, modified fields and reason. | S2_C T06b, T27b–d; S2_E E02–E04, E08–E10 |
| **R14: exact level matching** | Investigation, resolution submission and escalation requests need the **active assignment plus an exact membership** at the complaint's department and level; a Level 1 member gains nothing at Level 2 or 3. Supervision (view, assign, reject, edit, execute escalation) uses department authority at or above max(2, level). It is a separate permission and never gives the right to investigate. The permission families are listed in STAGE2_SECURITY_GRANTS §6b. The former `complaint:triage` permission was removed, because only the assignee accepts. The officer gains `complaint:update_investigation` so it can accept Level 4 work assigned to its own profile. Designation is never read. | S2_E E05–E07, E11–E13, E16, E22–E23 |
| **R15: escalation reassignment** | `escalate_complaint` now writes the escalation row (reason and actor), updates the level, **closes the active assignment** (attributed to the escalating actor), clears `assigned_staff_id`, and sets `Escalated`, meaning awaiting assignment. `reassign_complaint` then assigns an exact member of the new level, and only that assignee can accept (`ESCALATION_ACCEPTED`). The previous assignee loses every handling path. The ledger and timeline keep the full trail. | S2_E E14–E17, E22–E24 |
| **R16: separation of duties** | `RPV → Resolved` is refused when the approving officer is the user who **submitted** the pending resolution. The Level 4 direct path is recorded as **`OFFICER_FINAL_DECISION`**, with a timeline row of `Decision: <status>. Reason: <reason>`, plus the actor and time. **No `resolution_verifications` row is written**; the revision 2 behaviour (a fabricated APPROVED verification) was removed. Officer rejections at Level 4 are also recorded as `OFFICER_FINAL_DECISION`. | S2_E E18–E21, E24 |

### Files changed in revision 3

- `migrations/002_rbac_initial_seeds.sql`:
  - `triage` removed;
  - `26 complaint:edit_own` (student, external) and `27 complaint:edit_details` (reviewer, officer) added;
  - the officer gains 6;
  - permission-family comment added;
  - 27 permissions in total.
- `migrations/008_triggers_and_procedures.sql`:
  - `transition_complaint_status` rewritten;
  - `escalate_complaint` closes the assignment;
  - `update_complaint_details` is new;
  - header updated;
  - 17 routines in total.
- `migrations/admin/S2_B_post_migration_grants.sql`: runtime UPDATE on `complaints` revoked; runtime EXECUTE on `update_complaint_details`; definer UPDATE on the four detail columns.
- `migrations/admin/S2_C_runtime_negative_tests.sql`: now 34 runtime probes plus 3 CLI probes. Direct UPDATEs now expect error 1142.
- **New** `migrations/admin/S2_E_decision_acceptance_tests.sql`: 24 self-checking R13–R16 scenarios. It **modifies data** and must be bracketed by a post-Stage-2 admin backup and restore (guide Step 6b).
- `migrations/run_migrations.py`: expects 17 routines and 27 permissions.
- `STAGE2_CLAUDE_REVIEW.md`, `STAGE2_SECURITY_GRANTS.md`, `STAGE2_EXECUTION_GUIDE.md`.

These files did not change in revision 3: `000`, `001`, `003`–`007`, `S2_A`, `S2_A2`, `S2_D`, `cli_activation.py`.

### Offline verification (revision 3)

- **AST parse:** OK.
- **SQL lint:** clean, apart from the legacy names being dropped. All 21 routine and trigger definers are correct.
- **Grant review:** no runtime INSERT or UPDATE on `complaints`; the CLI holds exactly the operator and redeem procedures; every `CALL` target is executable by the definer; every permission key used in 008 is seeded.
- **Leftover references:** none to `complaint:triage` or the removed `RESOLVED_BY_OFFICER_LEVEL4`.
- **Grant allowlist:** 10 of 10 offline cases still pass.
- The S2_E scenarios were traced by hand against the procedure code and the seeds. **They have not been executed.**

---

## Revision 2: independent-review corrections

Revision 2 responds to the eight points of the independent review. It was static correction only. **No MySQL connection was opened, no SQL or migration was executed, and neither database was modified.** The Flask app, templates and static files are untouched.

Where this section conflicts with the revision 1 text below, **this section wins**. Stale revision 1 statements have been corrected inline.

| # | Review point | Correction | Files |
|---|---|---|---|
| 1 | Migrator privilege reconciliation | S2_A now **revokes everything** (`REVOKE ALL PRIVILEGES, GRANT OPTION`) before granting the exact 14 schema privileges plus temporary SET_USER_ID. There is no DELETE, FILE, PROCESS, SUPER, SYSTEM_USER, GRANT OPTION or other schema. The runner replaces its substring check with an **exact allowlist parser** (`review_migrator_grants`) that rejects `ALL PRIVILEGES ON college_complaints_v2_dev.*`, unknown privileges, granted roles and other schemas; requires SET_USER_ID before 008; and halts `--preflight` if it is still held after Stage 2. Offline unit test: 10 of 10 cases behave as expected. | `admin/S2_A_*`, `run_migrations.py` |
| 2 | Workflow-level authorization | New `cc_auth_staff_eligible` covers handling authority. At Levels 1–3 it requires an **exact** membership (complaint department, current level). At Level 4 only the Primary Officer's own staff profile qualifies, and never for resolution submission or escalation. `cc_auth_is_assigned_staff` now checks both assignment and eligibility. In `transition_complaint_status`, every move into In Progress requires an eligible assignee, so an escalated complaint must be reassigned to a member at the new level; resolution submission requires `can_resolve`; and a new **Level 4 path** lets only the officer resolve directly, recorded as an APPROVED verification. Without that path, a Level 4 complaint could never be resolved, because no membership exists at Level 4. `reassign_complaint` validates the target's membership at the current level; at Level 4 the complaint keeps its department. New `request_escalation` checks the assignee's `can_escalate`. Department supervision (`cc_auth_department_authority`, at or above max(2, current level)) and the officer's global oversight are unchanged. Designation is never read. | `008` |
| 3 | Complaint submission ownership | **Direct INSERT on `complaints` was removed** from the runtime account. The new `submit_complaint(actor, type, department, title, description, category, priority, OUT id)` takes no complainant, student or external ID. It derives the profile from the actor and validates active account, good standing, active role, the matching `submit_*` permission, profile ownership, an existing service department, the field domains, and the initial state (defaults plus INSERT trigger). It also writes a SUBMISSION timeline row. Probes T13 and T21–T24. | `008`, `S2_B`, `S2_C` |
| 4 | Token issuance authorization | `issue_account_token` now **requires an actor**: self-service PASSWORD_RESET, `system:manage_users`, or `staff:verify_account` for staff ACTIVATION. A separate `issue_account_token_operator` is granted **only** to the new locked development account `cc_v2_dev_activation_cli`, which `cli_activation.py` uses and Flask never does. Both share the internal `cc_token_issue_core`. A student cannot issue or revoke tokens for another account (T26), and the runtime account cannot call the operator procedure (T15). Raw tokens are still never stored or logged. | `008`, `S2_A`, `S2_B`, `S2_C`, `cli_activation.py` |
| 5 | Primary Officer eligibility | `transfer_primary_officer` now requires an **active, VERIFIED staff profile** and rejects any account with a student or external profile. There is no exception path. `cc_auth_is_primary_officer` also requires that staff profile, so officer authority is suspended if it is deactivated. The singleton, locking, history and self-appointment ban are unchanged. | `008` |
| 6 | Runner recovery message | Per-migration dumps are renamed `forensic_checkpoint_pre_<ver>_<ts>.sql` and documented as **forensic only** (no routines). On failure the runner prints two labelled paths: **full recovery** (the admin baseline from `--baseline-checkpoint`, with drop, recreate, restore and re-run from 000) and **forensic only**. | `run_migrations.py`, guide |
| 7 | CLI environment safety | Before connecting, `cli_activation.py` requires `DB_NAME = college_complaints_v2_dev`, a local `DB_HOST` and `DB_ACTIVATION_USER = cc_v2_dev_activation_cli`. After connecting it verifies `DATABASE()` and `CURRENT_USER()`. It reads credentials only from `DB_ACTIVATION_*`, never prints them, and never references another schema. Error output no longer echoes raw exception text. | `cli_activation.py` |
| 8 | Locking-read documentation | Corrected. `FOR SHARE` needs only SELECT (used on `staff`). `FOR UPDATE` needs SELECT plus UPDATE, DELETE or LOCK TABLES (used on `complaints`, `users`, `primary_officer_assignment` and `account_activations`, where the definer holds column-level UPDATE). LOCK TABLES is kept as a documented precaution on the locked definer. Every definer grant is now justified line by line. | `S2_B`, `STAGE2_SECURITY_GRANTS.md` |

### Files changed in revision 2

- `migrations/008_triggers_and_procedures.sql`:
  - new routines: `cc_auth_staff_eligible`, `cc_token_issue_core`, `issue_account_token_operator`, `request_escalation`, `submit_complaint`;
  - changed routines: `cc_auth_is_primary_officer`, `cc_auth_is_assigned_staff` (new signature), `transition_complaint_status`, `reassign_complaint`, `transfer_primary_officer`, `issue_account_token` (new actor parameter);
  - 16 routines in total.
- `migrations/run_migrations.py`: grant allowlist, the post-Stage-2 SET_USER_ID check, routine list, forensic naming, recovery text.
- `migrations/admin/S2_A_pre_migration_accounts.sql`: migrator revoke-then-grant, locked CLI account, anonymous-account and protected-database checks.
- `migrations/admin/S2_B_post_migration_grants.sql`: definer grants for the new routines, runtime INSERT removed, CLI grants, corrected locking-read rationale.
- `migrations/admin/S2_C_runtime_negative_tests.sql`: now 30 runtime probes plus 3 CLI probes.
- `cli_activation.py`: dedicated issuer account and environment guards.
- `STAGE2_CLAUDE_REVIEW.md`, `STAGE2_SECURITY_GRANTS.md`, `STAGE2_EXECUTION_GUIDE.md`.

These files did **not** change in revision 2: `000`–`007`, `S2_A2`, `S2_D`.

### Offline verification (revision 2)

- AST parse of all Python files: OK, ASCII only.
- SQL lint: BEGIN/END and IF/END IF balance, MESSAGE_TEXT at most 128 characters, identifiers, definers (all 20 routine and trigger objects correct, no root), legacy trigger dropped first. Clean apart from the legacy names being dropped.
- Grant review: no INSERT on `complaints` for the runtime account; no runtime EXECUTE on `cc_*` or the operator procedure; the CLI holds exactly the operator and redeem procedures, with no password-hash column; every `CALL` target is executable by the definer; every public procedure is granted to someone.

---

## Severity summary of defects found in the original artifacts

| # | Sev. | File | Defect |
|---|---|---|---|
| D1 | **Critical** | 008 + runtime grants | The status guard relied only on the forgeable session variable `@app_status_transition_authorized`. The architecture document (§2.2) gives the runtime account `ALL PRIVILEGES` on the dev schema, so the app account could run `SET @app_status_transition_authorized = TRUE; UPDATE complaints SET status='Resolved' …` and bypass everything. The same was true for `assigned_staff_id`, `current_level_id`, `is_deleted` and the ledgers. |
| D2 | **Critical** | 005 | `complaint_history.old_status/new_status` were `VARCHAR(30)`. `'Resolution Pending Verification'` is **31** characters, so under `STRICT_TRANS_TABLES` every transition into or out of that state would fail with *Data too long*, inside the history trigger. |
| D3 | **Critical** | 003/004/008 | No `DEFINER` clause on any routine, so the definer silently became the migrator, which holds full DDL privileges. Procedures and triggers ran with migration-level authority. |
| D4 | High | 008 | `transition_complaint_status` had no state machine: any non-final status could go to any status, including back to `Submitted`, or from `Submitted` straight to `Resolved`. Reviewer and admin authority was **global**, not scoped to a department. SYSTEM_ADMIN could change status. No verification ledger was written. |
| D5 | High | 008 | Validation ran **before** `START TRANSACTION`, without `FOR UPDATE`. This is a time-of-check/time-of-use race: two concurrent transitions could both pass. |
| D6 | High | 004 | `reassign_complaint` had no authorization, department scope, staff-eligibility, complaint-state or locking checks, and no check that the ledger and cache agreed. |
| D7 | High | 003 | `transfer_primary_officer` had no actor validation, no validation of the new officer, and read the singleton `IF EXISTS` *before* locking it. History stored the person **ending** the tenure as `appointed_by_user_id`. |
| D8 | High | 002 | SYSTEM_ADMIN was granted **every** permission, including `complaint:verify_resolution`, which violates "officer-only resolution verification". |
| D9 | High | run_migrations.py | Passwords went on the `mysql` and `mysqldump` command lines (`--password=…`, lines 73–74 and 108–109), where they are visible in the process list. There was no ledger-based skip, so a re-run would have re-applied 005 (failing) and 006. The single checkpoint `checkpoint_pre_stage2.sql` was **overwritten on every run**. There were no pre/post assertions. `mysqldump` lacked `--no-tablespaces`, so it would need PROCESS and would probably fail for the migrator. |
| D10 | High | cli_activation.py | No token-redemption path existed, so requirements D5 and D6 (set the password, then activate only after verification) were not implemented. Expiry was computed in Python local time but compared by MySQL. "Invalidation" reused `is_used`, conflating *consumed* with *revoked*. |
| D11 | Medium | 006 | Output used `✓` characters. Under a Windows cp1252 pipe (the runner captures stdout) this raises `UnicodeEncodeError` **after** the DML, which rolls back the whole backfill. |
| D12 | Medium | 006/001 | A fake password hash `'LOCKED_PENDING_ACTIVATION'` was stored. Werkzeug's `check_password_hash` raises on it, producing HTTP 500 instead of a clean denial. This is effectively an invented placeholder password. |
| D13 | Medium | 005 | The legacy FK was found with an **unfiltered** `information_schema … LIMIT 1`. A re-run could drop the wrong FK, and a missing FK produced a NULL `PREPARE`. The DROP and ADD were separate statements, leaving a window with no FK. `complaints` was changed in three separate non-atomic ALTERs. |
| D14 | Medium | 004/006 | Legacy ledger rows got `assigned_at = NOW()`, a fabricated migration-day timestamp. Nothing at schema level prevented NULL-actor rows for new assignments. |
| D15 | Medium | 008 | Views were recreated as `SQL SECURITY DEFINER` (the default) with the migrator as definer. That is a privilege-escalation path and a dependency on the migrator account. |
| D16 | Low | 005 | `staff.designation NOT NULL DEFAULT 'Staff Member'` fabricated a designation for 15 legacy staff. |
| D17 | Low | 006 | A `MYSQL_ROOT_PWD` fallback existed (line 167). Collision errors printed e-mail addresses into logs. |

---

## File-by-file review and corrections

### `000_schema_migrations.sql`
- **Original:** correct.
- **Changes:** explicit `SET NAMES` and `sql_mode`; named the unique key `uq_schema_migrations_version`; `applied_at` is `NOT NULL`. No semantic change.

### `001_core_rbac_schema.sql`
- **Original issues:**
  - The `password_hash NOT NULL` design forced the placeholder described in D12.
  - `account_activations.is_used` conflated used and revoked tokens, and nothing guaranteed a single live token per user.
  - `idx_users_email` duplicated the UNIQUE index.
- **Changes:**
  - `users.password_hash` is nullable. NULL means no password has ever been set.
  - New `chk_users_active_requires_password`: an account can't be active without a password.
  - `account_activations` was redesigned:
    - new `purpose` column (`ACTIVATION` / `PASSWORD_RESET`);
    - new `used_at` and `revoked_at` columns, plus `chk_activation_single_terminal_state`;
    - a stored generated `live_user_id` with a **UNIQUE** key, so at most one live token per user;
    - `token_hash` is `ascii_bin`, checked against `^[0-9a-f]{64}$`;
    - UTC `created_at`;
    - the FK has no CASCADE, because MySQL forbids CASCADE on the base column of a stored generated column.
  - Named all constraints. Removed the redundant index.
- **Unchanged:** no `user_type` column (roles stay authoritative), and `external_complainants`.

### `002_rbac_initial_seeds.sql`
- **Original issues:** D8; the officer held `complaint:view_own`; no permission existed for triage or archive.
- **Changes:**
  - SYSTEM_ADMIN now holds only 14, 19 and 20–24 (oversight, reports, administration, audit). It has no workflow write permissions.
  - The officer no longer holds 3.
  - New permissions **25 `complaint:soft_delete`** (officer) and **26 `complaint:triage`** (reviewer and officer). Both are needed by the 008 procedures.
  - Still one explicit transaction, with deterministic IDs.
- A role alone is never sufficient. The procedures also require workflow membership, the active assignment, or the officer singleton.

### `003_workflow_and_singleton.sql`
- **Original issues:** D7; the seed DML ran outside a transaction alongside DDL; a membership row could grant Level 4.
- **Changes:**
  - **`transfer_primary_officer` moved to 008.**
  - The `workflow_levels` seed is in an explicit `START TRANSACTION … COMMIT` after all DDL.
  - `chk_workflow_level_range` added.
  - `staff_workflow_assignments.level_id` is limited to 1–3 (`chk_swa_level_not_officer_tier`), so Level 4 authority can only come from the singleton.
  - `primary_officer_assignment.transition_reason` is `NOT NULL` with no fake default. `assigned_at` is a plain DATETIME set by the procedure.
  - `primary_officer_history` now records `appointed_by_user_id` together with `appointment_reason` and `ended_by_user_id` together with `end_reason`, plus `chk_poh_tenure_order`.
- **Singleton guarantees:**
  - The PK plus `CHECK (singleton_id = 1)` means at most one row can exist, ever.
  - The table starts empty, and bootstrap is handled by the procedure.
  - Concurrent appointments serialize on the row or gap lock. A loser fails with a deadlock or duplicate-PK error and rolls back.

### `004_assignment_and_audit.sql`
- **Original issues:** D6 and D14; `resolution_verifications` could hold several PENDING rows for one complaint.
- **Changes:**
  - **`reassign_complaint` moved to 008.**
  - `complaint_assignments` gains:
    - `assignment_source` (`LEGACY_IMPORT` | `WORKFLOW`);
    - **`chk_assignment_actor_required`**: WORKFLOW rows must have both an actor and a time. Only legacy rows may have a NULL actor, and that is now enforced by the schema;
    - nullable `assigned_at` for legacy rows, plus a separate `recorded_at`;
    - `unassigned_by_user_id`;
    - `chk_assignment_active_state`.
  - The generated-column unique index `uq_single_active_assignment` is kept as designed. It is correct: inactive rows produce NULL, which MySQL never unique-checks.
  - `resolution_verifications`: a generated `pending_complaint_id` with UNIQUE (at most one PENDING row per complaint) and `chk_verification_decision_state`.
  - `complaint_escalations`: `chk_escalation_changes_level`.
  - FKs on columns referenced by CHECKs or generated columns are declared without an explicit referential action. The InnoDB default is NO ACTION, which behaves as RESTRICT.

### `005_alter_existing_tables.sql`
- **Original issues:** D2, D13, D16.
- **Changes:**
  - **One ALTER per table.** MySQL 8 DDL is atomic per statement, so each table is fully migrated or untouched.
  - `complaint_history`:
    - `old_status`/`new_status` widened to `VARCHAR(40)`;
    - the legacy FK `complaint_history_ibfk_1` is dropped **by name** (the name was verified in the baseline dump) and replaced by a RESTRICT FK in the same statement;
    - this uses `ALGORITHM=INPLACE` with `foreign_key_checks=0` for this one statement, because MySQL only supports DROP FK plus ADD FK in one statement with INPLACE. This is safe because the existing data is already guaranteed valid by the FK being replaced;
    - actor and `action_type` columns added.
  - `staff.designation` is nullable with no default.
  - New queue index `idx_complaints_dept_queue`.
- **Idempotency:** MySQL 8.0 has no `ADD COLUMN IF NOT EXISTS`. The runner therefore asserts beforehand that none of the 15 new columns exist and that the CASCADE FK is present, and halts on any partial state.

### `006_data_backfill_and_sync.py`
- **Original issues:** D11, D12, D17; it reused an existing user found by e-mail (unsafe on re-run); it made no count assertions; its ledger write was not atomic with the data.
- **Changes:**
  - **Preconditions:** `users` is empty, nothing is linked yet, the ledger is empty, and the baseline counts match.
  - **Users:** one inactive user per student and per staff member, with **`password_hash = NULL`**.
  - **Roles:** resolved by name, not assumed by ID.
  - **Legacy staff:** marked `VERIFIED` with `staff.is_active = TRUE` (see A1), while login stays inactive. Each gets a Level 1 membership. `verified_by` and `verified_at` stay NULL; no verifier is invented.
  - **Legacy assignments:** one `LEGACY_IMPORT` row per assigned complaint, with **`assigned_by_user_id = NULL` and `assigned_at = NULL`**.
  - **Assertions before COMMIT:**
    - 117 users, all inactive with no password, and 117 role rows;
    - 15 memberships;
    - nothing left unlinked;
    - 200 active assignments and 2 unassigned complaints;
    - zero mismatches between cache and ledger, or between complainant and student;
    - zero legacy rows with an invented actor.
  - **Transaction:** one transaction, with the runner's ledger row written *inside* it through a `before_commit` callback.
  - **Output:** ASCII only, and counts only (no e-mails).
  - **Direct execution:** refused; the file must be run through the runner.

### `007_enforce_complainant_not_null.sql`
- **Original:** functionally adequate, but the counts were captured in session variables *before* the assertion procedure existed.
- **Changes:**
  - The counts are computed inside the temporary procedure at CALL time, with a NULL-safe comparison and an extra "no complainant link" assertion.
  - The procedure is `SQL SECURITY INVOKER` and is dropped after use.
  - Then `MODIFY … NOT NULL`. Strict mode would reject this anyway if a NULL remained.

### `008_triggers_and_procedures.sql` (rewritten)
**Trust boundary, stated explicitly:**

- The Flask runtime account has **no UPDATE privilege** on any of these complaint columns: `status`, `assigned_staff_id`, `department_id`, `current_level_id`, `complainant_user_id`, `is_deleted`, `deleted_*`, `resolved_at`. It also has no write access to any ledger. This privilege boundary is **the** control.
- Every application request shares one MySQL account, so MySQL cannot prove which website user made a call.
- Flask must therefore authenticate the user, take `p_actor_user_id` from the server-side session, and authorize the action first.
- The procedures then independently re-validate the actor's account state, active roles, permissions, department workflow membership, assignment and workflow level.
- `@app_status_transition_authorized` is documented and used **only** as an accident guard for privileged human or migration accounts. It is never treated as a security mechanism. Test S2_C/T01 proves that the runtime account is denied even with the variable set to TRUE.

**Routines.** Every procedure is `DEFINER = 'cc_v2_dev_routine_definer'@'localhost'`, `SQL SECURITY DEFINER`, uses the locked account, and is never root.

- **Internal helpers:** `cc_auth_has_permission`, `cc_auth_is_primary_officer`, `cc_auth_department_authority`, `cc_auth_staff_eligible`, `cc_auth_is_assigned_staff` and `cc_token_issue_core` (revision 2). They are procedures with OUT parameters rather than stored functions, because creating stored functions with binary logging enabled requires SUPER.
- **`transition_complaint_status`:**
  - opens the transaction first, then locks the complaint row (`SELECT … FOR UPDATE OF c`);
  - enforces an explicit state machine (in the header);
  - Resolved and Rejected are final;
  - `Escalated` can only be reached through `escalate_complaint`, and `Submitted` is initial only;
  - entering RPV requires the assigned staff member and notes, and creates a PENDING verification;
  - RPV → Resolved or In Progress is officer-only (`verify_resolution`) and updates the verification row;
  - Rejected requires department authority or the officer, plus a reason;
  - remarks are length-validated;
  - session variables are cleared at the start, at the end, and in the exception handler.
- **`escalate_complaint` (new):**
  - the only path that changes `current_level_id`;
  - writes `complaint_escalations` first;
  - non-officers may only go up exactly one level, and need `can_escalate` and `escalate_tier`;
  - the officer may go to any higher level;
  - writes exactly one timeline row in all cases.
- **`reassign_complaint`:**
  - same department: department authority, with `assign_staff` when unassigned or `reassign_staff` otherwise;
  - cross-department: officer with `reassign_global`, and `department_id` follows the staff member;
  - the target staff member must be VERIFIED, active and linked to a user;
  - forbidden on final or RPV complaints;
  - the ledger row is closed with a check that it matches the cached pointer, the new row is opened, then the cache is updated;
  - writes a timeline entry.
- **`soft_delete_complaint` (new):** officer only, attributed, one-way, and keeps every audit row.
- **`transfer_primary_officer`:**
  - the actor needs `system:manage_roles`; self-appointment is forbidden;
  - the new officer must exist and be active, must have an **active, VERIFIED staff profile**, and must have **no student or external profile** (revision 2);
  - the singleton is locked before deciding between bootstrap and transfer;
  - history records the correct appointer and the person who ended the tenure;
  - the old officer's role is deactivated and the new one's activated.
- **Revision 2 additions:** `submit_complaint` (the only creation path) and `request_escalation`. Token issuance is split into actor-checked `issue_account_token` (runtime) and `issue_account_token_operator` (development CLI account only). See the Revision 2 section.
- **`issue_account_token` / `redeem_account_token` (new):**
  - token lifecycle D1–D7 (next section), validated with UTC;
  - generic failure messages, so the response is not an oracle;
  - only real Werkzeug scrypt or pbkdf2, or Argon2id, password hashes are accepted.
- **Transactions:** every procedure has `START TRANSACTION`, an `EXIT HANDLER FOR SQLEXCEPTION` that does `ROLLBACK` then `RESIGNAL`, explicit `COMMIT`, and a `NOT FOUND` handler.

**Triggers.** Definer `cc_v2_dev_trigger_definer`, a locked account.

- **Legacy trigger:** the v1 `trg_complaint_status_history` is **explicitly dropped first**, then recreated under the same name. The runner asserts there is exactly **one** AFTER UPDATE trigger on `complaints`, so duplicate history rows are impossible.
- **`trg_validate_complaint_identity_insert/_update`:**
  - reject a NULL or mismatched `complainant_user_id`;
  - make `complainant_user_id`, `student_id` and `external_id` immutable;
  - require a new complaint to start Submitted, unassigned, at Level 1 and not archived;
  - use scalar subqueries rather than `SELECT … INTO`.
- **`trg_guard_complaint_sensitive_update`:**
  1. the status accident guard;
  2. `assigned_staff_id` must equal the **active ledger row**, which is a real, non-forgeable integrity check because the runtime account cannot write the ledger;
  3. a `current_level_id` change must match the **latest escalation row**;
  4. archiving is one-way and must be attributed.

**Views.** All four are recreated as **`SQL SECURITY INVOKER`**. They keep the original columns, support external complainants, and filter out soft-deleted rows.

### `run_migrations.py` (rewritten)
- **Modes:** `--plan` (offline), `--preflight` (read-only) and `--execute`. Execute requires `--confirm-target college_complaints_v2_dev` **and** `--baseline-checkpoint <admin dump>`.
- **Hard guards:**
  - DB name, account name and a local host;
  - the protected schema must be **invisible** to the migrator (`INFORMATION_SCHEMA.SCHEMATA`);
  - MySQL 8.0, and a `utf8mb4_unicode_ci` schema default;
  - the migrator must hold no SYSTEM_USER, SUPER, GRANT OPTION or global ALL.
- **Credentials:** written to a temporary MySQL option file (created exclusively, deleted afterwards). They are never on argv and never printed.
- **Ledger:**
  - SUCCESS versions are skipped after their checksum is verified;
  - a checksum mismatch halts;
  - a FAILED row halts, except for the re-runnable 008;
  - gaps in the order are detected.
- **Assertions:**
  - baseline assertions (counts, the 200/2 assignment split, the CASCADE FK, the legacy trigger, no Stage 2 tables yet);
  - per-migration fingerprints (absent before, present after);
  - full post-flight assertions: 22 tables, preserved counts, 117 users, ledger/cache parity, legacy actors NULL, routine and trigger definers, view security type.
- **Checkpoints:** a uniquely named `backups/stage2/checkpoint_pre_<ver>_<timestamp>.sql` before every migration, refusing to overwrite. The dump uses `--no-tablespaces --set-gtid-purged=OFF --skip-routines --triggers`.
- **006:** runs in-process on the runner's connection, with its ledger row written in the same transaction. No password is passed through the environment.

### `cli_activation.py` (rewritten)
Requirements D1–D7:

| Requirement | How it is met |
|---|---|
| D1 Fresh CSPRNG token | `secrets.token_urlsafe(32)` (256 bits) |
| D2 Store only SHA-256 | Only the hex digest is sent; the column is `ascii_bin` with a CHECK |
| D3 Invalidate earlier unused tokens | `cc_token_issue_core` (behind `issue_account_token_operator` for the CLI) sets `revoked_at` on all live tokens, and the UNIQUE `live_user_id` allows one live token per user |
| D4 Expiry | `expires_at` is computed and checked in UTC by MySQL; 5 minutes to 7 days |
| D5 Password only after verification | `redeem_account_token` verifies the token under a row lock before writing `password_hash` |
| D6 Activate only after verification | `is_active = TRUE` in the same transaction; the token is marked `used_at` |
| D7 No secrets in logs | The raw token is shown once on the terminal or written to a new file (`--link-file`, never overwritten); the runner never invokes the CLI; passwords are read with `getpass` and only the scrypt hash leaves the process |

Further changes:

- A `DB_NAME` guard.
- `autocommit=True`, because the procedures own their transactions.
- Activation is refused for unverified or deactivated staff, users without an active role, and accounts that already have a password.
- The hard-coded `--demo-links` personas were removed: those e-mail addresses are not known to exist.

---

## Requirement traceability (handover §5)

| Requirement | Status |
|---|---|
| A. Direct status update prevented, even with the variable TRUE | ✔ Privilege boundary (S2_B), proven by test S2_C T01; the trigger is accident-guard only |
| B. Sensitive columns only via procedures | ✔ status, assignee/department, level, complainant, is_deleted and resolved_at are all procedure-only; the ledger cannot be bypassed (T07, plus D02 integrity check) |
| C. Procedure security | ✔ Restricted locked definer, transactions, handlers, actor, permission, membership and level validation, state machine |
| D. Token lifecycle | ✔ Table above |
| E. Officer singleton | ✔ PK + CHECK, bootstrap, locking, history, separation of duties |
| F. Assignment integrity | ✔ Generated unique index, CHECK on the actor, ledger-to-cache trigger check, legacy rows NULL |
| G. Trigger integrity | ✔ Explicit drop before create; one AFTER UPDATE trigger asserted; identity triggers |
| H. Existing records preserved | ✔ No deletes; counts asserted (202/102/15/155/5/10, 200/2) |
| DDL/DML separation, ordering, ledger, checkpoints, assertions, recovery | ✔ Runner and execution guide |
| 22 tables (16 new) | ✔ No extra tables added; asserted at post-flight |

---

## Assumptions (please confirm)

- **A1 – Legacy staff standing.** The 15 legacy staff are marked `verification_status='VERIFIED'` and `staff.is_active=TRUE`, because they currently hold the 200 valid assignments. Login stays blocked (`users.is_active=FALSE`) until activation. `verified_by_user_id` and `verified_at` stay NULL. The original draft set `staff.is_active=FALSE`, which would have left them unassignable until an officer re-enabled them.
- **A2 – Workflow policy choices encoded in 008.** Please confirm each:
  - SYSTEM_ADMIN is outside the complaint workflow;
  - an administrator cannot appoint themselves officer;
  - non-officers escalate exactly one level;
  - no reassignment while a resolution awaits verification;
  - investigation requires an assignee;
  - Level 4 belongs only to the officer.
- **A3 – Baseline counts.** The history count is **155**, as stated in the handover. The architecture document (§2.4) says 156. The runner asserts 155 and halts on any difference. Records are never deleted to make the numbers match.
- **A4 – Environment keys.** `.env.development` uses the key names the original scripts used: `DB_HOST`, `DB_NAME`, `DB_MIGRATOR_USER` and `DB_MIGRATOR_PASSWORD` for the migrator; `DB_USER` and `DB_PASSWORD` for the runtime account; optionally `DB_PORT`. The file was not opened to check.
- **A5 – Schema collation.** The dev schema default collation is `utf8mb4_unicode_ci`, as created in Stage 1. The runner asserts this.

## Unresolved risks (cannot be settled statically)

1. **R1.** `DROP FOREIGN KEY` plus `ADD FOREIGN KEY` in one `ALGORITHM=INPLACE` ALTER with `foreign_key_checks=0` (005). This is documented MySQL behaviour. If the server refuses, the statement changes nothing and the runner halts. The fallback is to split it into two ALTERs.
2. **R2.** CHECK constraints on FK columns: FKs were declared without an explicit action to avoid ER 3823. This needs confirming on 8.0.46.
3. **R3.** Column-level UPDATE on base columns of generated columns, and whether column-level UPDATE satisfies the 8.0.22+ `FOR UPDATE` privilege check. `FOR SHARE` needs only SELECT. This is mitigated by a schema-level `LOCK TABLES` grant to the locked definer, and tests S2_C and S2_D will surface any gap.
4. **R4.** Dropping or replacing the v1 objects whose definer is `root@localhost` (restored in Stage 1) may require SYSTEM_USER on some builds. Fallback: `admin/S2_A2_optional_drop_root_defined_legacy_objects.sql`, then re-run 008, which is idempotent.
5. **R5.** `MODIFY … NOT NULL` on an FK column (007), and `REGEXP` inside a CHECK (001). Both are expected to work on 8.0.
6. **R6.** The shared application account is a trust boundary. If the Flask process is compromised, an attacker can act as any `p_actor_user_id` and can issue reset tokens. The procedures limit what each actor may do, but they cannot authenticate the human behind the call.
7. **R7.** Restores always need an admin. Dumps contain `DEFINER=root` and `cc_v2_dev_*` objects, which require SET_USER_ID or SYSTEM_USER to recreate. Per-migration checkpoints exclude routines; the admin baseline includes them.
8. **R8.** **Stage 2 makes the legacy Flask app incompatible with the dev database.** The app does direct `UPDATE complaints SET status`, and it inserts students without a user link. This is expected: the redesign is Stage 3. Note also that `app.py` currently **defaults to the protected database** (`DB_NAME` defaults to `college_complaints`, `DB_USER` to `complaint_app`). That should be fixed in Stage 3. It was not touched here.
9. **R9.** Deferred to Stage 3, and not invented here:
   - registration procedures and grants (users, students, external profiles, staff applicants; the runtime account currently has no INSERT on `users`, `students`, `user_roles` or `complaints`);
   - an unauthenticated "forgot password" flow, which cannot use the actor-checked `issue_account_token`;
   - staff verification and access-toggle procedures;
   - workflow-membership management;
   - **first SYSTEM_ADMIN bootstrap**, which needs a deliberate admin action;
   - `complaint:withdraw_own`, which has no workflow state yet;
   - notifications are created by the app, not by the procedures;
   - (resolved in revision 2: staff escalation requests are now recorded by `request_escalation` as `ESCALATION_REQUESTED` timeline rows).
10. **R10.** Callers must invoke the procedures with autocommit on and no open transaction, because `START TRANSACTION` inside a procedure implicitly commits pending caller work.
11. **R11.** Time handling is mixed: tokens are UTC; other timestamps follow the server's session time zone, using a mix of TIMESTAMP and DATETIME.
12. **R12 – Hygiene.**
    - `CAMPUSCARE_V2_AUDIT_FINAL.md` (§2.2, §2.3) contains a **literal development password**. If it is the real one, rotate it and keep it out of shared documents.
    - `.gitignore` ignores `*.sql`, which would also exclude every migration file if this folder becomes a git repository. Add `!migrations/**/*.sql`.
    - `--preflight` final-state assertions are only valid immediately after Stage 2, before any application activity.
13. **R13: resolved in revision 3.** Detail edits go only through `update_complaint_details`, and the runtime account has no UPDATE on `complaints`.
14. **R14: resolved in revision 3.** Exact-level handling is approved and implemented, with separate supervisory permissions.
15. **R15: resolved in revision 3.** Escalation closes the assignment and the new-level assignee must accept. Operational impact: every escalation needs an explicit reassignment.
16. **R16: resolved in revision 3.** Self-approval is refused, and Level 4 decisions are recorded as `OFFICER_FINAL_DECISION` without a verification row. Remaining limitation: if the officer submits a resolution while acting as a Level 1–3 handler, nobody else can approve it, because the officer is a singleton. It would stay pending until the officer returns it or the officer role is transferred. Avoid giving the officer handling memberships in normal operation.
17. **R17.** The `cc_v2_dev_activation_cli` password is generated by MySQL (`RANDOM PASSWORD`) and stored by the operator in `.env.development`. The account should stay locked except while it is in use. Its operator procedure can issue tokens for any eligible account, which is acceptable only in the development sandbox and must not exist in production.
18. **R18.** None of the new authorization logic has run on a server. S2_C, S2_D and the **data-modifying** S2_E must be executed (S2_E between the post-Stage-2 backup and its restore) before Stage 2 is accepted.
19. **R19 (revision 3).** S2_E activates six existing migrated accounts with a random, unusable password hash and grants test roles. Skipping the Step 6b restore would leave these fixtures in the sandbox. The guide makes the restore mandatory, and Step 7 confirms the pristine state.
20. **R20 (revision 3).** View permissions (`view_own`, `view_assigned`, `view_department_queue`, `view_all`) cannot be enforced row by row in MySQL for a shared account. Flask must filter every read query by the session user's scope, as designed in Stage 3.
