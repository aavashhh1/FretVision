"""Verifier construction. Selects exactly one mode — never a runtime fallback."""

from __future__ import annotations

import httpx

from app.auth.auth_server_verifier import AuthServerVerifier
from app.auth.jwks_verifier import JwksVerifier
from app.auth.signing_keys import PyJWKClientSigningKeyProvider
from app.auth.verifier import JWTVerifier
from app.settings import Settings


def build_verifier(settings: Settings, http_client: httpx.AsyncClient) -> JWTVerifier:
    """Build the configured verifier. Settings validation guarantees the required
    per-mode fields are present, so a missing value here is a programming error."""
    if settings.jwt_verification_mode == "jwks":
        assert settings.supabase_jwks_url is not None
        assert settings.jwt_issuer is not None
        assert settings.jwt_audience is not None
        provider = PyJWKClientSigningKeyProvider(
            settings.supabase_jwks_url,
            cache_ttl_seconds=settings.jwks_cache_ttl_seconds,
            http_timeout=settings.jwks_http_timeout,
        )
        return JwksVerifier(
            provider=provider,
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
            allowed_algorithms=settings.jwt_allowed_algorithms,
        )

    assert settings.supabase_url is not None
    assert settings.supabase_publishable_key is not None
    return AuthServerVerifier(
        base_url=settings.supabase_url,
        publishable_key=settings.supabase_publishable_key.get_secret_value(),
        http_client=http_client,
    )
