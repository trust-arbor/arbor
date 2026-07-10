defmodule Arbor.Scheduler.RunIdentity do
  @moduledoc """
  Per-pipeline-run ephemeral identity + capability lifecycle.

  Phase 5 of the scheduler-privesc redesign. For each pipeline run that
  has a verified signed attestation, this module mints a fresh
  Ed25519 keypair, registers it in `Identity.Registry`, grants the
  declared capabilities to that ephemeral principal, and returns a
  signer the orchestrator can use. After the run completes (success
  or failure), the caller calls `revoke/1` to explicitly revoke each
  granted cap and deregister the identity.

  ## Why a per-run identity

  Capability lifecycle is bound to the principal: caps die naturally
  with the identity. Per-run identities give us:

    - **Bounded blast radius**: a compromised cap from run N cannot be
      replayed in run N+1 because the principal it was granted to
      no longer exists.
    - **Clean audit trail**: every signed_request the orchestrator
      processes is attributable to a specific run, not just to "the
      scheduler."
    - **No cross-run cap bleed**: two pipelines running concurrently
      can't see each other's caps even if they declared overlapping
      resource URIs.

  The cost is one Ed25519 keypair generation per run (~µs) and a
  registry write+delete pair — negligible compared to pipeline runtime.

  ## Trust chain (recap)

  ```
  operator enrolls issuer X with envelope Y         (Phase 2)
       │
       ▼
  issuer X signs caps.json declaring caps {Z₁, Z₂}  (Phase 4 sign_caps)
       │
       ▼
  CapsFile.load verifies the complete attestation     (Phase 5)
       │
       ▼
  RunIdentity.mint creates ephemeral identity E,
       grants {Z₁, Z₂} to E, returns signer-for-E    (this module)
       │
       ▼
  Orchestrator runs the pipeline as E, action layer
       sees E's caps include Z₁ and Z₂, file_write
       succeeds without approval gate
  ```

  Failure modes during mint return `{:error, reason}`; `revoke/1` is
  best-effort and never raises (it must run in an `after` clause).
  """

  require Logger

  alias Arbor.Contracts.Security.Identity, as: IdentityStruct
  alias Arbor.Scheduler.CapsFile
  alias Arbor.Scheduler.CapsFile.Attestation
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry

  # Every pipeline run needs orchestrator/execute to traverse graph nodes.
  # This is lobby authority only. Resource handlers MUST independently require
  # canonical fs, shell, and action capabilities; this grant cannot substitute
  # for those checks and must never be expanded into broad resource grants.
  @orchestrator_execute_uri "arbor://orchestrator/execute/**"

  @type run_handle :: %{
          agent_id: String.t(),
          signer: (binary() -> {:ok, term()} | {:error, term()}),
          cap_ids: [String.t()],
          attestation: Attestation.t()
        }

  @doc """
  Mint a per-run identity from a verified attestation and grant only its
  envelope-bounded capability descriptors.

  Verification chain (each step fails closed):
    1. Caller supplies the `CapsFile.Attestation` returned by `CapsFile.load/1`
    2. `Identity.generate` produces a fresh Ed25519 keypair
    3. `IdentityRegistry.register` enrolls the public key
    4. `Security.grant` creates the orchestrator/execute lobby cap
    5. `Security.grant` creates each attested capability descriptor

  On any failure, partial state (e.g., identity registered but caps
  not yet granted) is cleaned up before returning the error.
  """
  @spec mint(Attestation.t()) :: {:ok, run_handle()} | {:error, atom() | tuple()}
  def mint(%Attestation{} = attestation) do
    with :ok <- CapsFile.verify_attestation(attestation),
         {:ok, identity} <- generate_identity(),
         :ok <- register_identity(identity) do
      mint_registered(identity, attestation)
    end
  end

  def mint(_), do: {:error, :verified_attestation_required}

  @doc """
  Revoke every cap in the run handle and deregister the ephemeral
  identity.

  Best-effort: each revoke is logged on failure but never raises. This
  function MUST be safe to call in an `after` clause regardless of
  whether `mint/1` succeeded — that's how `PipelineRunner` guarantees
  cleanup even on pipeline crash.

  Pass `nil` for runs that never minted (caps file missing, etc.) to
  make the call-site uniform.
  """
  @spec revoke(run_handle() | nil) :: :ok
  def revoke(nil), do: :ok

  def revoke(%{agent_id: agent_id, cap_ids: cap_ids}) do
    Enum.each(cap_ids, &safe_revoke_cap/1)
    safe_deregister(agent_id)
    :ok
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp generate_identity do
    IdentityStruct.generate()
  end

  defp register_identity(%IdentityStruct{} = identity) do
    case IdentityRegistry.register(identity) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp grant_orchestrator_execute(agent_id) do
    Security.grant(principal: agent_id, resource: @orchestrator_execute_uri)
  end

  defp mint_registered(identity, attestation) do
    case grant_orchestrator_execute(identity.agent_id) do
      {:ok, lobby_cap} ->
        mint_declared_caps(identity, attestation, lobby_cap)

      {:error, reason} ->
        safe_deregister(identity.agent_id)
        {:error, {:grant_failed, @orchestrator_execute_uri, reason}}
    end
  end

  defp mint_declared_caps(identity, attestation, lobby_cap) do
    case grant_run_caps(identity.agent_id, attestation) do
      {:ok, run_caps} ->
        :ok = set_trust_profile_rules(identity.agent_id, attestation.capabilities)

        {:ok,
         %{
           agent_id: identity.agent_id,
           signer: Security.make_signer(identity.agent_id, identity.private_key),
           cap_ids: [lobby_cap.id | Enum.map(run_caps, & &1.id)],
           attestation: attestation
         }}

      {:error, reason, granted_caps} ->
        cleanup_registered(identity.agent_id, [lobby_cap | granted_caps])
        {:error, reason}
    end
  end

  defp grant_run_caps(agent_id, attestation) do
    attestation.capabilities
    |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, acc} ->
      # Provenance records that this cap was minted from a verified signed
      # envelope. `AuthDecision.check_approval` consults this metadata to
      # bypass the security ceiling :ask gate for parameter-bounded caps on
      # the "askable" URI classes (fs/write, code/write, file.* actions).
      # Always-locked URIs (shell, governance, code.hot_load) ignore this
      # marker — pre-approval can't unlock parameter-unbounded blast radius.
      metadata = %{
        provenance: %{
          source: :caps_file,
          manifest_version: attestation.version,
          issuer_id: attestation.issuer_id,
          pipeline_root: attestation.pipeline_root,
          pipeline_path: attestation.pipeline_path,
          graph_hash: attestation.graph_hash
        }
      }

      case Security.grant(
             principal: agent_id,
             resource: descriptor.resource_uri,
             constraints: descriptor.constraints,
             metadata: metadata
           ) do
        {:ok, cap} ->
          {:cont, {:ok, [cap | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:grant_failed, descriptor.resource_uri, reason}, Enum.reverse(acc)}}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      error -> error
    end
  end

  # Set trust profile rules on the ephemeral identity to `:allow` for
  # each granted cap's URI prefix. Without this, AuthDecision's
  # `check_approval/3` consults the trust profile AFTER finding the
  # cap; the default `:ask` mode for fs/shell/etc. operations forces
  # the auth chain to require human approval, which then times out
  # because the ephemeral identity has no human presence. Mirrors the
  # pattern in `Arbor.Scheduler.Identity.ensure_trust_profile/1`.
  #
  # The lobby cap (`arbor://orchestrator/execute/**`) is handled
  # separately by the same trust rule pattern. Each descriptor's URI
  # gets its `best_rule_prefix` (e.g. `arbor://fs/read/<path>/**`
  # becomes `arbor://fs/read`) and that prefix is allowed.
  #
  # Surfaced 2026-06-06 by the morning-digest LLM pipelines hitting
  # the approval gate even with matching per-run caps.
  defp set_trust_profile_rules(agent_id, descriptors) do
    prefixes =
      descriptors
      |> Enum.map(&trust_rule_prefix(&1.resource_uri))
      |> Enum.uniq()
      # Lobby cap covers pipeline traversal — needed by every run.
      |> List.insert_at(0, "arbor://orchestrator/execute")

    with :ok <- ensure_profile_exists(agent_id),
         :ok <- apply_allow_rules(agent_id, prefixes) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[RunIdentity] trust profile setup failed for #{agent_id}: #{inspect(reason)}"
        )

        # Don't fail the mint — the cap chain may still allow the run
        # depending on trust config. Logged for visibility.
        :ok
    end
  end

  defp ensure_profile_exists(agent_id) do
    if Arbor.Trust.Store.profile_exists?(agent_id) do
      :ok
    else
      profile = Arbor.Trust.Authority.new_profile(agent_id)

      case Arbor.Trust.Store.store_profile(profile) do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp apply_allow_rules(agent_id, prefixes) do
    result =
      Arbor.Trust.Store.update_profile(
        agent_id,
        fn profile ->
          rules = profile.rules || %{}
          new_rules = Enum.reduce(prefixes, rules, fn p, acc -> Map.put(acc, p, :allow) end)
          %{profile | rules: new_rules}
        end
      )

    case result do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Mirrors `Arbor.Trust.Store.best_rule_prefix/1`. Extracts the
  # `arbor://<domain>/<operation>` prefix from a fuller URI. Used to set
  # trust rules at the operation scope instead of per-path.
  defp trust_rule_prefix(uri) when is_binary(uri) do
    case String.split(uri, "/") do
      ["arbor:", "", domain, operation | _] -> "arbor://#{domain}/#{operation}"
      ["arbor:", "", domain | _] -> "arbor://#{domain}"
      _ -> uri
    end
  end

  defp cleanup_registered(agent_id, capabilities) do
    Enum.each(capabilities, &safe_revoke_cap(&1.id))
    safe_deregister(agent_id)
  end

  defp safe_revoke_cap(cap_id) do
    case Security.revoke(cap_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[RunIdentity] failed to revoke cap #{cap_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[RunIdentity] exception revoking cap #{cap_id}: #{inspect(Exception.message(e))}"
      )

      :ok
  end

  defp safe_deregister(agent_id) do
    case IdentityRegistry.deregister(agent_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RunIdentity] failed to deregister run identity #{agent_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[RunIdentity] exception deregistering #{agent_id}: #{inspect(Exception.message(e))}"
      )

      :ok
  end
end
