defmodule Arbor.Security.IdentityVerifiedPassthroughTest do
  @moduledoc """
  **Security regression guard (gateway pre-verified lifecycle path, 2026-06-28).**

  The Gateway's `SignedRequestAuth` verifies an external client's Ed25519
  per-request signature — binding it to the principal AND consuming the
  single-use nonce — BEFORE the capability-gated operation runs. The downstream
  capability check must NOT re-verify that signature: with `identity_verification`
  config-ON (dev/prod), re-verifying either demands a signed_request the caller
  no longer carries (`:missing_signed_request`) or replays the spent nonce
  (`:replayed_nonce`).

  The fix: callers that have already verified upstream pass
  `identity_verified: true`, and `Arbor.Security.authorize/4`'s
  `build_auth_context` marks the context verified so `AuthDecision` skips
  re-verification (the `%AuthContext{identity_verified: true}` short-circuit).

  This guards that opt end-to-end through the facade. Pre-fix, `build_auth_context`
  ignored `identity_verified`, so the second assertion would still see
  `:missing_signed_request` and fail. Surfaced live by the TUI `/new` command,
  whose `POST /api/chat/agents` rejected authenticated requests until the
  signed-request proof was threaded into `Arbor.Agent.authorize_create/3`.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security

  setup do
    prev = %{
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement)
    }

    # Isolate identity verification as the only variable: identity check
    # permissive (strict off), no signing/reflex/uri gates in the way.
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    on_exit(fn ->
      restore(:strict_identity_mode, prev.strict)
      restore(:capability_signing_required, prev.signing)
      restore(:reflex_checking_enabled, prev.reflex)
      restore(:uri_registry_enforcement, prev.uri)
    end)

    hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    principal = "agent_" <> hex
    uri = "arbor://historian/query"

    {:ok, _cap} = Security.grant(principal: principal, resource: uri)

    {:ok, principal: principal, uri: uri}
  end

  test "security regression: identity_verified:true lets a pre-verified caller skip " <>
         "re-verification instead of being rejected as :missing_signed_request",
       %{principal: principal, uri: uri} do
    # With identity verification FORCED on and no signed_request, the gate fires —
    # this is exactly the state the gateway lifecycle endpoints hit (config-ON in
    # dev/prod) once a capability check runs without the verified proof.
    assert {:error, :missing_signed_request} =
             Security.authorize(principal, uri, :query, verify_identity: true)

    # With identity already verified upstream, the verification step is skipped.
    # The result must NOT be :missing_signed_request — pre-fix the opt was ignored
    # by build_auth_context and this stayed :missing_signed_request.
    result =
      Security.authorize(principal, uri, :query,
        verify_identity: true,
        identity_verified: true
      )

    refute match?({:error, :missing_signed_request}, result),
           "identity_verified: true must skip signed-request re-verification; " <>
             "got #{inspect(result)}"

    # It also must not have replayed a nonce (the other failure mode of
    # re-verifying an already-verified request).
    refute match?({:error, :replayed_nonce}, result),
           "identity_verified: true must not re-consume the single-use nonce; " <>
             "got #{inspect(result)}"
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:arbor_security, key, value)
end
