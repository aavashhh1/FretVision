"""auth_server verifier — legacy local-development compatibility only.

Validates the bearer against the local Supabase Auth ``/auth/v1/user`` endpoint using
the shared application ``httpx.AsyncClient`` and the publishable key. FastAPI never holds
the legacy HS256 secret and performs no local signature verification.
"""

from __future__ import annotations

from uuid import UUID

import httpx

from app.auth.models import VerifiedIdentity
from app.errors import AuthError


class AuthServerVerifier:
    def __init__(
        self, *, base_url: str, publishable_key: str, http_client: httpx.AsyncClient
    ) -> None:
        self._url = base_url.rstrip("/") + "/auth/v1/user"
        self._apikey = publishable_key
        self._client = http_client

    async def verify(self, token: str) -> VerifiedIdentity:
        try:
            response = await self._client.get(
                self._url,
                headers={"Authorization": f"Bearer {token}", "apikey": self._apikey},
            )
        except httpx.HTTPError as exc:
            raise AuthError("auth server unreachable") from exc

        if response.status_code != 200:
            raise AuthError("token rejected by auth server")

        try:
            data = response.json()
        except ValueError as exc:
            raise AuthError("invalid auth server response") from exc

        sub = data.get("id")
        if not isinstance(sub, str) or not sub.strip():
            raise AuthError("auth server response missing user id")
        try:
            sub_uuid = UUID(sub)
        except ValueError as exc:
            raise AuthError("auth server user id is not a valid UUID") from exc

        role = data.get("role")
        return VerifiedIdentity(sub=sub_uuid, role=role if isinstance(role, str) else None)
