"""Environment-based configuration with hard safety guards.

Values come from the process environment, falling back to `.env.development` in the project
root. Secrets are never logged or rendered. The application refuses to start unless it targets
the development sandbox with the least-privilege runtime account.
"""
import os
from datetime import timedelta
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_ROOT / ".env.development"

REQUIRED_DATABASE = "college_complaints_v2_dev"
REQUIRED_DB_USER = "complaint_app_v2_dev"
PROTECTED_DATABASE = "college_complaints"
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}
HOSTED_SUFFIX = ".aivencloud.com"


class ConfigError(RuntimeError):
    pass


def _load_env_file():
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key.strip(), value)


class Config:
    """Resolved configuration. Construct via Config.from_environment()."""

    def __init__(self, **values):
        self.__dict__.update(values)

    @classmethod
    def from_environment(cls):
        _load_env_file()
        db_name = os.environ.get("DB_NAME", "")
        db_user = os.environ.get("DB_USER", "")
        db_host = os.environ.get("DB_HOST", "localhost")
        secret = os.environ.get("FLASK_SECRET_KEY", "")

        if db_name != REQUIRED_DATABASE:
            raise ConfigError(f"DB_NAME must be {REQUIRED_DATABASE}; refusing to start.")
        if db_user != REQUIRED_DB_USER:
            raise ConfigError(f"DB_USER must be {REQUIRED_DB_USER}; refusing to start.")
        ssl_ca_b64 = os.environ.get("DB_SSL_CA", "")
        if db_host not in LOCAL_HOSTS:
            # Hosted deployment: only an Aiven MySQL host, and only over verified TLS.
            if not db_host.endswith(HOSTED_SUFFIX):
                raise ConfigError(f"A non-local DB_HOST must end with {HOSTED_SUFFIX}; refusing to start.")
            if not ssl_ca_b64:
                raise ConfigError("DB_SSL_CA (base64 CA certificate) is required for a hosted database.")
        if not os.environ.get("DB_PASSWORD"):
            raise ConfigError("DB_PASSWORD is not set.")
        if len(secret) < 16 or secret == "local-demo-key":
            raise ConfigError("FLASK_SECRET_KEY must be set to a strong value (16+ characters).")

        secure_cookies = os.environ.get("SESSION_COOKIE_SECURE", "0") == "1"
        return cls(
            SECRET_KEY=secret,
            DB_HOST=db_host,
            DB_PORT=int(os.environ.get("DB_PORT", "3306")),
            DB_NAME=db_name,
            DB_USER=db_user,
            DB_PASSWORD=os.environ["DB_PASSWORD"],
            DB_SSL_CA_B64=ssl_ca_b64,
            TRUST_PROXY=os.environ.get("TRUST_PROXY", "0") == "1",
            SESSION_COOKIE_HTTPONLY=True,
            SESSION_COOKIE_SAMESITE="Lax",
            SESSION_COOKIE_SECURE=secure_cookies,
            SESSION_COOKIE_NAME="campuscare_session",
            PERMANENT_SESSION_LIFETIME=timedelta(minutes=int(os.environ.get("SESSION_IDLE_MINUTES", "30"))),
            MAX_CONTENT_LENGTH=256 * 1024,
            APP_BASE_URL=os.environ.get("APP_BASE_URL", "http://localhost:5000").rstrip("/"),
            LOGIN_MAX_ATTEMPTS=5,
            LOGIN_LOCKOUT_SECONDS=300,
        )

    def flask_mapping(self):
        """Settings handed to Flask (excludes DB credentials)."""
        keys = ("SECRET_KEY", "SESSION_COOKIE_HTTPONLY", "SESSION_COOKIE_SAMESITE", "SESSION_COOKIE_SECURE",
                "SESSION_COOKIE_NAME", "PERMANENT_SESSION_LIFETIME", "MAX_CONTENT_LENGTH")
        return {k: getattr(self, k) for k in keys}
