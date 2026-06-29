defmodule Arbor.Scheduler.Identity do
  @moduledoc """
  Per-machine cryptographic identity for the scheduler.

  Every Arbor node that runs `arbor_scheduler` provisions a scheduler
  identity on first start: an Ed25519 keypair is generated, the
  private key is stored encrypted-at-rest via
  `Arbor.Security.SigningKeyStore` under the fixed storage key
  `"system_scheduler"`, and the public key is registered with
  `Arbor.Security.Identity.Registry`. Subsequent starts on the same
  machine load the persisted keypair — the scheduler is a stable,
  long-lived system actor.

  The identity is used by `Arbor.Scheduler.Workers.PipelineRunner`
  to sign requests when invoking the orchestrator. This closes the
  loop on the security model: every scheduled pipeline run is
  unforgeably attributable to this node's scheduler agent_id (and
  through that, to this specific Arbor node), satisfying both the
  orchestrator's capability gate and the audit-provenance
  requirement.

  ## agent_id derivation

  `agent_id` is `"agent_" <> hex(SHA-256(public_key))`, derived
  cryptographically — the same shape every non-OIDC agent uses. We
  do NOT override it with a canonical name like `"agent_scheduler"`:
  `Arbor.Security.Identity.Registry` strictly validates that
  `agent_id == Crypto.derive_agent_id(public_key)` for any non-OIDC
  registration. Storage lookup uses the fixed key `"system_scheduler"`
  instead, so the keypair is recoverable across restarts without
  needing to know the agent_id in advance.

  ## Why per-machine and not per-cluster

  Each node holds its own keypair so:
    - Identity rotation on one node doesn't ripple to others
    - A compromised node's signing rights can be revoked without
      affecting peers
    - The audit chain naturally records which node ran which pipeline

  ## Capability + Trust profile granted

  Two policy artifacts are provisioned at first registration:

    1. A blanket `arbor://orchestrator/execute/**` **capability grant**
       (satisfies `CapabilityCheck` middleware).
    2. A **trust profile** with `arbor://orchestrator/execute` set to
       `:allow` (satisfies `AuthDecision.check_approval/3`, so scheduled
       pipelines don't escalate to consensus on every run).

  Both are scoped narrowly to `arbor://orchestrator/execute/*` — wide
  enough to cover all current pipeline node types (shell, file_write,
  etc.) but not so wide that the scheduler can act outside its lane.
  The shell.execute approval ceiling that AuthDecision enforces for
  human/agent flows is intentionally bypassed for the scheduler:
  pipelines are operator-authored static .dot files registered ahead
  of time, so the approval point is at registration, not per-run.
  Per the priorities discussion: start blanket, tighten to
  per-handler-type when a real pipeline forces the question.

  ## Public surface

    * `signer/0` — returns a signing function suitable to pass as the
      orchestrator's `:signer` opt. Returns `nil` if the Identity
      GenServer isn't running (e.g., in `:fast` tests with
      `start_children: false`). Callers MUST propagate `nil` through,
      not substitute a fallback — passing `nil` causes CapabilityCheck
      to halt with `:missing_signed_request`, which is the correct
      fail-closed behavior.
    * `agent_id/0` — the live agent_id this node uses. Stable across
      restarts on a given machine. Returns `nil` when the GenServer
      isn't running.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Security.Identity, as: IdentityStruct
  alias Arbor.Security
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Trust.Authority, as: TrustAuthority
  alias Arbor.Trust.Store, as: TrustStore

  # Fixed SigningKeyStore lookup key. NOT the agent_id — see moduledoc.
  @signing_id "system_scheduler"

  @blanket_capability "arbor://orchestrator/execute/**"
  # Rule prefix used in the trust profile. `best_rule_prefix/1` in
  # TrustStore would derive this from a full resource URI (e.g.
  # arbor://orchestrator/execute/shell → arbor://orchestrator/execute),
  # but we set it explicitly because the prefix is itself the
  # authorization scope this identity owns.
  @trust_rule_prefix "arbor://orchestrator/execute"

  # ── Public API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the agent_id this node's scheduler uses, or `nil` if the
  Identity GenServer isn't running.

  Cryptographically derived from the public key — stable across
  restarts on a given machine, distinct across machines.
  """
  @spec agent_id() :: String.t() | nil
  def agent_id do
    case GenServer.call(__MODULE__, :get_agent_id, 5_000) do
      {:ok, id} -> id
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Returns a signer function the orchestrator can use to mint signed
  requests on behalf of this node's scheduler agent.

  The function closure holds the agent_id and private signing key;
  the orchestrator receives only the function, never the raw key.

  Returns `nil` when the Identity GenServer isn't running. Callers
  must propagate `nil` — passing `nil` as the orchestrator's `:signer`
  causes the CapabilityCheck middleware to halt with
  `{:error, :missing_signed_request}`, which is the correct
  fail-closed shape.
  """
  @spec signer() :: (binary() -> {:ok, term()} | {:error, term()}) | nil
  def signer do
    case GenServer.call(__MODULE__, :get_signer, 5_000) do
      {:ok, signer_fn} -> signer_fn
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  # ── GenServer ──

  @impl true
  def init(_opts) do
    case load_or_create_identity() do
      {:ok, identity, status} ->
        Logger.info("[Scheduler.Identity] #{status} keypair for #{identity.agent_id}")

        :ok = ensure_capability(identity.agent_id)
        :ok = ensure_trust_profile(identity.agent_id)

        signer_fn = Security.make_signer(identity.agent_id, identity.private_key)
        {:ok, %{identity: identity, signer: signer_fn}}

      {:error, reason} ->
        Logger.error("[Scheduler.Identity] init failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_signer, _from, %{signer: signer_fn} = state) do
    {:reply, {:ok, signer_fn}, state}
  end

  def handle_call(:get_agent_id, _from, %{identity: identity} = state) do
    {:reply, {:ok, identity.agent_id}, state}
  end

  # ── Identity lifecycle ──

  defp load_or_create_identity do
    case SigningKeyStore.get_keypair(@signing_id) do
      {:ok, %{signing: signing_key}} ->
        build_existing(signing_key)

      {:error, _} ->
        create_new()
    end
  end

  defp build_existing(signing_key) do
    # Re-derive the public key from the persisted private signing key
    # — same pattern OIDC IdentityStore uses. Ed25519's `generate_key`
    # is deterministic for a given seed.
    {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, signing_key)

    case IdentityStruct.new(public_key: public_key, private_key: signing_key) do
      {:ok, identity} ->
        # Use the hex-derived agent_id IdentityStruct.new produced; do
        # NOT override. The Registry rejects mismatches.
        case register(identity) do
          :ok -> {:ok, identity, :loaded}
          err -> err
        end

      err ->
        err
    end
  end

  defp create_new do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    with :ok <- SigningKeyStore.put_keypair(@signing_id, private_key),
         {:ok, identity} <- IdentityStruct.new(public_key: public_key, private_key: private_key) do
      case register(identity) do
        :ok -> {:ok, identity, :generated}
        err -> err
      end
    end
  end

  defp register(%IdentityStruct{} = identity) do
    public_only = IdentityStruct.public_only(identity)

    case IdentityRegistry.register(public_only) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      other -> other
    end
  end

  defp ensure_capability(agent_id) do
    # Idempotent: if the capability is already granted, the kernel
    # returns an already-granted shape — treat any of those as success.
    case Security.grant(principal: agent_id, resource: @blanket_capability) do
      {:ok, _cap} ->
        Logger.info("[Scheduler.Identity] granted #{@blanket_capability} to #{agent_id}")
        :ok

      {:error, :already_granted} ->
        :ok

      {:error, {:already_granted, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Scheduler.Identity] capability grant failed for #{agent_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_trust_profile(agent_id) do
    # Idempotent: if a profile exists, just patch the rule; otherwise
    # mint a fresh untrusted-tier profile with the rule preset. Either
    # path leaves the rule for @trust_rule_prefix at :allow, which is
    # what AuthDecision.check_approval needs to skip escalation.
    case ensure_profile_exists(agent_id) do
      :ok ->
        case TrustStore.update_profile(agent_id, fn profile ->
               %{profile | rules: Map.put(profile.rules || %{}, @trust_rule_prefix, :allow)}
             end) do
          {:ok, _profile} ->
            Logger.info(
              "[Scheduler.Identity] trust rule #{@trust_rule_prefix} => :allow for #{agent_id}"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[Scheduler.Identity] trust rule update failed for #{agent_id}: #{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "[Scheduler.Identity] could not ensure trust profile for #{agent_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_profile_exists(agent_id) do
    if TrustStore.profile_exists?(agent_id) do
      :ok
    else
      profile = TrustAuthority.new_profile(agent_id)
      TrustStore.store_profile(profile)
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
