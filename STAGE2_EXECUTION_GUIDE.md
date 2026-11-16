# CampusCare 2.0 – Stage 2 Execution Guide (revision 4, for LATER, after explicit approval)

> **Status: NOT EXECUTED.** Nothing in this guide has been run. Do not start until the
> project owner has approved execution against `college_complaints_v2_dev`.
> `college_complaints` is never a target of any step.

The commands are for **Windows PowerShell**, run from `C:\Users\rayan\Desktop\dbms_pbl`.

- Every `-p` makes the client prompt for the password. Never put a password on the command line.
- "Admin" means a MySQL administrative account such as root, used only for the account, grant, backup and restore steps.

```powershell
$bin = "C:\Program Files\MySQL\MySQL Server 8.0\bin"
```

## Two kinds of backup

| Backup | Made by | Contents | Use |
|---|---|---|---|
| **Admin baseline recovery backup** `backups\stage2\admin_pre_stage2_<stamp>.sql` | Admin, Step 1 | tables, data, triggers, **routines**, events | **The only full recovery image** for Stage 2 |
| **Forensic checkpoint** `backups\stage2\forensic_checkpoint_pre_<ver>_<stamp>.sql` | Runner, before each migration | tables, data, triggers; **no routines** | Investigating the state before a step. **Never** restore it as a full recovery |

## Step 0: Preconditions (no database changes)

1. Stop the Flask app and every other client of `college_complaints_v2_dev`.
2. Check the **key names** in `.env.development`. This command prints names only, never values:

   ```powershell
   Get-Content .env.development | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' } | ForEach-Object { ($_ -split '=', 2)[0].Trim() }
   ```

   Expected: `DB_HOST`, `DB_NAME`, `DB_MIGRATOR_USER`, `DB_MIGRATOR_PASSWORD`, `DB_USER`, `DB_PASSWORD` (`DB_PORT` is optional). `DB_ACTIVATION_USER` and `DB_ACTIVATION_PASSWORD` are added in Step 8.
3. Run the offline plan. It makes no connection; record the checksums against `MANIFEST_SHA256.txt` from the review bundle:

   ```powershell
   python migrations\run_migrations.py --plan
   ```

## Step 1: Admin baseline recovery backup (mandatory)

```powershell
New-Item -ItemType Directory -Force backups\stage2 | Out-Null; $stamp = Get-Date -Format yyyyMMdd_HHmmss; $cp = "backups\stage2\admin_pre_stage2_$stamp.sql"; if (Test-Path $cp) { throw "exists" }; & "$bin\mysqldump.exe" -u root -p --single-transaction --routines --triggers --events --no-tablespaces --set-gtid-purged=OFF --default-character-set=utf8mb4 --hex-blob "--result-file=$cp" college_complaints_v2_dev; Get-Item $cp
```

Keep the printed path. Step 4 needs it.

## Step 2: Admin: reconcile the migrator and create the locked accounts

```powershell
& "$bin\mysql.exe" -u root -p --table -e "source migrations/admin/S2_A_pre_migration_accounts.sql"
```

Check the output:

- **Migrator:** exactly `USAGE ON *.*`, `SET_USER_ID ON *.*`, and the 14 schema privileges. That means **no** `ALL PRIVILEGES`, DELETE, FILE, PROCESS, SUPER, SYSTEM_USER or GRANT OPTION, and no row for `college_complaints`.
- **The two definers and the CLI account:** USAGE only, with `account_locked = Y`.
- **Anonymous accounts:** `anonymous_accounts = 0`.

## Step 3: Read-only preflight as the migrator

```powershell
python migrations\run_migrations.py --preflight
```

Every line must report `[OK]`, specifically:

- the target database, the account, MySQL 8.0 and the collation;
- the protected database is invisible;
- **the grant allowlist passes**;
- the baseline matches: 10 / 5 / 15 / 102 / 202 / 155, with 200 assigned and 2 unassigned;
- before 005: the live `complaints_ibfk_1` (`student_id`) rules are NO ACTION/RESTRICT (the runner halts otherwise);
- "SET_USER_ID held: yes".

