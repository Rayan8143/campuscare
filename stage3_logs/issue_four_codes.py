"""Phase 1: unlock the activation CLI account, issue four 60-minute codes into protected
.activation-code files, then ALWAYS relock it (with a fresh random password that is discarded).

* Root password: typed by the operator at each mysql prompt (twice). Never seen by this script.
* Generated CLI password: captured from mysql stdout, kept only in memory, passed to
  cli_activation.py through its environment; never printed, logged or written to disk.
* Raw codes: written only by cli_activation.py into ACL-restricted files; never printed.
Run AFTER the fresh backup:  python stage3_logs/issue_four_codes.py
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
ACCOUNT = "'cc_v2_dev_activation_cli'@'localhost'"
TARGETS = [  # (user_id, email, file)
    (114, "vikram.lab@example.edu", "activation_codes/vikram_114.activation-code"),
    (115, "neha.lab@example.edu", "activation_codes/neha_115.activation-code"),
    (108, "arjun.maintenance@example.edu", "activation_codes/arjun_108.activation-code"),
    (109, "priya.maintenance@example.edu", "activation_codes/priya_109.activation-code"),
]


def root_mysql(sql, capture):
    return subprocess.run([MYSQL, "-u", "root", "-p", "--batch", "--skip-column-names", "-e", sql],
                          stdout=subprocess.PIPE if capture else subprocess.DEVNULL, text=True)


def main():
    os.chdir(ROOT)
    (ROOT / "activation_codes").mkdir(exist_ok=True)
    for _, _, f in TARGETS:
        if Path(f).exists():
            sys.exit(f"STOP: {f} already exists; nothing was changed.")

    print("[1/3] Unlock activation CLI account (enter ROOT password)")
    r = root_mysql(f"ALTER USER {ACCOUNT} IDENTIFIED BY RANDOM PASSWORD ACCOUNT UNLOCK;", capture=True)
    parts = r.stdout.strip().split("\t") if r.returncode == 0 else []
    password = parts[2] if len(parts) >= 3 and parts[0] == "cc_v2_dev_activation_cli" else None
    del r
    results = []
    try:
        if not password:
            print("ERROR: unlock failed or unexpected output; relocking.")
            return 1
        env = dict(os.environ, DB_ACTIVATION_USER="cc_v2_dev_activation_cli", DB_ACTIVATION_PASSWORD=password)
        print("[2/3] Issuing four 60-minute codes")
        for uid, email, f in TARGETS:
            p = subprocess.run([sys.executable, "cli_activation.py", "--email", email, "--ttl-minutes", "60",
                                "--code-file", f], env=env, capture_output=True, text=True)
            ok = p.returncode == 0 and Path(f).exists()
            results.append((uid, f, ok))
            msg = (p.stderr or "").strip().splitlines()
            print(f"  user {uid}: {'issued -> ' + f if ok else 'FAILED: ' + (msg[-1] if msg else 'unknown')}")
        del env
    finally:
        password = None
        print("[3/3] Relock activation CLI account with a discarded random password (enter ROOT password)")
        lock = root_mysql(f"ALTER USER {ACCOUNT} IDENTIFIED BY RANDOM PASSWORD ACCOUNT LOCK; "
                          "SELECT 'LOCKED_CHECK', account_locked FROM mysql.user WHERE user = 'cc_v2_dev_activation_cli';",
                          capture=True)
        state = [ln for ln in lock.stdout.splitlines() if ln.startswith("LOCKED_CHECK")]
        print(f"  account_locked = {state[0].split(chr(9))[1] if state else 'UNKNOWN - CHECK MANUALLY'}")
        del lock
    return 0 if results and all(ok for _, _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
