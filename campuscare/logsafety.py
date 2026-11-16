"""Log redaction for secrets that may arrive in a URL despite the form-only activation flow
(for example a pasted CLI link). The Flask app never reads a code from the URL, but the
web server's access log records the request line before any view runs, so it is scrubbed here."""
import logging
import re

_SECRET_QUERY = re.compile(r"(?i)((?:^|[?&])(?:token|code|password|password2)=)[^&\s\"]*")
_ACTIVATE_QUERY = re.compile(r"(/activate)\?[^\s\"]*")


def redact(text):
    text = _ACTIVATE_QUERY.sub(r"\1?[REDACTED]", text)
    return _SECRET_QUERY.sub(r"\1[REDACTED]", text)


class RedactSecretsFilter(logging.Filter):
    def filter(self, record):
        if isinstance(record.msg, str):
            record.msg = redact(record.msg)
        if record.args:
            args = record.args if isinstance(record.args, tuple) else (record.args,)
            record.args = tuple(redact(a) if isinstance(a, str) else a for a in args)
        return True


def install():
    flt = RedactSecretsFilter()
    for name in ("werkzeug", "campuscare", "campuscare.db", ""):
        logger = logging.getLogger(name)
        if not any(isinstance(f, RedactSecretsFilter) for f in logger.filters):
            logger.addFilter(flt)
    for handler in logging.getLogger().handlers:
        if not any(isinstance(f, RedactSecretsFilter) for f in handler.filters):
            handler.addFilter(flt)
