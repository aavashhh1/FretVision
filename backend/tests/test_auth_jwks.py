"""JWKS verifier unit tests (fake provider — no network)."""

from __future__ import annotations

from collections.abc import Callable
from uuid import UUID

import pytest
from app.auth.jwks_verifier import JwksVerifier
from app.errors import AuthError
from cryptography.hazmat.primitives.asymmetric import ec

from tests.conftest import (
    AUDIENCE,
    ISSUER,
    KID,
    FakeSigningKeyProvider,
    raw_token,
)

pytestmark = pytest.mark.asyncio

KeyPair = tuple[ec.EllipticCurvePrivateKey, ec.EllipticCurvePublicKey]


def _verifier(public_key: ec.EllipticCurvePublicKey, *, raise_error: bool = False) -> JwksVerifier:
    return JwksVerifier(
        provider=FakeSigningKeyProvider(public_key, raise_error=raise_error),
        issuer=ISSUER,
        audience=AUDIENCE,
        allowed_algorithms=frozenset({"ES256"}),
    )


async def test_valid_token(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    sub = "11111111-1111-1111-1111-111111111111"
    identity = await _verifier(public_key).verify(make_token(sub=sub))
    assert identity.sub == UUID(sub)
    assert identity.role == "authenticated"


async def test_invalid_signature(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    other_key = ec.generate_private_key(ec.SECP256R1())
    token = make_token(key=other_key)
    with pytest.raises(AuthError, match="invalid signature"):
        await _verifier(public_key).verify(token)


async def test_expired_token(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError, match="expired"):
        await _verifier(public_key).verify(make_token(exp_delta=-10))


async def test_wrong_issuer(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError, match="issuer"):
        await _verifier(public_key).verify(make_token(iss="https://evil.test"))


async def test_wrong_audience(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError, match="audience"):
        await _verifier(public_key).verify(make_token(aud="someone-else"))


async def test_missing_sub(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError):
        await _verifier(public_key).verify(make_token(include_sub=False))


async def test_invalid_sub_not_uuid(
    signing_keypair: KeyPair, make_token: Callable[..., str]
) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError, match="not a valid UUID"):
        await _verifier(public_key).verify(make_token(sub="not-a-uuid"))


async def test_unknown_kid(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError, match="unknown signing key"):
        await _verifier(public_key, raise_error=True).verify(make_token())


async def test_missing_alg_header(signing_keypair: KeyPair) -> None:
    _, public_key = signing_keypair
    token = raw_token({"kid": KID}, {"sub": "x"})
    with pytest.raises(AuthError, match="missing alg"):
        await _verifier(public_key).verify(token)


async def test_missing_kid_header(signing_keypair: KeyPair, make_token: Callable[..., str]) -> None:
    _, public_key = signing_keypair
    with pytest.raises(AuthError, match="missing kid"):
        await _verifier(public_key).verify(make_token(kid=None))


async def test_disallowed_algorithm(signing_keypair: KeyPair) -> None:
    _, public_key = signing_keypair
    import jwt

    token = jwt.encode({"sub": "x"}, "x" * 32, algorithm="HS256", headers={"kid": KID})
    with pytest.raises(AuthError, match="algorithm not allowed"):
        await _verifier(public_key).verify(token)
