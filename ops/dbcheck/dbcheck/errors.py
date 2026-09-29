"""Error types. Every failure the operator can cause has its own message."""


class DbCheckError(Exception):
    """Base class; the CLI prints the message and exits with code 2."""


class ConfigError(DbCheckError):
    """A binding, rule or expected file is malformed."""


class SchemaError(DbCheckError):
    """The database does not match the binding (missing table or column)."""


class RunnerError(DbCheckError):
    """The database client failed or returned something unparseable."""
