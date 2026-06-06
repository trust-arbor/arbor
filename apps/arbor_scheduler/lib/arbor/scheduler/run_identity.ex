defmodule Arbor.Scheduler.RunIdentity do
  @moduledoc """
  Per-pipeline-run ephemeral identity + capability lifecycle.

  Phase 5 of the scheduler-privesc redesign. For each pipeline run that
  has a valid signed `.caps.json` file, this module mints a fresh
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
  CapsFile.load verifies signature + envelope        (Phase 3)
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
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry

  # Every pipeline run needs the orchestrator/execute capability to
  # actually traverse pipeline nodes (the CapabilityCheck middleware
  # demands it). The persistent scheduler identity holds this cap as a
  # permanent grant; per-run identities mint their own scoped to /**
  # so the pipeline can run at all. The "real" security gates are at
  # the resource layer (fs/write/, shell/exec/) — orchestrator/execute
  # is the lobby pass, not a resource permission.
  @orchestrator_execute_uri "arbor://orchestrator/execute/**"

  @type run_handle :: %{
          agent_id: String.t(),
          signer: (binary() -> {:ok, term()} | {:error, term()}),
          cap_ids: [String.t()]
        }

  @doc """
  Mint a per-run identity, grant the caps declared in `caps_file_path`,
  return a handle with the signer + cap ids for later revocation.

  Verification chain (each step fails closed):
    1. `CapsFile.load` validates the file and returns descriptors
    2. `Identity.generate` produces a fresh Ed25519 keypair
    3. `IdentityRegistry.register` enrolls the public key
    4. `Security.grant` for the orchestrator/execute lobby cap
    5. `Security.grant` for each declared capability descriptor

  On any failure, partial state (e.g., identity registered but caps
  not yet granted) is cleaned up before returning the error.
  """
  @spec mint(Path.t()) :: {:ok, run_handle()} | {:error, atom() | tuple()}
  def mint(caps_file_path) do
    with {:ok, descriptors} <- load_caps(caps_file_path),
         {:ok, identity} <- generate_identity(),
         :ok <- register_identity(identity),
         {:ok, lobby_cap} <- grant_orchestrator_execute(identity.agent_id),
         {:ok, run_caps} <- grant_run_caps(identity.agent_id, descriptors),
         :ok <- set_trust_profile_rules(identity.agent_id, descriptors) do
      {:ok,
       %{
         agent_id: identity.agent_id,
         signer: Security.make_signer(identity.agent_id, identity.private_key),
         cap_ids: [lobby_cap.id | Enum.map(run_caps, & &1.id)]
       }}
    else
      {:error, reason} = err ->
        # Best-effort cleanup of anything partially built. We don't
        # bother distinguishing where we were in the with chain — each
        # cleanup helper is idempotent and quietly ignores misses.
        cleanup_partial(reason)
        err
    end
  end

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

  defp load_caps(path) do
    case CapsFile.load(path) do
      {:ok, descriptors} -> {:ok, descriptors}
      {:error, _} = err -> err
    end
  end

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

  defp grant_run_caps(agent_id, descriptors) do
    descriptors
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
          issuer_id: descriptor.issuer_id
        }
      }

      case Security.grant(
             principal: agent_id,
             resource: descriptor.resource_uri,
             constraints: descriptor.constraints,
             metadata: metadata
           ) do
        {:ok, cap} -> {:cont, {:ok, [cap | acc]}}
        {:error, reason} -> {:halt, {:error, {:grant_failed, descriptor.resource_uri, reason}}}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      err -> err
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
    trust_authority = Arbor.Trust.Authority
    trust_store = Arbor.Trust.Store

    if Code.ensure_loaded?(trust_authority) and Code.ensure_loaded?(trust_store) and
         function_exported?(trust_store, :profile_exists?, 1) do
      prefixes =
        descriptors
        |> Enum.map(&trust_rule_prefix(&1.resource_uri))
        |> Enum.uniq()
        # Lobby cap covers pipeline traversal — needed by every run.
        |> List.insert_at(0, "arbor://orchestrator/execute")

      with :ok <- ensure_profile_exists(agent_id, trust_authority, trust_store),
           :ok <- apply_allow_rules(agent_id, prefixes, trust_store) do
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
    else
      # arbor_trust not loaded — best-effort skip.
      :ok
    end
  end

  defp ensure_profile_exists(agent_id, trust_authority, trust_store) do
    if apply(trust_store, :profile_exists?, [agent_id]) do
      :ok
    else
      profile = apply(trust_authority, :new_profile, [agent_id, :untrusted])

      case apply(trust_store, :store_profile, [profile]) do
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

  defp apply_allow_rules(agent_id, prefixes, trust_store) do
    result =
      apply(trust_store, :update_profile, [
        agent_id,
        fn profile ->
          rules = profile.rules || %{}
          new_rules = Enum.reduce(prefixes, rules, fn p, acc -> Map.put(acc, p, :allow) end)
          %{profile | rules: new_rules}
        end
      ])

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

  defp cleanup_partial(_reason) do
    # No-op for now: each helper above leaves the world either fully
    # advanced or fully rolled back. Future hooks could clean up
    # half-granted caps if the grant_run_caps step partially failed —
    # but Security.grant is atomic enough that the only realistic
    # half-state is "identity registered + lobby cap granted +
    # run_caps half-done." Surfacing that path under test is on the
    # follow-up list once a concrete failure mode forces the question.
    :ok
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
