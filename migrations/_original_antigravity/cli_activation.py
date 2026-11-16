"""
CampusCare 2.0 - Local Development Account Activation Helper
Usage:
  python cli_activation.py --email <user_email>
  python cli_activation.py --list-pending
  python cli_activation.py --demo-links

Note: Strictly for local development & demonstration evaluation.
Never logs password hashes. Raw tokens are generated on demand and stored as SHA-256 hashes.
"""

import os
import sys
import argparse
import secrets
import hashlib
import datetime
import mysql.connector

def get_db():
    # Connect using development config
    password = os.getenv("DB_PASSWORD", "")
    if not password:
        raise RuntimeError("DB_PASSWORD environment variable or .env.development entry is required.")
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"),
        user=os.getenv("DB_USER", "complaint_app_v2_dev"),
        password=password,
        database=os.getenv("DB_NAME", "college_complaints_v2_dev")
    )

def list_pending():
    db = get_db()
    cur = db.cursor(dictionary=True)
    cur.execute("""
        SELECT u.user_id, u.email, u.full_name, r.role_name
        FROM users u
        LEFT JOIN user_roles ur ON u.user_id = ur.user_id AND ur.is_active = TRUE
        LEFT JOIN roles r ON ur.role_id = r.role_id
        WHERE u.is_active = FALSE
        ORDER BY u.user_id
    """)
    rows = cur.fetchall()
    print(f"\n--- Inactive Accounts Awaiting Activation ({len(rows)}) ---")
    for r in rows:
        print(f"  [ID: {r['user_id']:3d}] {r['email']:<32} | {r['full_name']:<25} | Role: {r['role_name'] or 'N/A'}")
    cur.close()
    db.close()

def generate_link_for_email(email):
    db = get_db()
    cur = db.cursor(dictionary=True)
    cur.execute("SELECT user_id, full_name, email, is_active FROM users WHERE email = %s", (email,))
    user = cur.fetchone()
    if not user:
        print(f"ERROR: No user found with email '{email}'.")
        cur.close()
        db.close()
        return

    if user["is_active"]:
        print(f"NOTICE: User '{email}' is already active. Generating password reset token instead.")

    # Generate fresh raw token
    raw_token = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    expires_at = datetime.datetime.now() + datetime.timedelta(hours=48)

    # Invalidate old unused tokens
    cur.execute("UPDATE account_activations SET is_used = TRUE WHERE user_id = %s AND is_used = FALSE", (user["user_id"],))

    # Insert fresh token hash
    cur.execute("""
        INSERT INTO account_activations (user_id, token_hash, expires_at, is_used)
        VALUES (%s, %s, %s, FALSE)
    """, (user["user_id"], token_hash, expires_at))

    db.commit()
    cur.close()
    db.close()

    activation_url = f"http://localhost:5000/activate?token={raw_token}"
    print("\n--- Account Activation Link Generated ---")
    print(f"  User:      {user['full_name']} ({user['email']})")
    print(f"  Expires:   {expires_at.strftime('%Y-%m-%d %H:%M:%S')} (48 hours)")
    print(f"  Local URL: {activation_url}")
    print("------------------------------------------\n")

def demo_links():
    # Helper to generate links for key evaluation personas
    demo_emails = [
        "student001@example.edu",
        "student002@example.edu",
        "maintenance@example.edu",
        "it_support@example.edu"
    ]
    print("\n--- Generating Local Activation Links for Key Demo Personas ---")
    for em in demo_emails:
        generate_link_for_email(em)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CampusCare 2.0 Account Activation CLI")
    parser.add_argument("--email", type=str, help="Generate activation link for specific user email")
    parser.add_argument("--list-pending", action="store_true", help="List all inactive accounts pending activation")
    parser.add_argument("--demo-links", action="store_true", help="Generate activation links for sample demonstration accounts")
    args = parser.parse_args()

    # Load local .env.development if present
    env_file = os.path.join(os.path.dirname(__file__), ".env.development")
    if os.path.exists(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip())

    if args.email:
        generate_link_for_email(args.email)
    elif args.list_pending:
        list_pending()
    elif args.demo_links:
        demo_links()
    else:
        parser.print_help()