Any HALT stops the process. Never edit data to make the counts match.

## Step 4: Apply migrations 000–008

```powershell
python migrations\run_migrations.py --execute --confirm-target college_complaints_v2_dev --baseline-checkpoint "<path from Step 1>"
```

For each migration the runner:

1. verifies the ledger and checksum;
2. asserts the pre-condition;
3. writes a forensic checkpoint;
4. applies the migration;
5. records it in the ledger;
6. asserts the post-condition.

The final post-flight checks:

- 22 base tables (16 new) and preserved counts;
- 117 inactive users with no password;
- 200 legacy assignments with a NULL actor, and cache/ledger parity;
- **17 routines** owned by `cc_v2_dev_routine_definer` and **4 triggers** owned by `cc_v2_dev_trigger_definer`;
- all 4 views are INVOKER.

If a step fails, the runner prints both backup paths, labelled **full recovery** (the admin baseline) and **forensic only**. Use the Recovery section below. Only 008 may be retried in place.

If 008 fails with access denied on the root-defined v1 objects (R4), run the following as admin, then repeat Step 4:

```powershell
& "$bin\mysql.exe" -u root -p -e "source migrations/admin/S2_A2_optional_drop_root_defined_legacy_objects.sql"
```

## Step 5: Admin: least-privilege grants, and revoke SET_USER_ID

```powershell
& "$bin\mysql.exe" -u root -p --table -e "source migrations/admin/S2_B_post_migration_grants.sql"
```

Check the output:

- **Runtime account:** no schema-wide grant and **no INSERT or UPDATE** on `complaints`; EXECUTE on 10 procedures (including `update_complaint_details`), **not** including `issue_account_token_operator` or any `cc_*` helper.
- **CLI account:** EXECUTE only on `issue_account_token_operator` and `redeem_account_token`, plus column-limited `users` reads.
- **Migrator:** SET_USER_ID is gone.

## Step 6: Probes (they change nothing)

Run as the runtime account:

```powershell
& "$bin\mysql.exe" --force --table -u complaint_app_v2_dev -p --database=college_complaints_v2_dev -e "source migrations/admin/S2_C_runtime_negative_tests.sql"
```

Run as the migrator. Everything runs inside one transaction that is rolled back:

```powershell
& "$bin\mysql.exe" --force --table -u complaint_migrator_v2_dev -p --database=college_complaints_v2_dev -e "source migrations/admin/S2_D_integrity_tests_rolled_back.sql"
```

Key results:

- **T01:** error 1143 even with the session marker set to TRUE.
- **T06b:** direct detail UPDATE denied (R13).
- **T13:** direct INSERT denied.
- **T15:** operator issuance denied to Flask.
- **T22, T23, T26:** no submission or token issuance for another account.
- **T30:** still 202 complaints and 155 history rows.

## Step 6b: Decision acceptance tests R13–R16 (DATA-MODIFYING; bracketed by backup and restore)

