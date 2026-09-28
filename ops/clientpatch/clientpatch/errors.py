"""Error types. Every failure the tool reports on purpose is a ClientPatchError,
so the CLI can print one clear line instead of a traceback."""


class ClientPatchError(Exception):
    """Base class for expected, user-facing failures."""


class BindingError(ClientPatchError):
    """A binding file is invalid or does not match a DBC."""


class LayoutError(ClientPatchError):
    """A DBC file does not match its binding (wrong client build?)."""


class DeltaError(ClientPatchError):
    """A delta file is invalid or cannot be applied."""


class BaseError(ClientPatchError):
    """The client base is unknown or differs from its registered fingerprint."""


class SqlSourceError(ClientPatchError):
    """A server SQL export is missing or malformed."""


class ConsistencyError(ClientPatchError):
    """Client data and server SQL disagree (a blocking rule failed)."""


class ToolError(ClientPatchError):
    """An external tool (mpqcli) is missing, has the wrong version, or failed."""
