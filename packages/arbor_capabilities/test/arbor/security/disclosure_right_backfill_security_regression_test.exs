defmodule Arbor.Security.DisclosureRightBackfillSecurityRegressionTest do
  @moduledoc """
  Security regression for the operator-signed backfill of the narrow
  disclosure-issue right (`mix arbor.agent.grant_disclosure`).

  Agents created before 2026-11-14 lack
  `arbor://security/disclose/<agent>/<human>`, so their Session cannot mint the
  one-turn disclosure capability and every authenticated turn on an external
  route is refused. The backfill is signed in the CLI with the operator's key
  file (`prepare_key_file_disclosure_right_grant/2`) and admitted by
  `submit_signed_disclosure_right_grant/2`.

  These tests pin the Security half: the right is bound to the human who
  signed it, never another human, and the path never admits a grant the
  signer could not make with its own grant authority. Agent ownership is
  checked above this library (arbor_agent's
  `owner_disclosure_right_security_regression_test.exs`).
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  setup do
    :ok = Security.TestBootstrap.start!()

    previous_flag =
      Application.get_env(:arbor_capabilities, :allow_local_human_identity, :__absent__)

    previous_oidc = Application.get_env(:arbor_capabilities, :oidc, :__absent__)
    Application.put_env(:arbor_capabilities, :allow_local_human_identity, true)
    Application.delete_env(:arbor_capabilities, :oidc)

    dir = private_dir!()

    {:ok, identity} = Identity.generate(name: "disclosure-right backfill agent")
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session
      )

    {:ok, authority} = Security.open_ephemeral_signing_authority(proof, identity.private_key)

    on_exit(fn ->
      _ = Security.close_signing_authority(authority)
      _ = Security.deregister_identity_fixture(identity.agent_id)
      restore_env(:allow_local_human_identity, previous_flag)
      restore_env(:oidc, previous_oidc)
      File.rm_rf!(dir)
    end)

    admin = human!(dir, "admin")
    other = human!(dir, "other")
    grant!(admin.principal, "arbor://security/grant/*")
    grant!(other.principal, "arbor://security/grant/*")

    %{agent_id: identity.agent_id, authority: authority, admin: admin, other: other, dir: dir}
  end

  test "security regression: the key-file grant binds the key's own human and admits that human's turns",
       ctx do
    assert {:ok, human, cap, proof} = prepare_disclosure(ctx.admin, ctx.agent_id)
    assert human == ctx.admin.principal
    assert {:ok, right} = Security.disclosure_issue_right_uri(ctx.agent_id, human)
    assert cap.resource_uri == right
    assert cap.principal_id == ctx.agent_id
    assert cap.delegation_depth == 0
    refute_secret(cap, ctx.admin.private_key)
    refute_secret(proof, ctx.admin.private_key)

    assert {:error, :capability_mutation_unauthorized} =
             Security.issue_disclosure_capability(disclosure_opts(ctx, human))

    assert {:ok, _granted} = Security.submit_signed_disclosure_right_grant(cap, proof)

    assert {:ok, disclosure} = Security.issue_disclosure_capability(disclosure_opts(ctx, human))
    assert :ok = Security.revoke(disclosure.id, actor_authority: ctx.authority)

    # The other human's turns are still refused on this agent.
    assert {:error, :capability_mutation_unauthorized} =
             Security.issue_disclosure_capability(disclosure_opts(ctx, ctx.other.principal))
  end

  test "security regression: a grant naming another human is refused, even for an administrator",
       ctx do
    {:ok, own_right} = Security.disclosure_issue_right_uri(ctx.agent_id, ctx.admin.principal)
    {:ok, other_right} = Security.disclosure_issue_right_uri(ctx.agent_id, ctx.other.principal)

    # Signed by the admin, naming the other human.
    {:ok, foreign, foreign_proof} =
      prepare_generic(ctx.admin, principal: ctx.agent_id, resource: other_right)

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Security.submit_signed_disclosure_right_grant(foreign, foreign_proof)

    # A genuine grant rebound after signing.
    {:ok, _human, cap, proof} = prepare_disclosure(ctx.admin, ctx.agent_id)

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Security.submit_signed_disclosure_right_grant(
               %{cap | resource_uri: other_right},
               proof
             )

    # The right bound to the admin, signed by the other human.
    {:ok, swapped, swapped_proof} =
      prepare_generic(ctx.other, principal: ctx.agent_id, resource: own_right)

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Security.submit_signed_disclosure_right_grant(swapped, swapped_proof)

    # Scoped to a principal, a session or a task, or anything that is not the
    # disclosure right at all.
    for extra <- [
          [principal_scope: ctx.admin.principal],
          [session_id: "session-backfill"],
          [task_id: "task-backfill"]
        ] do
      {:ok, scoped, scoped_proof} =
        prepare_generic(ctx.admin, [principal: ctx.agent_id, resource: own_right] ++ extra)

      assert {:error, :disclosure_right_not_bound_to_signer} =
               Security.submit_signed_disclosure_right_grant(scoped, scoped_proof),
             "#{inspect(extra)} must not pass as the narrow right"
    end

    {:ok, wide, wide_proof} =
      prepare_generic(ctx.admin,
        principal: ctx.agent_id,
        resource: "arbor://security/grant/#{ctx.agent_id}"
      )

    assert {:error, :disclosure_right_not_bound_to_signer} =
             Security.submit_signed_disclosure_right_grant(wide, wide_proof)

    for resource <- [own_right, other_right, "arbor://security/grant/#{ctx.agent_id}"] do
      assert holding(ctx.agent_id, resource) == []
    end
  end

  test "security regression: the backfill never admits what the signer could not grant directly",
       ctx do
    bare = human!(ctx.dir, "bare")
    {:ok, _human, cap, proof} = prepare_disclosure(bare, ctx.agent_id)

    assert {:error, :capability_mutation_unauthorized} =
             Security.submit_signed_disclosure_right_grant(cap, proof)

    assert holding(ctx.agent_id, cap.resource_uri) == []
  end

  test "security regression: a forged or replayed backfill proof is refused", ctx do
    {:ok, _human, cap, proof} = prepare_disclosure(ctx.admin, ctx.agent_id)
    forged = resign(proof, ctx.other.private_key)

    assert {:error, _reason} = Security.submit_signed_disclosure_right_grant(cap, forged)
    assert holding(ctx.agent_id, cap.resource_uri) == []

    {:ok, _human, cap, proof} = prepare_disclosure(ctx.admin, ctx.agent_id)
    assert {:ok, granted} = Security.submit_signed_disclosure_right_grant(cap, proof)
    assert :ok = Security.revoke_fixture(granted.id)

    assert {:error, _reason} = Security.submit_signed_disclosure_right_grant(cap, proof)
    assert holding(ctx.agent_id, cap.resource_uri) == []
  end

  test "an agent principal's key file cannot bind a disclosure right", ctx do
    {:ok, agent} = Identity.generate(name: "agent key file")
    path = Path.join(ctx.dir, "agent.key")
    {:ok, ^path} = Security.write_key_file(path, agent)

    assert {:error, :invalid_binding_field} =
             with_key(path, &Security.prepare_key_file_disclosure_right_grant(&1, ctx.agent_id))

    assert {:error, :capability_mutation_unauthorized} =
             Security.prepare_key_file_disclosure_right_grant(path, ctx.agent_id)
  end

  # -- helpers -----------------------------------------------------------------

  defp disclosure_opts(ctx, human) do
    [
      principal_id: ctx.agent_id,
      session_id: "session-disclosure-right-backfill",
      task_id: "turn-disclosure-right-backfill",
      principal_scope: human,
      destination: "opencode.ai",
      provider: "opencode_zen",
      runtime: "arbor",
      model: "test-model-free",
      actor_authority: ctx.authority
    ]
  end

  defp prepare_disclosure(human, agent_id),
    do: with_key(human.key_path, &Security.prepare_key_file_disclosure_right_grant(&1, agent_id))

  defp prepare_generic(human, opts),
    do: with_key(human.key_path, &Security.prepare_key_file_capability_grant(&1, opts))

  defp with_key(path, fun) do
    {:ok, io_device} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

    try do
      fun.(io_device)
    after
      :file.close(io_device)
    end
  end

  defp resign(%SignedRequest{} = request, private_key) do
    message = SignedRequest.signing_payload(request)
    %{request | signature: :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])}
  end

  defp human!(dir, tag) do
    claims = [user: "#{tag}-#{System.unique_integer([:positive])}", host: "backfill.test"]
    principal = Security.local_human_principal_id(claims)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_path = Path.join(dir, "#{tag}-#{System.unique_integer([:positive])}.key")

    {:ok, ^key_path} =
      Security.write_key_file(key_path, %{agent_id: principal, private_key: private_key})

    {:ok, payload} = Security.local_human_registration_request_payload(principal, public_key)
    {:ok, proof} = SignedRequest.sign(payload, principal, private_key)
    {:ok, _identity, :created} = Security.register_local_human_identity(public_key, proof, claims)

    %{principal: principal, private_key: private_key, key_path: key_path}
  end

  defp grant!(principal, resource) do
    {:ok, cap} = Security.grant_fixture(principal: principal, resource: resource)
    on_exit(fn -> _ = Security.revoke_fixture(cap.id) end)
    cap
  end

  defp holding(principal, resource) do
    {:ok, caps} = Security.list_capabilities(principal)
    Enum.filter(caps, &(&1.resource_uri == resource))
  end

  defp refute_secret(term, private_key) do
    assert :binary.match(:erlang.term_to_binary(term), private_key) == :nomatch
  end

  defp private_dir! do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "disclosure-right-backfill-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(key, :__absent__), do: Application.delete_env(:arbor_capabilities, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_capabilities, key, value)
end