`S2_E_decision_acceptance_tests.sql` activates six existing users with a **random, unusable** password hash, adds reviewer, admin and officer fixtures, submits three test complaints, and runs every R13–R16 scenario plus the revision 4 eligibility tests: 34 checks (E25–E29 cover inactive accounts and roles; E19b–E21b cover the officer's combined roles). The procedures commit, so the only way back is a restore. Run all four commands in order, and do not skip the restore.

1. Admin post-Stage-2 backup. It uses a new timestamped file and never overwrites anything:

   ```powershell
   $stamp = Get-Date -Format yyyyMMdd_HHmmss; $post = "backups\stage2\admin_post_stage2_$stamp.sql"; if (Test-Path $post) { throw "exists" }; & "$bin\mysqldump.exe" -u root -p --single-transaction --routines --triggers --events --no-tablespaces --set-gtid-purged=OFF --default-character-set=utf8mb4 --hex-blob "--result-file=$post" college_complaints_v2_dev; Get-Item $post
   ```

2. Run the tests as the migrator. Every `PASS` line must say PASS, and every `expect ERROR 1644` line must be followed by that error:

   ```powershell
   & "$bin\mysql.exe" --force --table -u complaint_migrator_v2_dev -p --database=college_complaints_v2_dev -e "source migrations/admin/S2_E_decision_acceptance_tests.sql"
   ```

3. Restore the post-Stage-2 state. This is destructive and limited to the dev sandbox; check the name:

   ```powershell
   & "$bin\mysql.exe" -u root -p -e "DROP DATABASE college_complaints_v2_dev; CREATE DATABASE college_complaints_v2_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
   ```

   ```powershell
   & "$bin\mysql.exe" -u root -p --default-character-set=utf8mb4 --database=college_complaints_v2_dev -e "source $post"
   ```

4. Continue with Step 7. It must report the pristine post-Stage-2 state: 202 complaints, 155 history rows, 0 active users, an empty officer singleton.

## Step 7: Final read-only confirmation

```powershell
python migrations\run_migrations.py --preflight
```

When nothing is pending, this re-runs the post-flight. It **halts if the migrator still holds SET_USER_ID**. Record the actual outputs of Steps 2–7 in a Stage 2 execution report.

## Step 8: Enable the development activation CLI (optional; only when needed)

1. As admin, interactively: `& "$bin\mysql.exe" -u root -p`, then run:

   ```sql
   ALTER USER 'cc_v2_dev_activation_cli'@'localhost' IDENTIFIED BY RANDOM PASSWORD ACCOUNT UNLOCK;
   ```

   MySQL displays the generated password **once**, on your console only.
2. Add `DB_ACTIVATION_USER=cc_v2_dev_activation_cli` and `DB_ACTIVATION_PASSWORD=<generated>` to `.env.development` yourself. Don't paste the password anywhere else.
3. Optional: run the three CLI-account probes at the end of `S2_C_runtime_negative_tests.sql`.
4. Activate accounts with `python cli_activation.py --email <address>` and `python cli_activation.py --redeem`. This modifies data, so it is a separate approved action.
5. When finished: `ALTER USER 'cc_v2_dev_activation_cli'@'localhost' ACCOUNT LOCK;`

## Stop conditions

Stop at the first HALT, `[X] MIGRATION FAILED`, unexpected probe result, or unexpected warning. Stage 3 does not start until Stage 2 is verified and approved.

## Recovery (admin only, full recovery = admin baseline)

1. Confirm the name is exactly `college_complaints_v2_dev`. **Never** run this against `college_complaints`.
2. Recreate the empty sandbox. This is destructive and limited to the dev sandbox:

   ```powershell
   & "$bin\mysql.exe" -u root -p -e "DROP DATABASE college_complaints_v2_dev; CREATE DATABASE college_complaints_v2_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
   ```

3. Restore the **admin baseline recovery backup**, not a forensic checkpoint:

   ```powershell
   & "$bin\mysql.exe" -u root -p --default-character-set=utf8mb4 --database=college_complaints_v2_dev -e "source backups/stage2/admin_pre_stage2_<stamp>.sql"
   ```

4. Run `python migrations\run_migrations.py --preflight` and expect the baseline report. Then continue from Step 2. S2_A is idempotent.

**Notes:**

- Account grants survive `DROP DATABASE`. If S2_B had already run, re-run it after a successful migration.
- Restoring into the existing database without the drop and create is not a valid recovery, because tables created later would survive.

## Not part of Stage 2 (Stage 3 backlog)

- The first SYSTEM_ADMIN bootstrap, then officer appointment. The officer must already be an active, VERIFIED staff member.
- Registration, staff-verification and membership-management procedures; the unauthenticated forgot-password flow.
- The Flask changes: `connect_db` guard and defaults, procedure calls with autocommit, the ownership check on complaint edits, CSRF, the Tabler UI.
