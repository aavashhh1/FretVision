"""Settings validation: per-mode requirements, guards, and secret hygiene."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from tests.conftest import build_settings


def test_auth_server_minimal_valid() -> None:
    settings = build_settings()
    assert settings.jwt_verification_mode == "auth_server"
    assert settings.db_connection_mode == "direct"


def test_jwks_minimal_valid() -> None:
    settings = build_settings(
        jwt_verification_mode="jwks",
        supabase_url=None,
        supabase_publishable_key=None,
        supabase_jwks_url="https://issuer.test/jwks.json",
        jwt_issuer="https://issuer.test",
        jwt_audience="authenticated",
        jwt_allowed_algorithms="ES256,RS256",
    )
    assert settings.jwt_allowed_algorithms == frozenset({"ES256", "RS256"})


def test_jwks_missing_issuer_rejected() -> None:
    with pytest.raises(ValidationError, match="jwks mode requires"):
        build_settings(
            jwt_verification_mode="jwks",
            supabase_url=None,
            supabase_publishable_key=None,
            supabase_jwks_url="https://issuer.test/jwks.json",
            jwt_audience="authenticated",
            jwt_allowed_algorithms="ES256",
        )


def test_auth_server_forbidden_in_production_without_guard() -> None:
    with pytest.raises(ValidationError, match="not permitted in production"):
        build_settings(app_env="production")


def test_auth_server_allowed_in_production_with_guard() -> None:
    settings = build_settings(app_env="production", allow_auth_server_in_prod=True)
    assert settings.is_production


def test_invalid_connection_mode_rejected() -> None:
    with pytest.raises(ValidationError, match="direct.*session"):
        build_settings(db_connection_mode="cluster")


def test_transaction_connection_mode_rejected() -> None:
    with pytest.raises(ValidationError, match="transaction.*forbidden"):
        build_settings(db_connection_mode="transaction")


def test_transaction_pooler_port_rejected() -> None:
    with pytest.raises(ValidationError, match="transaction pooler"):
        build_settings(
            database_url="postgresql://user:pw@aws-0-region.pooler.supabase.com:6543/postgres"
        )


@pytest.mark.parametrize("value", ["HS256", "ES256,HS384", "", "ES256,ES256", "FOO"])
def test_bad_algorithm_values_rejected(value: str) -> None:
    with pytest.raises(ValidationError):
        build_settings(
            jwt_verification_mode="jwks",
            supabase_url=None,
            supabase_publishable_key=None,
            supabase_jwks_url="https://issuer.test/jwks.json",
            jwt_issuer="https://issuer.test",
            jwt_audience="authenticated",
            jwt_allowed_algorithms=value,
        )


def test_placeholder_sentinel_rejected() -> None:
    with pytest.raises(ValidationError, match="deployment-blocking placeholder"):
        build_settings(
            jwt_verification_mode="jwks",
            supabase_url=None,
            supabase_publishable_key=None,
            supabase_jwks_url="https://issuer.test/jwks.json",
            jwt_issuer="VERIFY_U5_ISSUER",
            jwt_audience="authenticated",
            jwt_allowed_algorithms="ES256",
        )


def test_secrets_excluded_from_repr() -> None:
    settings = build_settings()
    rendered = repr(settings) + str(settings)
    assert "supersecretpassword" not in rendered
    assert "pk_test_publishable" not in rendered
