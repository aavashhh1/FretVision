"""Typed application settings and startup configuration validation.

Secrets (``DATABASE_URL``, keys) are stored as :class:`~pydantic.SecretStr` so they
are excluded from ``repr``/logging. Configuration is validated eagerly at construction
so a misconfigured process fails fast at startup rather than at first request.
"""

from __future__ import annotations

from typing import Literal
from urllib.parse import urlsplit

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

JwtVerificationMode = Literal["jwks", "auth_server"]
DbConnectionMode = Literal["direct", "session"]

# Only asymmetric algorithms are permitted. Symmetric (HS*) is rejected on purpose:
# FastAPI never holds the legacy shared secret.
SUPPORTED_ASYMMETRIC_ALGORITHMS: frozenset[str] = frozenset(
    {
        "RS256",
        "RS384",
        "RS512",
        "ES256",
        "ES384",
        "ES512",
        "PS256",
        "PS384",
        "PS512",
        "EdDSA",
    }
)

# Supabase transaction-pooler port. asyncpg uses prepared statements, which are
# incompatible with transaction pooling, so a DSN on this port is rejected.
SUPABASE_TRANSACTION_POOLER_PORT = 6543

# Deployment-blocking placeholder markers left in the hosted template until the
# corresponding unresolved items (U5 JWKS issuer/audience, U6 connection mode) are
# verified against first-party sources.
_PLACEHOLDER_MARKERS = ("VERIFY_", "REPLACE_")


def _looks_like_placeholder(value: str | None) -> bool:
    return value is not None and value.strip().startswith(_PLACEHOLDER_MARKERS)


class Settings(BaseSettings):
    """Runtime configuration loaded from environment / ``.env``."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ----- Application -----
    app_env: str = "local"
    log_level: str = "INFO"

    # ----- Database -----
    database_url: SecretStr
    db_connection_mode: str
    db_application_name: str = "fretvision-backend"
    db_pool_min_size: int = Field(default=0, ge=0)
    db_pool_max_size: int = Field(default=10, ge=1)
    db_command_timeout: float = Field(default=30.0, gt=0)
    db_connect_timeout: float = Field(default=10.0, gt=0)

    # ----- Commands -----
    # Expiry metadata only. Deletion/reuse policy remains unresolved as U12.
    idempotency_ttl_seconds: int = Field(default=86400, ge=60, le=2592000)

    # ----- JWT verification -----
    jwt_verification_mode: JwtVerificationMode
    allow_auth_server_in_prod: bool = False

    # auth_server mode
    supabase_url: str | None = None
    supabase_publishable_key: SecretStr | None = None

    # jwks mode
    supabase_jwks_url: str | None = None
    jwt_issuer: str | None = None
    jwt_audience: str | None = None
    jwt_allowed_algorithms: frozenset[str] = frozenset()
    jwks_cache_ttl_seconds: int = Field(default=300, ge=0)
    jwks_http_timeout: float = Field(default=5.0, gt=0)

    # ----- Optional -----
    supabase_secret_key: SecretStr | None = None
    test_database_url: SecretStr | None = None

    @property
    def is_production(self) -> bool:
        return self.app_env.strip().lower() == "production"

    @field_validator("jwt_allowed_algorithms", mode="before")
    @classmethod
    def _parse_algorithms(cls, value: object) -> frozenset[str]:
        """Parse a comma-separated list into a validated asymmetric-algorithm set."""
        if value is None or value == "":
            return frozenset()
        if isinstance(value, str):
            tokens = [token.strip() for token in value.split(",") if token.strip()]
        elif isinstance(value, (list, tuple, set, frozenset)):
            tokens = [str(token).strip() for token in value if str(token).strip()]
        else:
            raise ValueError("JWT_ALLOWED_ALGORITHMS must be a comma-separated string")

        if not tokens:
            return frozenset()

        seen: set[str] = set()
        for token in tokens:
            if token in seen:
                raise ValueError(f"duplicate algorithm in JWT_ALLOWED_ALGORITHMS: {token}")
            seen.add(token)
            if token not in SUPPORTED_ASYMMETRIC_ALGORITHMS:
                raise ValueError(
                    f"unsupported or non-asymmetric algorithm {token!r}; "
                    f"allowed: {sorted(SUPPORTED_ASYMMETRIC_ALGORITHMS)}"
                )
        return frozenset(seen)

    @model_validator(mode="after")
    def _validate_configuration(self) -> Settings:
        self._reject_placeholders()
        self._validate_connection_mode()
        self._reject_transaction_pooler_dsn()
        self._validate_jwt_mode()
        return self

    def _reject_placeholders(self) -> None:
        checks: dict[str, str | None] = {
            "DATABASE_URL": self.database_url.get_secret_value(),
            "DB_CONNECTION_MODE": self.db_connection_mode,
            "JWT_ISSUER": self.jwt_issuer,
            "JWT_AUDIENCE": self.jwt_audience,
        }
        offenders = [name for name, value in checks.items() if _looks_like_placeholder(value)]
        if offenders:
            raise ValueError(
                "deployment-blocking placeholder value(s) present for "
                f"{', '.join(sorted(offenders))}; resolve U5/U6 and set real values"
            )

    def _validate_connection_mode(self) -> None:
        mode = self.db_connection_mode.strip().lower()
        if mode == "transaction":
            raise ValueError(
                "DB_CONNECTION_MODE=transaction is forbidden (asyncpg prepared "
                "statements are incompatible with transaction pooling); use "
                "'direct' or 'session'"
            )
        if mode not in ("direct", "session"):
            raise ValueError(
                f"DB_CONNECTION_MODE must be 'direct' or 'session', got {self.db_connection_mode!r}"
            )
        # Normalize.
        object.__setattr__(self, "db_connection_mode", mode)

    def _reject_transaction_pooler_dsn(self) -> None:
        dsn = self.database_url.get_secret_value()
        try:
            port = urlsplit(dsn).port
        except ValueError:
            port = None
        if port == SUPABASE_TRANSACTION_POOLER_PORT:
            raise ValueError(
                f"DATABASE_URL targets port {SUPABASE_TRANSACTION_POOLER_PORT}, which is the "
                "Supabase transaction pooler; use a direct connection or Supavisor session mode"
            )

    def _validate_jwt_mode(self) -> None:
        if self.jwt_verification_mode == "jwks":
            missing = [
                name
                for name, value in (
                    ("SUPABASE_JWKS_URL", self.supabase_jwks_url),
                    ("JWT_ISSUER", self.jwt_issuer),
                    ("JWT_AUDIENCE", self.jwt_audience),
                )
                if not value
            ]
            if not self.jwt_allowed_algorithms:
                missing.append("JWT_ALLOWED_ALGORITHMS")
            if missing:
                raise ValueError(
                    f"jwks mode requires: {', '.join(missing)}"
                )
        else:  # auth_server
            missing = [
                name
                for name, value in (
                    ("SUPABASE_URL", self.supabase_url),
                    ("SUPABASE_PUBLISHABLE_KEY", self.supabase_publishable_key),
                )
                if not value
            ]
            if missing:
                raise ValueError(f"auth_server mode requires: {', '.join(missing)}")
            if self.is_production and not self.allow_auth_server_in_prod:
                raise ValueError(
                    "auth_server mode is not permitted in production unless "
                    "ALLOW_AUTH_SERVER_IN_PROD=true"
                )
