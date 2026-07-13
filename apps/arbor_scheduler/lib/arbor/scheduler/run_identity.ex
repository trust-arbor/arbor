defmodule Arbor.Scheduler.RunIdentity do
  @moduledoc """
  Per-pipeline-run ephemeral identity + capability lifecycle.

  Phase 5 of the scheduler-privesc redesign. For each pipeline run that
  has a verified signed attestation, this module mints a fresh
  Ed25519 keypair, registers it through `Arbor.Security`, grants the
  declared capabilities to that ephemeral principal, and returns an opaque
  SigningAuthority the orchestrator can use. After the run completes (success
  or failure), the caller calls `revoke/1` to close the authority, revoke each
  granted cap, and deregister the identity.

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
       grants {Z₁, Z₂} to E, opens authority-for-E  (this module)
       │
       ▼
  Orchestrator runs the pipeline as E, action layer
       sees E's caps include Z₁ and Z₂, file_write
       succeeds without approval gate
  ```

  Failure modes during mint return `{:error, reason}` and atomically roll back
  all effects. A scheduler-supervised lease monitors the caller independently,
  so cleanup also runs when the caller is killed before its `after` clause.
  """

  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Scheduler.CapsFile
  alias Arbor.Scheduler.CapsFile.Attestation
  alias Arbor.Scheduler.RunLease
  alias Arbor.Security
  alias Arbor.Trust

  # Every pipeline run needs the exact orchestrator/execute lobby capability to
  # enter the Engine. Descendant node operations are deliberately excluded:
  # each must be present in the signed attestation before it can be granted.
  @orchestrator_execute_uri "arbor://orchestrator/execute"
  @default_lease_ttl_ms :timer.hours(24)
  @runtime_marker_key {__MODULE__, :runtime_marker}

  @type run_handle :: %{
          agent_id: String.t(),
          signing_authority: SigningAuthority.t(),
          cap_ids: [String.t()],
          lease: RunLease.id()
        }

  @doc false
  def identity_name(peer_node \\ node()) when is_atom(peer_node) do
    identity_name(peer_node, local_runtime_marker())
  end

  @doc false
  def identity_name(peer_node, instance_id) when is_atom(peer_node) and is_binary(instance_id) do
    runtime_id = Application.get_env(:arbor_scheduler, :run_identity_runtime_id, "ephemeral")

    "scheduler-run:#{runtime_id}:#{node_marker(peer_node)}:#{instance_marker(instance_id)}"
  end

  @doc """
  Mint a per-run identity from a verified attestation and grant only its
  envelope-bounded capability descriptors.

  Verification chain (each step fails closed):
    1. Caller supplies the `CapsFile.Attestation` returned by `CapsFile.load/1`
    2. `Security.generate_identity` produces a fresh Ed25519 keypair
    3. `Security.register_identity` enrolls the public key
    4. `Security.grant` creates the orchestrator/execute lobby cap
    5. `Security.grant` creates each attested capability descriptor

  On any failure, partial state (e.g., identity registered but caps
  not yet granted) is cleaned up before returning the error.
  """
  @spec mint(Attestation.t(), keyword()) :: {:ok, run_handle()} | {:error, atom() | tuple()}
  def mint(attestation, opts \\ [])

  def mint(%Attestation{} = attestation, opts) do
    security = Keyword.get(opts, :security_facade, Security)
    trust = Keyword.get(opts, :trust_facade, Trust)
    ttl_ms = Keyword.get(opts, :lease_ttl_ms, lease_ttl_ms())

    cleanup_opts =
      Keyword.take(opts, [
        :cleanup_max_attempts,
        :cleanup_retry_base_ms,
        :cleanup_retry_max_ms,
        :cleanup_reconcile_base_ms,
        :cleanup_reconcile_max_ms
      ])

    with :ok <- CapsFile.verify_attestation(attestation),
         {:ok, lease} <-
           RunLease.start(
             self(),
             [security_facade: security, trust_facade: trust, ttl_ms: ttl_ms] ++ cleanup_opts
           ) do
      provision(attestation, lease, security, trust, ttl_ms)
    end
  end

  def mint(_, _opts), do: {:error, :verified_attestation_required}

  @doc """
  Revoke every cap in the run handle and deregister the ephemeral
  identity.

  Cleanup retries transient failures with bounded exponential backoff. If an
  operation still fails, the error is returned and retained by the lease so it
  cannot be mistaken for successful revocation.

  Pass `nil` for runs that never minted (caps file missing, etc.) to
  make the call-site uniform.
  """
  @spec revoke(run_handle() | nil) :: :ok | {:error, term()}
  def revoke(nil), do: :ok

  def revoke(%{lease: lease}), do: RunLease.revoke(lease)

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp provision(attestation, lease, security, trust, ttl_ms) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)

    result =
      with {:ok, identity} <- security.generate_identity(name: identity_name()),
           :ok <- register_identity(lease, identity, security),
           {:ok, lobby_cap} <-
             grant_capability(
               lease,
               security,
               identity.agent_id,
               @orchestrator_execute_uri,
               expires_at,
               []
             ),
           {:ok, run_caps} <-
             grant_run_caps(lease, security, identity.agent_id, attestation, expires_at),
           :ok <- set_trust_profile_rules(trust, identity.agent_id, attestation.capabilities),
           {:ok, authority} <- open_authority(lease, identity, security) do
        {:ok,
         %{
           agent_id: identity.agent_id,
           signing_authority: authority,
           cap_ids: [lobby_cap.id | Enum.map(run_caps, & &1.id)],
           lease: lease
         }}
      end

    case result do
      {:ok, _handle} = success ->
        success

      {:error, reason} ->
        _ = RunLease.revoke(lease)
        {:error, reason}
    end
  rescue
    exception ->
      _ = RunLease.revoke(lease)
      {:error, {:provision_exception, Exception.message(exception)}}
  catch
    :exit, reason ->
      _ = RunLease.revoke(lease)
      {:error, {:provision_exit, reason}}
  end

  defp register_identity(lease, identity, security) do
    public_identity = Arbor.Contracts.Security.Identity.public_only(identity)
    RunLease.register_identity(lease, public_identity, security)
  end

  defp grant_capability(lease, security, agent_id, resource, expires_at, extra_opts) do
    opts = [principal: agent_id, resource: resource, expires_at: expires_at] ++ extra_opts

    RunLease.grant_capability(lease, opts, security)
  end

  defp open_authority(lease, identity, security),
    do: RunLease.open_authority(lease, identity, security)

  defp grant_run_caps(lease, security, agent_id, attestation, expires_at) do
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

      case grant_capability(
             lease,
             security,
             agent_id,
             descriptor.resource_uri,
             expires_at,
             constraints: descriptor.constraints,
             metadata: metadata
           ) do
        {:ok, cap} ->
          {:cont, {:ok, [cap | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
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
  # The exact lobby cap (`arbor://orchestrator/execute`) is handled
  # separately by the same trust rule pattern. Each descriptor's URI
  # gets its `best_rule_prefix` (e.g. `arbor://fs/read/<path>/**`
  # becomes `arbor://fs/read`) and that prefix is allowed.
  #
  # Surfaced 2026-06-06 by the morning-digest LLM pipelines hitting
  # the approval gate even with matching per-run caps.
  defp set_trust_profile_rules(trust, agent_id, descriptors) do
    prefixes =
      descriptors
      |> Enum.map(&trust_rule_prefix(&1.resource_uri))
      |> Enum.uniq()
      # Lobby cap covers pipeline traversal — needed by every run.
      |> List.insert_at(0, "arbor://orchestrator/execute")

    opts =
      case trust.get_trust_profile(agent_id) do
        {:ok, profile} ->
          [
            baseline: profile.baseline,
            rules: Enum.reduce(prefixes, profile.rules || %{}, &Map.put(&2, &1, :allow))
          ]

        {:error, :not_found} ->
          [baseline: :ask, rules: Map.new(prefixes, &{&1, :allow})]

        {:error, reason} ->
          {:error, {:trust_profile_lookup_failed, reason}}
      end

    case opts do
      {:error, _reason} = error ->
        error

      opts ->
        case trust.ensure_trust_profile(agent_id, opts) do
          {:ok, _profile} ->
            :ok

          {:error, reason} ->
            {:error, {:trust_profile_provision_failed, reason}}
        end
    end
  rescue
    exception ->
      {:error, {:trust_profile_provision_exception, Exception.message(exception)}}
  catch
    :exit, reason ->
      {:error, {:trust_profile_provision_exit, reason}}
  end

  # Mirrors the trust policy operation prefix. Extracts the
  # `arbor://<domain>/<operation>` prefix from a fuller URI. Used to set
  # trust rules at the operation scope instead of per-path.
  defp trust_rule_prefix(uri) when is_binary(uri) do
    case String.split(uri, "/") do
      ["arbor:", "", domain, operation | _] -> "arbor://#{domain}/#{operation}"
      ["arbor:", "", domain | _] -> "arbor://#{domain}"
      _ -> uri
    end
  end

  defp lease_ttl_ms do
    Application.get_env(:arbor_scheduler, :run_identity_lease_ttl_ms, @default_lease_ttl_ms)
  end

  defp local_runtime_marker do
    case :persistent_term.get(@runtime_marker_key, :missing) do
      :missing ->
        marker = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        :persistent_term.put(@runtime_marker_key, marker)
        marker

      marker ->
        marker
    end
  end

  defp node_marker(peer_node) do
    peer_node
    |> Atom.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp instance_marker(instance_id) do
    instance_id
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
