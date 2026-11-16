# CampusCare 2.0 – Stage 3 Application Report

**Target:** `college_complaints_v2_dev` as `complaint_app_v2_dev` only. `college_complaints` was not touched.
**Database changes made in Stage 3:** none. No schema, procedure, trigger, grant or data changes were made.

## 1. Structure
| Path | Purpose |
|---|---|
| `app.py` | Thin entry point (`create_app()`). The v1 app is preserved in `legacy/app_v1.py`, along with its template and CSS |
| `campuscare/config.py` | Loads `.env.development`. Refuses to start unless `DB_NAME=college_complaints_v2_dev`, `DB_USER=complaint_app_v2_dev`, the host is local and `FLASK_SECRET_KEY` is strong. No fallback to `college_complaints` |
| `campuscare/db.py` | One connection per request with autocommit. **Connection guard** checks `DATABASE()` and `CURRENT_USER()` on every new connection and closes any connection that does not match. Procedure allow-list (the 10 granted procedures). Direct writes are limited to `notifications`. SIGNAL 45000 messages are shown to the user; any other error gets a generic message, and only the error code is logged |
| `campuscare/security.py` | The session holds only `uid`, a CSRF token and a last-seen time. The identity (roles, permissions, student/external/staff profile, workflow memberships, officer status) is reloaded from the database on every request. Custom CSRF, idle timeout, and the decorators `login_required`, `permission_required` and `officer_required` |
| `campuscare/services.py` | Reads come from `complaint_details` and `department_complaint_summary`. Object-level visibility (`can_view`), plus `available_actions` mirroring the procedure rules. All writes go through procedures |
| `campuscare/blueprints/` | `auth` (login, logout, activation), `main` (dashboards), `complaints`, `notifications`, `reports` |
| `campuscare/templates/`, `static/css/app.css` | Tabler 1.0.0, Lucide 0.460.0 and Chart.js 4.4.1 from CDN. Navy sidebar, blue/teal accents, glass panels, responsive layout |
| `tests/test_readonly_integration.py` | Read-only integration harness against the dev database |

## 2. Features delivered
- **Authentication:**
  - werkzeug scrypt verification against a dummy hash, so timing does not reveal whether an account exists;
  - generic failure messages and a per-IP+username throttle (5 attempts per 5 minutes);
  - the session is cleared on login (fixation), with a 30-minute idle expiry;
  - logout is POST + CSRF only;
  - **activation and reset** go through `redeem_account_token`. Only the SHA-256 of the code is sent, never the code itself.
- **Dashboards:** chosen from the server-side identity.
  - Student / external: stats, own complaints, updates.
  - Staff L1: assigned queue, memberships, average resolution time.
  - Reviewer L2 / Head L3: unassigned and escalated queues, workload, priority and trend charts, department activity.
  - Primary Officer L4: verification queue, Level-4 complaints, department resolution rates, status mix, levels, live activity.
- **Complaints:** scoped lists (own / assigned / department queue / all) with filters. Detail view with a level stepper, timeline, escalations, assignment history and verifications.
  - **Actions:** submit, accept, submit resolution, verify (approve/return), Level-4 final decision, reject, assign/reassign, escalate, request escalation, owner/supervisory edit, archive.
  - **Procedures used:** `submit_complaint`, `transition_complaint_status`, `reassign_complaint`, `escalate_complaint`, `request_escalation`, `update_complaint_details`, `soft_delete_complaint`.
- **Rules enforced in Flask and in MySQL:**
  - an inaccessible complaint returns **404**;
  - an action that is not offered returns **403** before any database call;
  - escalation closes the assignment, and the UI then requires reassignment at the new level;
  - non-officers may escalate only one level;
  - a submitter cannot approve their own resolution (the procedure enforces this; the UI says so).
- **Notifications:** written after each successful action through the granted notification columns only. A notification is marked read only `WHERE user_id = <session user>`.
- **Reports:** institution-wide for the officer and `report:view_global`; department-scoped for members at Level 2 or above. Status, category, priority, 12-month trend, workload, average resolution days, activity log.

## 3. Test results (`python tests/test_readonly_integration.py`): **44/46**
**Passed:**
- **Guard:** the connection reports the right database and account.
- **Blocked in Python:** a non-allow-listed procedure, and a direct complaint write.
- **Before login:** anonymous users are redirected; the security headers are set.
- **Forms and sign-in:**
  - a POST without a CSRF token is refused (400);
  - an unknown user gets a generic refusal (401);
  - an unactivated account is refused;
  - an invalid activation code is refused;
  - no hashes appear in the pages.
- **Student:**
  - their own complaint is visible;
  - another person's complaint returns 404, including to a second student;
  - `scope=all` falls back to their own complaints;
  - reports return 403;
  - verify returns 403;
  - acting on someone else's complaint returns 404.
- **Staff L1:**
  - assigned complaints are visible; others return 404;
  - no assign/reject/verify controls are shown;
  - submit, escalate-tier, archive and reports all return 403.
- **Reviewer, head and officer screens:** they render, using an **in-memory** identity only. This shows the templates work; it does not test those roles' authorization.
- **No writes:** history, notification and status counts were unchanged after the run.

**Failed (data gaps, not code):**
- the sandbox has **no Level 2/3 workflow memberships**;
- **no Primary Officer has been appointed**.

## 4. Not verified / blockers (honest limitations)
1. **No end-to-end write test was possible.**
   - All 117 users are inactive and have no password, and no officer or admin exists. The procedures check that the actor is active, so every workflow action needs real activated accounts.
   - Unblocking this needs your decisions; none of them were taken:
     - (a) unlock `cc_v2_dev_activation_cli` and add `DB_ACTIVATION_USER/PASSWORD`;
     - (b) issue activation codes with `cli_activation.py`;
     - (c) add L2/L3 memberships and appoint an officer. **The runtime account has no grant for this, and it is not fake data only if you choose real people.**
2. **External complainant self-registration** is not possible: there is no procedure and no INSERT grant on `users`, `external_complainants` or `user_roles`. External users must be provisioned by an administrator outside the app.
3. **Withdraw** (`complaint:withdraw_own`) has no procedure path. `transition_complaint_status` allows Rejected only with `complaint:reject`. Withdraw is not offered.
4. **Comments and internal notes:** there is no table or procedure for them. Remarks entered with actions are stored in `complaint_history.remarks` and shown in the timeline.
5. **Staff verification/toggle, membership and role management:** there is no procedure or grant for any of them, so no admin screens were built. The administrator dashboard is read-only.
6. **Password reset delivery:** codes come from the CLI, and there is no email channel.
7. **Rate limiting** is in-process; it is not shared across workers. This is fine for the dev server; production needs a shared store.
8. **Browser check:** the pages have not been looked at in a browser. They were verified through the Flask test client only.

## 5. Running
```
python app.py        # http://127.0.0.1:5000  (refuses to start unless the guard passes)
python tests/test_readonly_integration.py
```
