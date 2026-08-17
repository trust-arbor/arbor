defmodule Arbor.Security do
  @moduledoc """
  Capability-based security for the Arbor platform.

  Arbor.Security provides authorization through unforgeable capability tokens,
  manages capability lifecycle (grant, revoke, list), and handles cryptographic
  agent identity (keypair generation, registration, signed request verification).

  Trust profile management (creation, scoring, tier progression, freezing) is
  handled by the separate `Arbor.Trust` library. Security focuses on capabilities
  and identity — callers that need trust operations should use `Arbor.Trust`
  directly.

  ## Quick Start

      # Check authorization (with audit logging)
      case Arbor.Security.authorize("agent_001", "arbor://fs/read/docs", :read) do
        {:ok, :authorized} -> proceed()
        {:error, reason} -> handle_denial(reason)
      end

  ## Capability Model

  Capabilities are unforgeable tokens that grant specific permissions:

      {:ok, cap} = Arbor.Security.grant(
        principal: "agent_001",
        resource: "arbor://fs/read/project/src",
        action: :read,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

  ## Signals

  Security emits signals for observability:

  - `{:security, :authorization_granted, %{...}}`
  - `{:security, :authorization_denied, %{...}}`
  - `{:security, :capability_granted, %{...}}`
  - `{:security, :capability_revoked, %{...}}`
  """

  @behaviour Arbor.Contracts.API.Security
  @behaviour Arbor.Contracts.API.Identity
  @behaviour Arbor.Common.SkillImporter.Security
  @behaviour Arbor.Signals.Contracts.Authorization
  @behaviour Arbor.Signals.Contracts.Crypto
  @behaviour Arbor.Signals.Contracts.IdentityKeys

  alias Arbor.Contracts.API.Security, as: SecurityContract
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Contracts.Security.Classification
  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.InvocationReceipt
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Contracts.Security.SigningAuthority.Validator, as: SigningAuthorityValidator
  alias Arbor.Contracts.Security.SigningAuthorityBootstrap
  alias Arbor.Common.SafePath
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Constraint
  alias Arbor.Security.Crypto
  alias Arbor.Security.Constraint.RateLimiter
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.DisclosureCapability
  alias Arbor.Security.EgressGate
  alias Arbor.Security.Events
  alias Arbor.Security.ExtensionEnvelopes
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.Keychain
  alias Arbor.Security.Reflex
  alias Arbor.Security.RevocationFence
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.Telemetry
  alias Arbor.Security.UriRegistry

  require Logger

  # ===========================================================================
  # Public API — short, human-friendly names
  # ===========================================================================

  @doc """
  Authorize an operation on a resource.

  Checks whether the principal holds a valid capability for the resource.

  ## Identity proof options

  - `:signed_request` — per-request Ed25519 proof (agents)
  - `:session_token` — HMAC human session proof (alternative to signing)
  - `:identity_verified` — Gateway pre-verified shortcut (no token present)
  - `:exact_capability_id` — require this one currently stored ordinary
    capability rather than accepting another covering capability. The selected
    capability must be signed, exactly resource- and scope-bound, and live.

  When `:session_token` is present it is extracted and redacted at this boundary
  before URI normalization, reflexes, context construction, or events. A present
  token forces active Registry status then HMAC/principal verification.

  ## Examples

      Arbor.Security.authorize("agent_001", "arbor://fs/read/docs")
      Arbor.Security.authorize(human_id, resource, :chat, session_token: token)
  """
  @impl Arbor.Signals.Contracts.Authorization
  @spec authorize(String.t(), String.t(), atom(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize(principal_id, resource_uri, action \\ nil, opts \\ []),
    do:
      check_if_principal_has_capability_for_resource_action(
        principal_id,
        resource_uri,
        action,
        opts
      )

  @exact_scope_keys MapSet.new([:session_id, :task_id, :principal_scope, :expected_egress])
  @exact_egress_keys MapSet.new([:max_tier, :destination])
  @exact_scalar_max_bytes 256
  @source_owned_egress_opt :source_owned_exact_egress_expectation

  @doc """
  Exercise one exact, signed ordinary capability from source-owned code.

  This narrow facade accepts no generic authorization options and never returns
  a capability struct. Security still requires the principal's Identity
  Registry status to be exactly `:active`; only the per-external-request
  SignedRequest proof is omitted. The selected ordinary capability must be the
  exact stored id and be live, signed, validly delegated, and exactly bound to
  the supplied principal/resource/scope. An optional expected egress constraint
  is checked against the exact capability selected by the normal authorization
  pipeline before stateful constraints and max-use accounting.

  `expectations` is a closed atom-keyed map with exactly these fields:

      %{
        session_id: binary | nil,
        task_id: binary | nil,
        principal_scope: binary | nil,
        expected_egress: nil | %{max_tier: atom, destination: binary}
      }

  Stateful constraints, max-use accounting, authorization events, and
  invocation receipts use the normal Security authorization side-effect path.
  """
  @spec authorize_source_owned_exact_ordinary_capability(
          String.t(),
          String.t(),
          atom(),
          String.t(),
          map()
        ) :: {:ok, :authorized} | {:error, :invalid_request | :unauthorized}
  def authorize_source_owned_exact_ordinary_capability(
        principal_id,
        resource_uri,
        action,
        capability_id,
        expectations
      ) do
    with :ok <-
           validate_exact_capability_request(
             principal_id,
             resource_uri,
             action,
             capability_id,
             expectations
           ),
         :ok <- require_exact_active_identity(principal_id),
         %{session_id: session_id, task_id: task_id, principal_scope: principal_scope} <-
           expectations,
         {:ok, :authorized} <-
           check_if_principal_has_capability_for_resource_action(
             principal_id,
             resource_uri,
             action,
             [
               verify_identity: false,
               exact_capability_id: capability_id,
               session_id: session_id,
               task_id: task_id,
               principal_scope: principal_scope
             ]
             |> Keyword.put(@source_owned_egress_opt, expectations.expected_egress)
           ) do
      {:ok, :authorized}
    else
      {:error, :invalid_request} = error ->
        error

      _denied ->
        {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp validate_exact_capability_request(
         principal_id,
         resource_uri,
         action,
         capability_id,
         expectations
       ) do
    if bounded_exact_scalar?(principal_id) and bounded_exact_scalar?(resource_uri) and
         is_atom(action) and not is_nil(action) and
         canonical_exact_capability_id?(capability_id) and
         valid_exact_expectations?(expectations) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp valid_exact_expectations?(expectations) when is_map(expectations) do
    MapSet.equal?(MapSet.new(Map.keys(expectations)), @exact_scope_keys) and
      optional_exact_scalar?(Map.get(expectations, :session_id)) and
      optional_exact_scalar?(Map.get(expectations, :task_id)) and
      optional_exact_scalar?(Map.get(expectations, :principal_scope)) and
      valid_exact_egress?(Map.get(expectations, :expected_egress))
  end

  defp valid_exact_expectations?(_expectations), do: false

  defp require_exact_active_identity(principal_id) do
    case Registry.identity_status(principal_id) do
      {:ok, :active} -> :ok
      _not_active -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp valid_exact_egress?(nil), do: true

  defp valid_exact_egress?(egress) when is_map(egress) do
    MapSet.equal?(MapSet.new(Map.keys(egress)), @exact_egress_keys) and
      Map.get(egress, :max_tier) in Classification.egress_tiers() and
      bounded_exact_scalar?(Map.get(egress, :destination))
  end

  defp valid_exact_egress?(_egress), do: false

  defp exact_egress_constraint?(%Capability{constraints: constraints}, %{
         max_tier: tier,
         destination: destination
       })
       when is_map(constraints) and is_atom(tier) and is_binary(destination) do
    egress = Map.get(constraints, :egress) || Map.get(constraints, "egress")

    is_map(egress) and
      normalize_exact_egress_tier(Map.get(egress, :max_tier) || Map.get(egress, "max_tier")) ==
        tier and
      (Map.get(egress, :destinations) || Map.get(egress, "destinations")) == [destination]
  end

  defp exact_egress_constraint?(_cap, _expectation), do: false

  defp normalize_exact_egress_tier(tier)
       when tier in [:on_host, :on_premises, :external_provider, :external_peer, :none],
       do: tier

  defp normalize_exact_egress_tier(tier) when is_binary(tier) do
    Enum.find(Classification.egress_tiers(), &(Atom.to_string(&1) == tier))
  end

  defp normalize_exact_egress_tier(_tier), do: nil

  defp optional_exact_scalar?(nil), do: true
  defp optional_exact_scalar?(value), do: bounded_exact_scalar?(value)

  defp bounded_exact_scalar?(value) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= @exact_scalar_max_bytes and
      String.valid?(value) and String.trim(value) == value and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp bounded_exact_scalar?(_value), do: false

  # Delivery-receipt issue admits only cryptographic proof keys. Never silently
  # strip. Explicitly forbidden (among others): :identity_verified,
  # :verify_identity (caller), :task_id, :principal_scope.
  @issue_session_mode_keys [:session_token]
  @issue_signed_mode_keys [:signed_request, :signer, :session_id, :expected_resource]
  @issue_admitted_opts [:session_token, :signed_request, :signer, :session_id, :expected_resource]
  @max_issue_human_principal_bytes 256

  @doc """
  Authorize a human principal and exchange success for a one-use delivery receipt.

  Raw `session_token` may enter only through this facade and is forwarded solely
  to `authorize/4`. The receipt carries no principal, resource, action, or
  session proof — only a Security-owned broker entry does.

  Exactly one active cryptographic proof mode is required:
  - `:session_token` — human HMAC session proof (no companions)
  - `:signed_request` — signed request proof; optional companions `:signer`,
    `:session_id`, `:expected_resource`. After closed option validation the
    wrapper injects `verify_identity: true` so verification always runs,
    regardless of the global identity-verification default.

  Public options may not select TTL, capacity, broker, clock, collaborators,
  `:identity_verified`, `:verify_identity`, `:task_id`, or `:principal_scope`.
  Modes are mutually exclusive; proof-specific companions cannot cross modes.
  """
  @spec authorize_and_issue_delivery_receipt(String.t(), String.t(), atom() | nil, keyword()) ::
          {:ok, DeliveryReceipt.t()}
          | {:error,
             :invalid_principal
             | :invalid_opts
             | :unauthorized
             | :pending_approval
             | :authorization_failed
             | :broker_full
             | :receipt_issue_failed
             | :broker_unavailable}
  def authorize_and_issue_delivery_receipt(
        principal_id,
        resource_uri,
        action \\ nil,
        opts \\ []
      ) do
    with :ok <- validate_issue_human_principal(principal_id),
         {:ok, safe_opts} <- validate_issue_opts(opts) do
      case authorize(principal_id, resource_uri, action, safe_opts) do
        {:ok, :authorized} ->
          case DeliveryReceiptBroker.issue(principal_id, resource_uri, action) do
            {:ok, %DeliveryReceipt{} = receipt} ->
              {:ok, receipt}

            {:error, reason}
            when reason in [:broker_full, :receipt_issue_failed, :broker_unavailable] ->
              {:error, reason}

            _ ->
              {:error, :broker_unavailable}
          end

        {:ok, :pending_approval, _proposal_id} ->
          {:error, :pending_approval}

        {:error, _reason} ->
          {:error, :unauthorized}

        _malformed ->
          {:error, :authorization_failed}
      end
    end
  rescue
    _ -> {:error, :authorization_failed}
  catch
    :throw, _ -> {:error, :authorization_failed}
    :exit, _ -> {:error, :authorization_failed}
  end

  @doc """
  Consume a one-use delivery receipt for an exact resource/action binding.

  Returns the Security-owned principal stored at issue time. Missing, replayed,
  forged, expired, or mismatched receipts share one bounded invalid error.
  """
  @spec consume_delivery_receipt(term(), String.t(), atom() | nil) ::
          {:ok, String.t()} | {:error, :invalid_receipt | :broker_unavailable}
  def consume_delivery_receipt(receipt, resource_uri, action)
      when is_binary(resource_uri) do
    case DeliveryReceipt.bearer_token(receipt) do
      {:ok, token} ->
        case DeliveryReceiptBroker.consume(token, resource_uri, action) do
          {:ok, principal_id} when is_binary(principal_id) ->
            {:ok, principal_id}

          {:error, reason} when reason in [:invalid_receipt, :broker_unavailable] ->
            {:error, reason}

          _ ->
            {:error, :invalid_receipt}
        end

      {:error, _} ->
        {:error, :invalid_receipt}
    end
  rescue
    _ -> {:error, :invalid_receipt}
  catch
    :throw, _ -> {:error, :invalid_receipt}
    :exit, _ -> {:error, :broker_unavailable}
  end

  def consume_delivery_receipt(_receipt, _resource_uri, _action),
    do: {:error, :invalid_receipt}

  @doc """
  Discard a delivery receipt. Idempotent for well-shaped receipts; reveals no
  existence or binding information.
  """
  @spec discard_delivery_receipt(term()) ::
          :ok | {:error, :invalid_receipt | :broker_unavailable}
  def discard_delivery_receipt(receipt) do
    case DeliveryReceipt.bearer_token(receipt) do
      {:ok, token} ->
        case DeliveryReceiptBroker.discard(token) do
          :ok -> :ok
          {:error, :broker_unavailable} -> {:error, :broker_unavailable}
          _ -> :ok
        end

      {:error, _} ->
        {:error, :invalid_receipt}
    end
  rescue
    _ -> {:error, :invalid_receipt}
  catch
    :throw, _ -> {:error, :invalid_receipt}
    :exit, _ -> {:error, :broker_unavailable}
  end

  # Bounded canonical human principal: non-empty, valid UTF-8, no NUL, `human_`
  # namespace only, ≤256 bytes (Agent message-facade ceiling). Agents rejected.
  defp validate_issue_human_principal(principal_id) do
    case SigningAuthorityValidator.validate_principal_id(principal_id) do
      :ok ->
        cond do
          not String.starts_with?(principal_id, "human_") ->
            {:error, :invalid_principal}

          byte_size(principal_id) > @max_issue_human_principal_bytes ->
            {:error, :invalid_principal}

          true ->
            :ok
        end

      {:error, _} ->
        {:error, :invalid_principal}
    end
  end

  defp validate_issue_opts(opts) do
    cond do
      not is_list(opts) ->
        {:error, :invalid_opts}

      not Keyword.keyword?(opts) ->
        {:error, :invalid_opts}

      true ->
        keys = Keyword.keys(opts)

        cond do
          Enum.any?(keys, fn k -> k not in @issue_admitted_opts end) ->
            {:error, :invalid_opts}

          length(keys) != length(Enum.uniq(keys)) ->
            {:error, :invalid_opts}

          true ->
            validate_issue_proof_shape(opts)
        end
    end
  rescue
    _ -> {:error, :invalid_opts}
  catch
    _, _ -> {:error, :invalid_opts}
  end

  # Exactly one active cryptographic proof mode:
  #   - :session_token alone (no companions)
  #   - :signed_request with optional :signer / :session_id / :expected_resource
  # Caller :identity_verified and :verify_identity are never admitted.
  # Signed mode injects verify_identity: true after validation so authorize/4
  # always verifies regardless of the global identity-verification default.
  defp validate_issue_proof_shape(opts) do
    has_session = Keyword.has_key?(opts, :session_token)
    has_signed = Keyword.has_key?(opts, :signed_request)
    keys = Keyword.keys(opts)

    cond do
      has_session and has_signed ->
        {:error, :invalid_opts}

      has_session ->
        if Enum.all?(keys, &(&1 in @issue_session_mode_keys)) do
          {:ok, opts}
        else
          {:error, :invalid_opts}
        end

      has_signed ->
        if Enum.all?(keys, &(&1 in @issue_signed_mode_keys)) do
          # Force active verification after closed caller-option validation.
          {:ok, Keyword.put(opts, :verify_identity, true)}
        else
          {:error, :invalid_opts}
        end

      true ->
        {:error, :invalid_opts}
    end
  end

  @doc """
  Record a durable security event for an answered approval request.

  External approval surfaces should use this facade instead of writing directly
  to the event backend.
  """
  @spec record_approval_answered(String.t(), String.t(), atom(), atom(), keyword()) ::
          :ok | {:error, term()}
  def record_approval_answered(actor_id, approval_id, source, decision, opts \\ []) do
    Events.record_approval_answered(actor_id, approval_id, source, decision, opts)
  end

  @doc """
  Record a durable security event for an async orchestration task dispatch.

  External orchestration surfaces should use this facade after starting a task.
  """
  @spec record_orchestration_task_dispatched(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_orchestration_task_dispatched(actor_id, task_id, agent_id, opts \\ []) do
    Events.record_orchestration_task_dispatched(actor_id, task_id, agent_id, opts)
  end

  @doc """
  Return the effective resource URI used by the authorization matcher.

  This is exposed so policy-layer code can perform explicit pre-authorization
  decisions against the same URI the security kernel will check. In particular,
  bare `arbor://fs/<op>` URIs plus `file_path:` are synthesized into the
  path-embedded URI before capability lookup.
  """
  @spec authorization_resource_uri(String.t(), keyword()) :: String.t()
  def authorization_resource_uri(resource_uri, opts \\ []),
    do: maybe_synthesize_fs_path_uri(resource_uri, opts)

  @doc """
  Return the checked effective resource URI used by authorization.

  Unlike `authorization_resource_uri/2`, this reports path-normalization errors
  instead of falling back to the caller's original URI. Authorization and trust
  policy callers use this form so invalid `file_path:` input fails closed before
  capability lookup or policy minting.
  """
  @spec normalize_authorization_resource_uri(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def normalize_authorization_resource_uri(resource_uri, opts \\ []),
    do: synthesize_fs_path_uri(resource_uri, opts)

  @doc """
  Validate an imported skill map through reflex screening.

  Checks the skill name as command context and the skill body as URL
  context via `Arbor.Security.Reflex.check/1`. Warnings are admissible;
  blocks reject. Reflex operational failures become `:reflex_unavailable`.
  """
  @spec validate_imported_skill(map()) ::
          :ok
          | {:error, :blocked | :invalid_skill | :malformed_reflex_result | :reflex_unavailable}
  @impl true
  def validate_imported_skill(skill) when is_map(skill) do
    name = imported_skill_text(skill, :name)
    body = imported_skill_text(skill, :body)

    with :ok <- check_imported_skill_context(%{command: name}),
         :ok <- check_imported_skill_context(%{url: body}) do
      :ok
    end
  end

  def validate_imported_skill(_skill), do: {:error, :invalid_skill}

  defp imported_skill_text(skill, key) do
    case Map.get(skill, key) || Map.get(skill, Atom.to_string(key)) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp check_imported_skill_context(context) do
    context
    |> Reflex.check()
    |> normalize_imported_skill_reflex()
  rescue
    _ -> {:error, :reflex_unavailable}
  catch
    _, _ -> {:error, :reflex_unavailable}
  end

  defp normalize_imported_skill_reflex(:ok), do: :ok
  defp normalize_imported_skill_reflex({:warned, _warnings}), do: :ok
  defp normalize_imported_skill_reflex({:blocked, _reflex, _message}), do: {:error, :blocked}
  defp normalize_imported_skill_reflex(_other), do: {:error, :malformed_reflex_result}

  @doc """
  Standalone egress authorization for callers WITHOUT an operation capability
  (2026-06-14 URI-addressing-vs-classification decision) — notably the
  compute-node LLM path (`LlmHandler`), where pipeline LLM calls have no per-op
  capability. Unlike `authorize/4`, this checks ONLY egress (it does not require
  or look up a capability authorizing the operation itself); it supplies the
  agent's egress-constrained caps to `EgressGate` for the `:ask`-downgrade
  refinement.

  Inert (`:allow`) unless `config :arbor_security, :egress_gate_enforcing`. The
  security kernel does not consult trust policy directly; callers that want
  profile standing pass `:egress_mode` in `opts` or use `Arbor.Trust.authorize_egress/3`.
  Emits `:egress_observed` telemetry for boundary-crossing egress regardless, so
  the compute-node egress surface is observable while the gate is dark. Arbor's
  signal runtime bridges this telemetry back to signals when `arbor_signals` is
  running.

  ## Parameters
  - `egress_tier` — resolved `Arbor.Contracts.Security.Classification.egress_tier`
  - `opts` — `:egress_taint` (level/Taint), `:egress_destination` (host/provider),
    `:egress_mode` (`:allow`/`:ask`/`:block`/`:auto`) from a policy layer;
    `:session_id`/`:task_id`/`:principal_scope` for ordinary-candidate scope
    matching (VP-05D2A0); `:disclosure_capability_id` plus
    `:egress_provider`/`:egress_runtime`/`:egress_model` (in addition to
    `:egress_destination`) to consult an interactive disclosure capability —
    see `Arbor.Security.DisclosureCapability`. Omitting `:disclosure_capability_id`
    is fully behavior-preserving for every existing caller.

  ## Returns
  - `:allow`
  - `{:requires_approval, :egress}` — the agent lacks standing; caller decides how
    to surface (the compute-node path halts the node)
  - `{:error, {:egress_blocked, tier, reason}}` — taint exfil or profile `:block`
  """
  @spec authorize_egress(String.t(), atom(), keyword()) ::
          :allow
          | {:requires_approval, :egress}
          | {:error, {:egress_blocked, atom(), atom()}}
  def authorize_egress(principal_id, egress_tier, opts \\ []) do
    if Keyword.keyword?(opts) do
      do_authorize_egress(principal_id, egress_tier, opts)
    else
      {:error, {:egress_blocked, egress_tier, :invalid_options}}
    end
  end

  @doc """
  Validate a closed E0C activation or invocation authorization envelope.

  This is a shape/digest check. Signature and expiry verification use
  `validate_signed_extension_envelope/2`.
  """
  @spec validate_extension_envelope(atom(), term()) :: {:ok, map()} | {:error, atom()}
  def validate_extension_envelope(kind, document) do
    ExtensionEnvelopes.validate(kind, document)
  end

  @doc "Validate a signed E0C authorization envelope."
  @spec validate_signed_extension_envelope(term(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def validate_signed_extension_envelope(document, opts \\ []) do
    ExtensionEnvelopes.validate_signed(document, opts)
  end

  defp do_authorize_egress(principal_id, egress_tier, opts) do
    emit_egress_observed(principal_id, egress_tier, opts)

    scope_opts = Keyword.take(opts, [:session_id, :task_id, :principal_scope])

    ordinary_caps =
      case CapabilityStore.list_valid_for_principal(principal_id, scope_opts) do
        {:ok, list} -> list
        _ -> []
      end

    disclosure_cap = resolve_disclosure_candidate(principal_id, opts)

    case EgressGate.decide(principal_id, egress_tier, opts, ordinary_caps, disclosure_cap) do
      :allow -> :allow
      :ask -> {:requires_approval, :egress}
      {:block, reason} -> {:error, {:egress_blocked, egress_tier, reason}}
    end
  end

  @doc """
  Mint a new interactive disclosure capability (VP-05D2A0). See
  `Arbor.Security.DisclosureCapability.issue/1` for the option contract and
  invariants.
  """
  @spec issue_disclosure_capability(keyword()) :: {:ok, Capability.t()} | {:error, atom()}
  def issue_disclosure_capability(opts), do: DisclosureCapability.issue(opts)

  @doc """
  Mint an interactive disclosure capability and return only its opaque id.

  Cross-library consumers should prefer this facade boundary so capability
  structs remain private to `arbor_security`.
  """
  @spec issue_disclosure_capability_id(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def issue_disclosure_capability_id(opts) do
    case issue_disclosure_capability(opts) do
      {:ok, %Capability{id: id}} when is_binary(id) -> {:ok, id}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :disclosure_capability_rejected}
    end
  end

  @doc """
  Revalidate one exact interactive disclosure capability against a live request.

  This is the public, capability-struct-free counterpart to disclosure issuance.
  `principal_id` is the executing agent and cannot be overridden through `opts`;
  the remaining options are the live session, task, authenticated-human scope,
  and exact egress route accepted by `issue_disclosure_capability/1` and
  `authorize_egress/3`.

  The check is independent of `:egress_gate_enforcing`. It does not authorize
  egress by itself: callers must still apply their ordinary trust and egress
  policy. It returns `:ok` only while the exact stored capability remains
  current, signed, undelegated, unrevoked, scope-matched, and route-matched.
  No capability struct crosses the facade.
  """
  @spec validate_disclosure_capability(String.t(), String.t(), keyword()) ::
          :ok | {:error, atom()}
  def validate_disclosure_capability(principal_id, capability_id, opts \\ []) do
    if Keyword.keyword?(opts) do
      request_opts = Keyword.put(opts, :principal_id, principal_id)

      case DisclosureCapability.fetch_and_validate(capability_id, request_opts) do
        {:ok, %Capability{}} -> :ok
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :disclosure_capability_rejected}
      end
    else
      {:error, :invalid_fetch_opts}
    end
  rescue
    _ -> {:error, :disclosure_capability_rejected}
  catch
    _, _ -> {:error, :disclosure_capability_rejected}
  end

  # Resolves `opts[:disclosure_capability_id]` to an already-revalidated
  # disclosure Capability, or nil on ANY validation failure (forged, unsigned,
  # expired, wrong-principal/session/task/human, delegated, revoked, malformed,
  # wrong-route, or the store/authority being unavailable all collapse to the
  # same fail-closed nil here — EgressGate simply cannot use it to override
  # untrusted/hostile taint).
  defp resolve_disclosure_candidate(principal_id, opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :disclosure_capability_id) do
        id when is_binary(id) ->
          request_opts = Keyword.put(opts, :principal_id, principal_id)

          case DisclosureCapability.fetch_and_validate(id, request_opts) do
            {:ok, cap} -> cap
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  # Observability for boundary-crossing egress on the standalone path. Fire-and-
  # forget; only for external tiers (on_host/on_premises are low-signal).
  defp emit_egress_observed(principal_id, tier, opts)
       when tier in [:external_provider, :external_peer] do
    data = %{
      agent_id: principal_id,
      egress_tier: tier,
      enforcing: EgressGate.enforcing?(),
      egress_destination: Keyword.get(opts, :egress_destination),
      # The flowing data's taint level — THE signal for observe-before-enable:
      # whether real egress carries untrusted data the taint conjunct would block.
      egress_taint: egress_taint_level(Keyword.get(opts, :egress_taint)),
      source: :compute_node,
      # VP-05D2A0 — bounded: id and a presence flag only, never the human
      # principal_scope, the constraints map, or any raw authority.
      disclosure_capability_id: sanitized_disclosure_capability_id(opts),
      disclosure_requested: not is_nil(Keyword.get(opts, :disclosure_capability_id))
    }

    # Prefer durable bridging so observe-before-enable data persists to the
    # EventLog (security:events stream), matching the action path when the
    # signals telemetry bridge is attached.
    Telemetry.emit(:egress_observed, data,
      signal_durable: true,
      stream_id: "security:events"
    )

    :ok
  rescue
    _ -> :ok
  end

  defp emit_egress_observed(_principal_id, _tier, _opts), do: :ok

  defp sanitized_disclosure_capability_id(opts) do
    case Keyword.get(opts, :disclosure_capability_id) do
      id when is_binary(id) ->
        if DisclosureCapability.valid_capability_id?(id), do: id, else: nil

      _ ->
        nil
    end
  end

  # Normalize an egress taint opt (level atom or Taint struct) to a level atom.
  defp egress_taint_level(%{level: level}), do: level
  defp egress_taint_level(level) when is_atom(level), do: level
  defp egress_taint_level(_), do: nil

  @doc """
  Grant a capability to an agent.

  ## Options

  - `:principal` - Agent ID (required)
  - `:resource` - Resource URI (required)
  - `:constraints` - Additional constraints map
  - `:expires_at` - Expiration DateTime
  - `:delegation_depth` - How many times this can be delegated (default: 3)
  """
  @spec grant(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def grant(opts), do: grant_capability_to_principal_for_resource(opts)

  @doc """
  Grant an ordinary capability and return only its opaque id.

  Cross-library consumers should prefer this facade boundary so capability
  structs remain private to `arbor_security`.
  """
  @spec grant_capability_id(keyword()) :: {:ok, String.t()} | {:error, term()}
  def grant_capability_id(opts) do
    case grant(opts) do
      {:ok, %Capability{id: id}} when is_binary(id) -> {:ok, id}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :capability_grant_failed}
    end
  end

  @doc "Revoke a capability."
  @spec revoke(String.t(), keyword()) :: :ok | {:error, :not_found | term()}
  def revoke(capability_id, opts \\ []), do: revoke_capability_by_id(capability_id, opts)

  @doc """
  Revoke all session-scoped capabilities for a session.

  Used to clean up capabilities granted for a session's lifetime (e.g. after a
  trust-profile change or session termination). Capabilities not bound to the
  given `session_id` are left untouched.
  """
  @spec revoke_by_session(String.t()) :: {:ok, non_neg_integer()}
  def revoke_by_session(session_id), do: CapabilityStore.revoke_by_session(session_id)

  @doc """
  Revoke all task-scoped capabilities for a task.

  VP-05D2A0 exposes both task and session revocation at the security facade.
  Agent/Voice terminal lifecycle call sites are wired by VP-05D2A1/A2.
  """
  @spec revoke_by_task(String.t()) :: {:ok, non_neg_integer()}
  def revoke_by_task(task_id), do: CapabilityStore.revoke_by_task(task_id)

  # ===========================================================================
  # Acknowledged, crash-journal-safe capability mutation (Phase 4C C3A).
  #
  # Narrow facade for exact grant/revoke suitable for a crash-recovery journal.
  # Cross-library callers receive only a bounded status and an opaque
  # capability id — never a Capability struct or persistence record. Ordinary
  # grant/1 and revoke/1 compatibility behavior is unchanged.
  # ===========================================================================

  @acknowledged_grant_required [:capability_id, :granted_at, :principal, :resource]

  @acknowledged_grant_optional [
    :expires_at,
    :not_before,
    :constraints,
    :delegation_depth,
    :max_uses,
    :allowed_delegatees,
    :session_id,
    :task_id,
    :principal_scope,
    :metadata
  ]

  @acknowledged_grant_admitted @acknowledged_grant_required ++
                                 @acknowledged_grant_optional
  @acknowledged_grant_max_opts 32
  @acknowledged_grant_max_map_keys 64
  @acknowledged_grant_max_map_depth 6
  @acknowledged_grant_max_nodes 1_024
  @acknowledged_grant_max_list_len 64
  @acknowledged_grant_max_delegatees 64

  @doc """
  Grant a capability via the acknowledged, crash-journal-safe exact path.

  `opts` carries a deterministic `:capability_id` and a stable `:granted_at`
  (plus `:principal`/`:resource` and a closed set of bounded optionals) so a
  journal replay is byte-identical to the original grant. An exact stored
  replay returns `{:ok, :idempotent, id}`; a mismatched occupant of the id
  returns `{:error, :id_conflict}`; a different same-principal/resource
  capability returns `{:error, :resource_conflict}` and is never replaced.

  Returns bounded status + the opaque capability id only. A best-effort audit
  event is emitted for observed `:applied` responses only; it is observability,
  not a crash-atomic outbox, and may be lost if the process exits between the
  durable admission and the emit. The Agent operation journal remains the C3
  workflow recovery authority. Idempotent retries emit no duplicate.
  """
  @spec acknowledged_grant(keyword()) ::
          {:ok, :applied | :idempotent, String.t()}
          | {:error,
             :invalid_request
             | :id_conflict
             | :resource_conflict
             | :quota_exceeded
             | :capability_store_unavailable
             | :outcome_unknown}
  def acknowledged_grant(opts) do
    with {:ok, safe_opts} <- validate_acknowledged_grant_opts(opts),
         {:ok, signed_cap} <- build_and_sign_acknowledged_grant(safe_opts) do
      result = CapabilityStore.acknowledged_put(signed_cap)
      emit_acknowledged_grant_audit(result, signed_cap)
      result
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  # Audit is best-effort observability for OBSERVED :applied responses, ISOLATED
  # from the mutation: an audit-emission failure can never relabel an
  # already-applied mutation as unavailable or unknown, and the store result is
  # returned unchanged regardless of audit outcome. This is NOT a crash-atomic
  # outbox — an exit between durable admission and the emit loses the event, so
  # the Agent operation journal (not this audit) is the C3 workflow authority.
  defp emit_acknowledged_grant_audit({:ok, :applied, _capability_id}, signed_cap) do
    Events.record_capability_granted(signed_cap)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emit_acknowledged_grant_audit(_result, _signed_cap), do: :ok

  @doc """
  Revoke a capability via the acknowledged, crash-journal-safe exact path.

  Authoritative absence is `{:ok, :idempotent, id}`; a durably-acknowledged
  deletion precedes live eviction and `{:ok, :applied, id}`. An ambiguous
  persistence result is never reported as applied (`:outcome_unknown`). A
  best-effort audit event is emitted for observed `:applied` responses only; it
  is observability, not a crash-atomic outbox (see `acknowledged_grant/1`).

  This arity revokes **current id occupancy**. For a durable workflow that
  observed an earlier incarnation, use `prepare_acknowledged_revoke/1` and
  `acknowledged_revoke/2` so a same-id re-grant is not deleted by a stale call.
  """
  @spec acknowledged_revoke(String.t()) ::
          {:ok, :applied | :idempotent, String.t()}
          | {:error, :invalid_request | :capability_store_unavailable | :outcome_unknown}
  def acknowledged_revoke(capability_id) do
    if canonical_exact_capability_id?(capability_id) do
      result = CapabilityStore.acknowledged_revoke(capability_id)
      emit_acknowledged_revoke_audit(result)
      result
    else
      {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  @doc """
  Prepare a closed v1 expected-Record revocation fence for one capability id
  or a previously observed Capability.

  Binary id path: one owner-mediated authoritative read with restore-grade
  decode and authority signature verification. Returns a JSON-clean fence
  binding capability identity plus Record id/generation/revision and a
  domain-separated digest of `Capability.signing_payload/1`. Authoritative
  absence is `:not_found`. Unavailable or unverifiable authority is not a
  usable fence.

  Capability path (authority boundary):
  1. Pure primitive admission → verification copy with `delegation_chain`
     stripped (nested chain never enters owner mailboxes).
  2. Current-authority cryptographic verification of that copy
     (`SystemAuthority.verify_authority_capability_signature/1`).
  3. Total-safe re-admit and reduce to a closed expected identity.
  4. One authoritative CapabilityStore read/compare on that identity only.

  Shape and logical signature failures are `{:error, :invalid_request}`.
  Store outcomes (`:not_found`, `:identity_conflict`, infrastructure atoms)
  pass through unchanged. A different same-id payload is
  `:identity_conflict` with zero mutation.
  """
  @spec prepare_acknowledged_revoke(String.t() | Capability.t()) ::
          {:ok, map()}
          | {:error,
             :invalid_request
             | :not_found
             | :identity_conflict
             | :capability_store_unavailable
             | :outcome_unknown}
  def prepare_acknowledged_revoke(capability_id) when is_binary(capability_id) do
    if canonical_exact_capability_id?(capability_id) do
      CapabilityStore.prepare_acknowledged_revoke(capability_id)
    else
      {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  def prepare_acknowledged_revoke(%Capability{} = cap) do
    # do-result is the CapabilityStore outcome unchanged (:ok fence, :not_found,
    # :identity_conflict, infrastructure). else preserves shape/sig vs infra.
    with {:ok, verify_cap} <- RevocationFence.admit_expected_for_prepare(cap),
         :ok <- verify_expected_authority_signature(verify_cap),
         {:ok, expected} <- RevocationFence.expected_identity(verify_cap) do
      CapabilityStore.prepare_acknowledged_revoke_expected(expected)
    else
      {:error, :invalid_request} ->
        {:error, :invalid_request}

      {:error, :capability_store_unavailable} = err ->
        err

      {:error, :outcome_unknown} = err ->
        err
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  def prepare_acknowledged_revoke(_), do: {:error, :invalid_request}

  # Logical signature/issuer miss → :invalid_request. Authority process
  # failures remain infrastructure atoms (not collapsed into bad-request).
  defp verify_expected_authority_signature(%Capability{} = verify_cap) do
    case SystemAuthority.verify_authority_capability_signature(verify_cap) do
      :ok -> :ok
      {:error, :invalid_capability_signature} -> {:error, :invalid_request}
      {:error, _} -> {:error, :invalid_request}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  @doc """
  Pure admission of a closed v1 fence against exact capability identity expectations.

  `expectations` must be exactly `%{capability_id: ..., principal_id: ...,
  resource_uri: ...}`. Validates the fence once through `RevocationFence`,
  requires all three exact matches, and returns the canonical string-keyed
  fence only on success. No IO.
  """
  @spec admit_acknowledged_revoke_fence(map(), map()) ::
          {:ok, map()} | {:error, :invalid_request}
  def admit_acknowledged_revoke_fence(fence, expectations) do
    RevocationFence.admit_with_expectations(fence, expectations)
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  @doc """
  Revoke only if the current verified Record exactly matches the fence from
  `prepare_acknowledged_revoke/1`.

  Authoritative absence is idempotent. A present replacement is
  `:identity_conflict` with zero mutation. Does not fall back to occupancy-only
  `acknowledged_revoke/1`. Audit emission for `:applied` matches `/1`.
  """
  @spec acknowledged_revoke(String.t(), map()) ::
          {:ok, :applied | :idempotent, String.t()}
          | {:error,
             :invalid_request
             | :identity_conflict
             | :capability_store_unavailable
             | :outcome_unknown}
  def acknowledged_revoke(capability_id, fence) do
    with true <- canonical_exact_capability_id?(capability_id),
         :ok <- RevocationFence.admit_fence(capability_id, fence) do
      result = CapabilityStore.acknowledged_revoke(capability_id, fence)
      emit_acknowledged_revoke_audit(result)
      result
    else
      false ->
        {:error, :invalid_request}

      {:error, :invalid_request} ->
        {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  defp emit_acknowledged_revoke_audit({:ok, :applied, capability_id}) do
    Events.record_capability_revoked(capability_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emit_acknowledged_revoke_audit(_result), do: :ok

  defp validate_acknowledged_grant_opts(opts) do
    cond do
      not is_list(opts) ->
        {:error, :invalid_request}

      not ack_opts_count_ok?(opts, 0) ->
        {:error, :invalid_request}

      not Keyword.keyword?(opts) ->
        {:error, :invalid_request}

      true ->
        validate_acknowledged_grant_keys(opts)
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  # Bound top-level option count BEFORE any Keyword API (no O(n) traversal on
  # an unbounded opts list). Walks at most max_opts+1 elements.
  defp ack_opts_count_ok?([_ | rest], n) when n < @acknowledged_grant_max_opts,
    do: ack_opts_count_ok?(rest, n + 1)

  defp ack_opts_count_ok?([], _n), do: true
  defp ack_opts_count_ok?(_, _n), do: false

  defp validate_acknowledged_grant_keys(opts) do
    keys = Keyword.keys(opts)

    cond do
      Enum.any?(@acknowledged_grant_required, &(&1 not in keys)) ->
        {:error, :invalid_request}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_request}

      Enum.any?(keys, &(&1 not in @acknowledged_grant_admitted)) ->
        {:error, :invalid_request}

      true ->
        validate_acknowledged_grant_values(opts)
    end
  end

  defp validate_acknowledged_grant_values(opts) do
    checks = [
      canonical_exact_capability_id?(Keyword.fetch!(opts, :capability_id)),
      canonical_ack_datetime?(Keyword.fetch!(opts, :granted_at)),
      bounded_exact_scalar?(Keyword.fetch!(opts, :principal)),
      SigningAuthorityValidator.validate_principal_id(Keyword.fetch!(opts, :principal)) == :ok,
      valid_ack_resource?(Keyword.fetch!(opts, :resource)),
      valid_ack_opt_datetime?(Keyword.get(opts, :expires_at)),
      valid_ack_opt_datetime?(Keyword.get(opts, :not_before)),
      valid_ack_delegation_depth?(Keyword.get(opts, :delegation_depth)),
      valid_ack_opt_posint?(Keyword.get(opts, :max_uses)),
      valid_ack_delegatees?(Keyword.get(opts, :allowed_delegatees)),
      valid_ack_opt_scalar?(Keyword.get(opts, :session_id)),
      valid_ack_opt_scalar?(Keyword.get(opts, :task_id)),
      valid_ack_opt_scalar?(Keyword.get(opts, :principal_scope)),
      valid_ack_opt_maps?(opts)
    ]

    if Enum.all?(checks, &(&1 == true)), do: {:ok, opts}, else: {:error, :invalid_request}
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  defp build_and_sign_acknowledged_grant(opts) do
    case Capability.new(
           resource_uri: Keyword.fetch!(opts, :resource),
           principal_id: Keyword.fetch!(opts, :principal),
           id: Keyword.fetch!(opts, :capability_id),
           granted_at: Keyword.fetch!(opts, :granted_at),
           expires_at: Keyword.get(opts, :expires_at),
           not_before: Keyword.get(opts, :not_before),
           constraints: Keyword.get(opts, :constraints, %{}),
           delegation_depth: Keyword.get(opts, :delegation_depth, 3),
           max_uses: Keyword.get(opts, :max_uses),
           allowed_delegatees: Keyword.get(opts, :allowed_delegatees),
           session_id: Keyword.get(opts, :session_id),
           task_id: Keyword.get(opts, :task_id),
           principal_scope: Keyword.get(opts, :principal_scope),
           metadata: Keyword.get(opts, :metadata, %{})
         ) do
      {:ok, cap} ->
        # Pin signed_at deterministically to the admitted granted_at BEFORE
        # signing. signed_at is part of signing_payload/1, so pinning it to the
        # already-canonical granted_at makes the signing payload byte-identical
        # across delayed journal retries (identity-exact across wall-clock).
        cap = %{cap | signed_at: cap.granted_at}

        case SystemAuthority.sign_capability(cap) do
          {:ok, signed_cap} -> {:ok, signed_cap}
          {:error, _reason} -> {:error, :capability_store_unavailable}
        end

      {:error, _reason} ->
        {:error, :invalid_request}

      _other ->
        {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :capability_store_unavailable}
  catch
    _, _ -> {:error, :capability_store_unavailable}
  end

  defp valid_ack_opt_datetime?(nil), do: true
  defp valid_ack_opt_datetime?(%DateTime{} = value), do: canonical_ack_datetime?(value)
  defp valid_ack_opt_datetime?(_), do: false

  # Serializer.deserialize/1 restores ISO-8601 values in UTC. Requiring an
  # exact ISO round trip prevents an offset-zone input from being signed in one
  # representation and reobserved in another after durable admission.
  defp canonical_ack_datetime?(%DateTime{} = value) do
    with iso when is_binary(iso) <- DateTime.to_iso8601(value),
         {:ok, restored, 0} <- DateTime.from_iso8601(iso) do
      restored == value
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp canonical_ack_datetime?(_value), do: false

  defp valid_ack_delegation_depth?(nil), do: true

  defp valid_ack_delegation_depth?(depth)
       when is_integer(depth) and depth >= 0 and depth <= 10,
       do: true

  defp valid_ack_delegation_depth?(_), do: false

  defp valid_ack_opt_posint?(nil), do: true

  # Signed-64-bit positive bound: 1 <= value < 2^63. A larger integer would
  # overflow a fixed-width consumption counter on restore.
  defp valid_ack_opt_posint?(value) when is_integer(value),
    do: value > 0 and value < 9_223_372_036_854_775_808

  defp valid_ack_opt_posint?(_), do: false

  defp valid_ack_opt_scalar?(nil), do: true
  defp valid_ack_opt_scalar?(value), do: bounded_exact_scalar?(value)

  defp valid_ack_resource?(value) do
    bounded_exact_scalar?(value) and ack_valid_arbor_uri?(value)
  end

  defp ack_valid_arbor_uri?(uri) do
    case CapabilityUri.parse(uri) do
      {:ok, _parsed} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp valid_ack_delegatees?(nil), do: true

  defp valid_ack_delegatees?(values) when is_list(values),
    do: ack_delegatees_ok?(values, 0)

  defp valid_ack_delegatees?(_), do: false

  # Bounded delegatee walk: count and per-element size bounded incrementally
  # (no length/Enum traversal before bounds).
  defp ack_delegatees_ok?([], _n), do: true

  defp ack_delegatees_ok?([elem | rest], n) when n < @acknowledged_grant_max_delegatees,
    do: bounded_exact_scalar?(elem) and ack_delegatees_ok?(rest, n + 1)

  defp ack_delegatees_ok?(_, _n), do: false

  # OMISSION VS PRESENCE for constraints/metadata: an ABSENT key normalizes to
  # %{}; a PRESENT key must be a non-struct map. An explicitly supplied nil,
  # list, scalar, or struct is invalid (presence is not collapsed into
  # omission). One total node budget is threaded across the two normalized
  # maps so a combined tree cannot exceed @acknowledged_grant_max_nodes.
  # Keyword.fetch/2 is safe here: ack_opts_count_ok?/2 and Keyword.keyword?/1
  # already bounded opts (<= 32, atom-keyed) before this point.
  defp valid_ack_opt_maps?(opts) do
    with {:ok, constraints} <- ack_opt_map(Keyword.fetch(opts, :constraints)),
         {:ok, metadata} <- ack_opt_map(Keyword.fetch(opts, :metadata)),
         {:ok, remaining} <- ack_node(constraints, 0, @acknowledged_grant_max_nodes),
         {:ok, _remaining} <- ack_node(metadata, 0, remaining) do
      true
    else
      _ -> false
    end
  end

  defp ack_opt_map(:error), do: {:ok, %{}}

  defp ack_opt_map({:ok, value}) when is_map(value) and not is_struct(value),
    do: {:ok, value}

  # Present but not a non-struct map: explicit nil/list/scalar/struct.
  defp ack_opt_map({:ok, _present_invalid}), do: :error

  # Single bounded traversal for constraints/metadata trees. Returns
  # {:ok, remaining_node_budget} | :error. Depth increments for maps AND lists;
  # budget is the remaining total-node allowance; per-map/per-list/per-key/
  # binary/integer/finite-float bounds enforced. No length()/Enum traversal
  # before bounds. Rejects structs/tuples/functions/pids (JSON-native only; no
  # executable collaborators).
  defp ack_node(map, depth, budget) when is_map(map) and not is_struct(map) do
    size = map_size(map)

    if depth <= @acknowledged_grant_max_map_depth and size <= @acknowledged_grant_max_map_keys and
         budget > 0 and ack_unique_canonical_keys?(Map.keys(map), MapSet.new()) do
      ack_kv(Map.to_list(map), depth + 1, budget - 1)
    else
      :error
    end
  end

  defp ack_node(list, depth, budget) when is_list(list) do
    if depth <= @acknowledged_grant_max_map_depth and budget > 0 do
      ack_elems(list, depth + 1, budget - 1, 0)
    else
      :error
    end
  end

  defp ack_node(binary, _depth, budget) when is_binary(binary) do
    if byte_size(binary) <= @exact_scalar_max_bytes and String.valid?(binary) and budget > 0 do
      {:ok, budget - 1}
    else
      :error
    end
  end

  defp ack_node(value, _depth, budget) when is_atom(value) do
    encoded = Atom.to_string(value)

    if budget > 0 and byte_size(encoded) <= @exact_scalar_max_bytes and String.valid?(encoded),
      do: {:ok, budget - 1},
      else: :error
  end

  defp ack_node(value, _depth, budget) when is_integer(value) do
    if ack_int_in_bounds?(value) and budget > 0, do: {:ok, budget - 1}, else: :error
  end

  defp ack_node(value, _depth, budget) when is_number(value) do
    if ack_finite?(value) and budget > 0, do: {:ok, budget - 1}, else: :error
  end

  defp ack_node(_other, _depth, _budget), do: :error

  defp ack_kv([], _depth, budget), do: {:ok, budget}

  defp ack_kv([{key, value} | rest], depth, budget) do
    with :ok <- ack_key_ok?(key),
         {:ok, remaining} <- ack_node(value, depth, budget) do
      ack_kv(rest, depth, remaining)
    end
  end

  defp ack_elems([], _depth, budget, _n), do: {:ok, budget}

  defp ack_elems([elem | rest], depth, budget, n) when n < @acknowledged_grant_max_list_len do
    with {:ok, remaining} <- ack_node(elem, depth, budget) do
      ack_elems(rest, depth, remaining, n + 1)
    end
  end

  defp ack_elems(_over_limit, _depth, _budget, _n), do: :error

  defp ack_key_ok?(key) when is_atom(key), do: ack_key_ok?(Atom.to_string(key))

  defp ack_key_ok?(key) when is_binary(key) do
    if byte_size(key) <= @exact_scalar_max_bytes and String.valid?(key) do
      :ok
    else
      :error
    end
  end

  defp ack_key_ok?(_key), do: :error

  defp ack_unique_canonical_keys?([], _seen), do: true

  defp ack_unique_canonical_keys?([key | rest], seen) do
    with {:ok, canonical} <- ack_canonical_key(key),
         false <- MapSet.member?(seen, canonical) do
      ack_unique_canonical_keys?(rest, MapSet.put(seen, canonical))
    else
      _ -> false
    end
  end

  defp ack_canonical_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp ack_canonical_key(key) when is_binary(key), do: {:ok, key}
  defp ack_canonical_key(_key), do: :error

  defp ack_int_in_bounds?(n),
    do: n >= -9_223_372_036_854_775_808 and n < 9_223_372_036_854_775_808

  # Reject NaN and ±Infinity floats (only finite numbers are JSON-native).
  defp ack_finite?(n), do: n * 0.0 == 0.0

  @doc """
  Delegate a capability to another agent.

  Creates a new signed capability derived from an existing one.

  ## Options

  - `:constraints` - Additional constraints to apply
  - `:expires_at` - Override expiration (cannot exceed parent)
  - `:delegator_private_key` - Private key for signing the delegation record
  """
  @spec delegate(String.t(), String.t(), keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def delegate(capability_id, new_principal_id, opts \\ []),
    do: delegate_capability_from_principal_to_principal(capability_id, new_principal_id, opts)

  @doc """
  Delegate matching capabilities from a parent to an agent.

  For each resource URI, finds the parent's authorizing capability and
  creates a signed delegation. Skips resources where the parent has no
  matching capability (logs a warning).

  ## Options

  - `:delegator_private_key` - Private key for signing delegation records (required)
  - `:resources` - List of resource URIs to delegate (required)

  ## Examples

      {:ok, caps} = Security.delegate_to_agent(human_id, agent_id,
        delegator_private_key: key,
        resources: ["arbor://fs/read/**", "arbor://fs/**"]
      )
  """
  @spec delegate_to_agent(String.t(), String.t(), keyword()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def delegate_to_agent(parent_id, agent_id, opts \\ []) do
    private_key = Keyword.fetch!(opts, :delegator_private_key)
    resources = Keyword.get(opts, :resources, [])

    delegated =
      Enum.reduce(resources, [], fn resource_uri, acc ->
        case CapabilityStore.find_authorizing(parent_id, resource_uri) do
          {:ok, parent_cap} ->
            case delegate(parent_cap.id, agent_id, delegator_private_key: private_key) do
              {:ok, delegated_cap} ->
                [delegated_cap | acc]

              {:error, reason} ->
                Logger.warning(
                  "[Security] Failed to delegate #{resource_uri} to #{agent_id}: #{inspect(reason)}"
                )

                acc
            end

          {:error, :not_found} ->
            Logger.warning(
              "[Security] Parent #{parent_id} has no capability for #{resource_uri}, skipping delegation"
            )

            acc
        end
      end)

    {:ok, Enum.reverse(delegated)}
  end

  @doc """
  Assign a role to a principal, granting all capabilities defined in the role.

  Grants are idempotent — capabilities that already exist are skipped.

  ## Options

  - `:delegation_depth` - Delegation depth for granted capabilities (default: 3)

  ## Examples

      {:ok, caps} = Security.assign_role("human_abc123", :admin)
  """
  @spec assign_role(String.t(), atom(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def assign_role(principal_id, role_name, opts \\ []) do
    alias Arbor.Security.Role

    case Role.get(role_name) do
      {:ok, resource_uris} ->
        delegation_depth = Keyword.get(opts, :delegation_depth, 3)

        granted =
          Enum.reduce(resource_uris, [], fn resource_uri, acc ->
            case grant(
                   principal: principal_id,
                   resource: resource_uri,
                   delegation_depth: delegation_depth
                 ) do
              {:ok, cap} ->
                [cap | acc]

              {:error, _reason} ->
                # Idempotent — skip if already granted or other non-fatal error
                acc
            end
          end)

        Logger.info(
          "[Security] Assigned role #{role_name} to #{principal_id} (#{length(granted)} capabilities)"
        )

        {:ok, Enum.reverse(granted)}

      {:error, :unknown_role} = error ->
        error
    end
  end

  @doc "List capabilities for an agent."
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_capabilities(principal_id, opts \\ []),
    do: list_capabilities_for_principal(principal_id, opts)

  @doc """
  Side-effect-free check that a capability can authorize a resource URI.

  This mirrors the non-mutating parts of the authorization matcher for
  enumeration and self-inspection paths: capability validity, scope bindings,
  resource matching, and signature acceptability. It does not emit signals,
  increment usage counters, or revoke max-use capabilities.
  """
  @spec capability_authorizes?(Capability.t(), String.t(), keyword()) :: boolean()
  def capability_authorizes?(capability, resource_uri, opts \\ [])

  def capability_authorizes?(%Capability{} = cap, resource_uri, opts)
      when is_binary(resource_uri) do
    Capability.valid?(cap) and Capability.scope_matches?(cap, scope_context(opts)) and
      Capability.grants_access?(cap, resource_uri) and capability_signature_acceptable?(cap)
  end

  def capability_authorizes?(_capability, _resource_uri, _opts), do: false

  @doc """
  Generate a unique trace ID for request correlation.

  Trace IDs link authorization, verification, and delegation events
  across a single request. Generate at the request boundary and pass
  as `trace_id: id` in authorize opts.
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    "trace_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp scope_context(opts) do
    []
    |> maybe_put_scope(:session_id, Keyword.get(opts, :session_id))
    |> maybe_put_scope(:task_id, Keyword.get(opts, :task_id))
    |> maybe_put_scope(:principal_scope, Keyword.get(opts, :principal_scope))
  end

  defp maybe_put_scope(scope, _key, nil), do: scope
  defp maybe_put_scope(scope, key, value), do: Keyword.put(scope, key, value)

  defp capability_signature_acceptable?(%Capability{} = cap) do
    cond do
      Capability.signed?(cap) ->
        SystemAuthority.verify_capability_signature(cap) == :ok

      Config.capability_signing_required?() ->
        false

      true ->
        true
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # ===========================================================================
  # Public API — Identity (short names)
  # ===========================================================================

  @doc """
  Generate a new cryptographic identity.

  ## Examples

      {:ok, identity} = Arbor.Security.generate_identity()
      identity.agent_id
      #=> "agent_a1b2c3..."
  """
  @spec generate_identity(keyword()) :: {:ok, Identity.t()} | {:error, term()}
  def generate_identity(opts \\ []),
    do: generate_cryptographic_identity_keypair(opts)

  @doc """
  Register an agent's self-certifying identity (public key).

  Ordinary registration accepts `agent_` identities only. First registration
  of a `human_` identity requires `register_oidc_identity/3` with the original
  signed ID token and provider configuration.

  ## Examples

      :ok = Arbor.Security.register_identity(identity)
  """
  @spec register_identity(Identity.t()) :: :ok | {:error, term()}
  def register_identity(identity),
    do: register_agent_identity_with_public_key(identity)

  @doc """
  Register a human identity from cryptographically verified OIDC provenance.

  The identity registry re-verifies the original signed ID token against the
  provider configuration, derives the expected human ID from verified
  `iss:sub`, and requires an exact match before registration. Decoded claims
  alone are not accepted.
  """
  @spec register_oidc_identity(Identity.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def register_oidc_identity(identity, id_token, provider_config) do
    public_identity = Identity.public_only(identity)

    case Registry.register_oidc(public_identity, id_token, provider_config) do
      :ok ->
        Events.record_identity_registered(public_identity.agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  rescue
    _ -> {:error, :invalid_oidc_registration}
  catch
    :exit, _ -> {:error, :registration_unavailable}
  end

  @doc """
  Remove an agent's identity from the registry.
  """
  @spec deregister_identity(String.t()) :: :ok | {:error, term()}
  def deregister_identity(agent_id) when is_binary(agent_id) do
    Registry.deregister(agent_id)
  end

  @doc """
  Look up the public key for an agent.
  """
  @spec lookup_public_key(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def lookup_public_key(agent_id),
    do: lookup_public_key_for_agent(agent_id)

  @doc """
  Look up the signing public key for an agent.

  Signals identity-key port (`Arbor.Signals.Contracts.IdentityKeys.lookup/1`).
  """
  @impl Arbor.Signals.Contracts.IdentityKeys
  @spec lookup(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def lookup(agent_id), do: Registry.lookup(agent_id)

  @doc """
  Look up the encryption public key for an agent.

  Signals identity-key port (`Arbor.Signals.Contracts.IdentityKeys`).
  """
  @impl Arbor.Signals.Contracts.IdentityKeys
  @spec lookup_encryption_key(String.t()) ::
          {:ok, binary()} | {:error, :not_found | :no_encryption_key}
  def lookup_encryption_key(agent_id), do: Registry.lookup_encryption_key(agent_id)

  @doc """
  Generate an X25519 encryption keypair.

  Signals crypto port (`Arbor.Signals.Contracts.Crypto`).
  """
  @impl Arbor.Signals.Contracts.Crypto
  @spec generate_encryption_keypair() :: {binary(), binary()}
  def generate_encryption_keypair, do: Crypto.generate_encryption_keypair()

  @doc """
  Encrypt plaintext with AES-256-GCM.

  Signals crypto port (`Arbor.Signals.Contracts.Crypto`).
  """
  @impl Arbor.Signals.Contracts.Crypto
  @spec encrypt(binary(), binary()) :: {binary(), binary(), binary()}
  def encrypt(plaintext, key), do: Crypto.encrypt(plaintext, key)

  @doc """
  Decrypt ciphertext with AES-256-GCM.

  Signals crypto port (`Arbor.Signals.Contracts.Crypto`).
  """
  @impl Arbor.Signals.Contracts.Crypto
  @spec decrypt(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(ciphertext, key, iv, tag), do: Crypto.decrypt(ciphertext, key, iv, tag)

  @doc """
  Seal a message for a recipient.

  Signals crypto port (`Arbor.Signals.Contracts.Crypto`).
  """
  @impl Arbor.Signals.Contracts.Crypto
  @spec seal(binary(), binary(), binary()) :: map()
  def seal(plaintext, recipient_public, sender_sign_private),
    do: Crypto.seal(plaintext, recipient_public, sender_sign_private)

  @doc """
  Unseal a message sealed with `seal/3`.

  Signals crypto port (`Arbor.Signals.Contracts.Crypto`).
  """
  @impl Arbor.Signals.Contracts.Crypto
  @spec unseal(map(), binary(), binary()) ::
          {:ok, binary()} | {:error, :bad_signature | :decryption_failed | :malformed_sealed}
  def unseal(sealed, recipient_private, sender_sign_public),
    do: Crypto.unseal(sealed, recipient_private, sender_sign_public)

  @doc """
  Look up principal IDs by identity display name for discovery only.

  Display names are non-unique and explicitly non-authoritative. Never use a
  name or the ordering of returned IDs for authentication or authorization;
  continue with an exact principal ID selected by the caller.
  """
  @spec lookup_identity_ids_by_display_name(String.t()) ::
          {:ok, [String.t()]} | {:error, :invalid_name | :not_found | :registry_unavailable}
  def lookup_identity_ids_by_display_name(name) do
    lookup_non_authoritative_principal_ids_by_identity_display_name(name)
  end

  @doc """
  Verify a signed request's authenticity.
  """
  @spec verify_request(term()) :: {:ok, String.t()} | {:error, atom()}
  def verify_request(signed_request),
    do: verify_signed_request_authenticity(signed_request)

  # ===========================================================================
  # Public API — Identity Lifecycle (short names)
  # ===========================================================================

  @doc """
  Suspend an agent's identity.

  Sets the identity status to `:suspended`. Suspended identities cannot
  be used for lookups or authorization but can be resumed later.

  ## Options

  - `:reason` - Optional reason for suspension

  ## Examples

      :ok = Arbor.Security.suspend_identity("agent_001", reason: "Suspicious activity")
  """
  @spec suspend_identity(String.t(), keyword()) :: :ok | {:error, term()}
  def suspend_identity(agent_id, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    case Registry.suspend(agent_id, reason) do
      :ok ->
        Events.record_identity_suspended(agent_id, reason)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Resume a suspended identity.

  Sets the identity status back to `:active`. Only works for `:suspended`
  identities — revoked identities cannot be resumed.

  ## Examples

      :ok = Arbor.Security.resume_identity("agent_001")
  """
  @spec resume_identity(String.t()) :: :ok | {:error, term()}
  def resume_identity(agent_id) do
    case Registry.resume(agent_id) do
      :ok ->
        Events.record_identity_resumed(agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Revoke an agent's identity.

  Sets the identity status to `:revoked` (terminal state). This also
  revokes all capabilities held by the agent. The identity entry remains
  for audit trail purposes.

  ## Options

  - `:reason` - Optional reason for revocation

  ## Examples

      :ok = Arbor.Security.revoke_identity("agent_001", reason: "Account compromised")
  """
  @spec revoke_identity(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke_identity(agent_id, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    case Registry.revoke_identity(agent_id, reason) do
      {:ok, cascade_count} ->
        Events.record_identity_revoked(agent_id, reason, cascade_count)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get the current status of an identity.

  ## Examples

      {:ok, :active} = Arbor.Security.identity_status("agent_001")
      {:ok, :suspended} = Arbor.Security.identity_status("agent_002")
  """
  @spec identity_status(String.t()) :: {:ok, Identity.status()} | {:error, :not_found}
  def identity_status(agent_id) do
    Registry.identity_status(agent_id)
  end

  @doc """
  Check if an identity is active.

  Returns `true` only if the identity exists AND has status `:active`.

  ## Examples

      true = Arbor.Security.identity_active?("agent_001")
      false = Arbor.Security.identity_active?("suspended_agent")
  """
  @spec identity_active?(String.t()) :: boolean()
  def identity_active?(agent_id) do
    Registry.active?(agent_id)
  end

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl Arbor.Contracts.API.Security
  # Private absence sentinel for session_token extraction — never nil.
  @session_token_absent :__session_token_absent__
  @max_session_token_bytes 4096

  def check_if_principal_has_capability_for_resource_action(
        principal_id,
        resource_uri,
        action,
        opts
      ) do
    # If the caller passed `:file_path` and the URI is the bare
    # `arbor://fs/<op>` form, synthesize the path-embedded URI for
    # cap lookup. Without this, path-scoped caps like
    # `arbor://fs/read/Users/azmaveth/.arbor/reports/upstream-deps/**`
    # don't match the action's bare URI. With this synthesis, the per-run cap
    # matches via the shared capability URI wildcard matcher and AuthDecision
    # returns `:authorized` without the approval detour.
    # FileGuard still runs in `maybe_check_file_guard/4` as
    # defense-in-depth path normalization. Surfaced 2026-06-06 by the
    # morning-digest pipelines hitting the gate when run via the
    # per-run identity flow.
    #
    # Session tokens are extracted and redacted before URI normalize, reflexes,
    # AuthContext construction, or any event/receipt/escalation work so the raw
    # credential never reaches those surfaces.
    requested_resource_uri = resource_uri

    with {:ok, opts} <- validate_exact_capability_option(opts) do
      case extract_session_token(opts) do
        {:error, reason, safe_opts} ->
          Events.record_authorization_denied(
            principal_id,
            requested_resource_uri,
            reason,
            safe_opts
          )

          {:error, reason}

        {:ok, proof, safe_opts} ->
          decision_opts =
            case proof do
              @session_token_absent -> safe_opts
              token when is_binary(token) -> Keyword.put(safe_opts, :session_token, token)
            end

          with {:ok, resource_uri} <-
                 normalize_authorization_resource_uri(resource_uri, safe_opts),
               reflex_context = build_reflex_context(resource_uri, action, safe_opts),
               :ok <-
                 check_reflexes(principal_id, reflex_context, resource_uri, action, safe_opts) do
            auth = build_auth_context(principal_id, safe_opts)

            case AuthDecision.evaluate(auth, resource_uri, action, decision_opts) do
              {:ok, :authorized, cap, auth} ->
                handle_authorized(cap, auth, principal_id, resource_uri, action, safe_opts)

              {:ok, :requires_approval, cap, auth} ->
                handle_requires_approval(cap, auth, principal_id, resource_uri, action, safe_opts)

              {:error, reason, _auth} ->
                Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
                {:error, reason}
            end
          else
            {:error, reason} = error ->
              Events.record_authorization_denied(
                principal_id,
                requested_resource_uri,
                reason,
                safe_opts
              )

              error
          end
      end
    else
      {:error, reason} ->
        Events.record_authorization_denied(principal_id, requested_resource_uri, reason, [])
        {:error, reason}
    end
  end

  defp validate_exact_capability_option(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :exact_capability_id) do
        [] ->
          {:ok, opts}

        [id] when is_binary(id) ->
          with true <- canonical_exact_capability_id?(id),
               :ok <- validate_exact_scope_option_keys(opts) do
            {:ok, opts}
          else
            false -> {:error, :invalid_exact_capability_id}
            {:error, _} = error -> error
          end

        _ ->
          {:error, :invalid_exact_capability_id}
      end
    else
      if exact_capability_intent?(opts),
        do: {:error, :invalid_exact_capability_id},
        else: {:ok, opts}
    end
  rescue
    _ -> {:error, :invalid_exact_capability_id}
  catch
    :exit, _ -> {:error, :invalid_exact_capability_id}
    :throw, _ -> {:error, :invalid_exact_capability_id}
  end

  defp validate_exact_capability_option(opts) do
    if exact_capability_intent?(opts),
      do: {:error, :invalid_exact_capability_id},
      else: {:ok, opts}
  rescue
    _ -> {:error, :invalid_exact_capability_id}
  catch
    :exit, _ -> {:error, :invalid_exact_capability_id}
    :throw, _ -> {:error, :invalid_exact_capability_id}
  end

  defp exact_capability_intent?(opts) when is_list(opts) do
    Enum.any?(opts, &exact_capability_intent_entry?/1)
  end

  defp exact_capability_intent?(opts) when is_map(opts) do
    Map.has_key?(opts, :exact_capability_id) or Map.has_key?(opts, "exact_capability_id")
  end

  defp exact_capability_intent?({key, _value})
       when key in [:exact_capability_id, "exact_capability_id"],
       do: true

  defp exact_capability_intent?(_opts), do: false

  defp exact_capability_intent_entry?({key, _value})
       when key in [:exact_capability_id, "exact_capability_id"],
       do: true

  defp exact_capability_intent_entry?(_entry), do: false

  defp canonical_exact_capability_id?("cap_" <> suffix)
       when byte_size(suffix) == 32 do
    Regex.match?(~r/\A[0-9a-f]{32}\z/, suffix)
  end

  defp canonical_exact_capability_id?(_id), do: false

  defp validate_exact_scope_option_keys(opts) do
    if Enum.all?([:session_id, :task_id, :principal_scope], fn key ->
         length(Keyword.get_values(opts, key)) <= 1
       end) do
      :ok
    else
      {:error, :invalid_exact_capability_scope}
    end
  rescue
    _ -> {:error, :invalid_exact_capability_scope}
  catch
    :exit, _ -> {:error, :invalid_exact_capability_scope}
    :throw, _ -> {:error, :invalid_exact_capability_scope}
  end

  # Extract every :session_token entry before any downstream work. Absence is a
  # private sentinel; present nil/empty/non-binary/oversized/duplicate values
  # fail closed and never fall back to "no proof".
  defp extract_session_token(opts) when is_list(opts) do
    try do
      if Keyword.keyword?(opts) do
        values = Keyword.get_values(opts, :session_token)
        safe_opts = Keyword.delete(opts, :session_token)

        case values do
          [] ->
            {:ok, @session_token_absent, safe_opts}

          [token]
          when is_binary(token) and byte_size(token) > 0 and
                 byte_size(token) <= @max_session_token_bytes ->
            {:ok, token, safe_opts}

          [_invalid] ->
            {:error, :invalid_session_token, safe_opts}

          _duplicates ->
            {:error, :invalid_session_token, safe_opts}
        end
      else
        {:ok, @session_token_absent, opts}
      end
    rescue
      _ -> {:error, :invalid_session_token, []}
    catch
      :exit, _ -> {:error, :invalid_session_token, []}
    end
  end

  defp extract_session_token(opts), do: {:ok, @session_token_absent, opts}

  # Side effects for authorized decisions
  defp handle_authorized(cap, _auth, principal_id, resource_uri, action, opts) do
    safe_opts = Keyword.delete(opts, @source_owned_egress_opt)

    # Stateful constraint checks (rate limiting) — cap was already found by AuthDecision
    with :ok <- enforce_source_owned_egress_expectation(cap, opts),
         :ok <-
           if(cap, do: maybe_enforce_constraints(cap, principal_id, resource_uri), else: :ok) do
      # FileGuard for fs:// URIs — runs explicit (caller passed :file_path)
      # OR implicit (we have a matched cap and the URI's path-part is the
      # implicit file_path) defense-in-depth normalization.
      file_guard_result = maybe_check_file_guard(principal_id, resource_uri, safe_opts, cap)

      case normalize_file_guard_result(file_guard_result) do
        :ok ->
          Events.record_authorization_granted(principal_id, resource_uri, safe_opts)
          if cap, do: maybe_check_max_uses(cap)

          if cap,
            do: maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, safe_opts)

          {:ok, :authorized}

        {:error, reason} ->
          Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
        error
    end
  end

  defp enforce_source_owned_egress_expectation(nil, _opts), do: :ok

  defp enforce_source_owned_egress_expectation(cap, opts) do
    case Keyword.get(opts, @source_owned_egress_opt, :absent) do
      :absent ->
        :ok

      nil ->
        :ok

      expectation when is_map(expectation) ->
        if exact_egress_constraint?(cap, expectation),
          do: :ok,
          else: {:error, :exact_egress_constraint_mismatch}

      _invalid ->
        {:error, :invalid_exact_egress_expectation}
    end
  end

  # Side effects for requires_approval decisions
  defp handle_requires_approval(cap, _auth, principal_id, resource_uri, action, opts) do
    safe_opts = Keyword.delete(opts, @source_owned_egress_opt)

    # Escalate to Consensus for kernel-owned capability constraints. Trust policy
    # approval lives in Arbor.Trust.ApprovalGuard.
    escalation_opts =
      safe_opts
      |> Keyword.put_new(:gate, :capability_constraint)
      |> Keyword.put_new(:reason, :capability_requires_approval)

    with :ok <- enforce_source_owned_egress_expectation(cap, opts) do
      case Arbor.Security.Escalation.maybe_escalate(
             cap,
             principal_id,
             resource_uri,
             escalation_opts
           ) do
        :ok ->
          # Graduated — still enforce constraints (rate limits, time windows)
          # AND run the implicit FileGuard normalization for fs URIs. The
          # approval-graduated path is structurally just another success
          # path and needs the same path-normalization defense as
          # handle_authorized — otherwise an fs cap with requires_approval
          # silently skips symlink-escape detection.
          with :ok <- maybe_enforce_constraints(cap, principal_id, resource_uri),
               fg_result <- maybe_check_file_guard(principal_id, resource_uri, safe_opts, cap),
               :ok <- normalize_file_guard_result(fg_result) do
            Events.record_authorization_granted(principal_id, resource_uri, safe_opts)
            maybe_check_max_uses(cap)
            maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, safe_opts)
            {:ok, :authorized}
          else
            {:error, reason} = error ->
              Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
              error
          end

        {:ok, :pending_approval, proposal_id} ->
          Events.record_authorization_pending(principal_id, resource_uri, proposal_id, safe_opts)

          maybe_emit_receipt(
            cap,
            principal_id,
            resource_uri,
            action,
            :pending_approval,
            safe_opts
          )

          {:ok, :pending_approval, proposal_id}

        {:error, reason} ->
          Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
        error
    end
  end

  defp build_auth_context(principal_id, opts) do
    alias Arbor.Contracts.Security.AuthContext

    ctx =
      AuthContext.new(principal_id,
        signed_request: Keyword.get(opts, :signed_request),
        signer: Keyword.get(opts, :signer),
        session_id: Keyword.get(opts, :session_id)
      )
      |> populate_store_capabilities()

    # `identity_verified: true` is set by callers that have ALREADY verified the
    # signer's per-request signature upstream (e.g. the Gateway's
    # SignedRequestAuth, which also consumed the single-use nonce). It marks the
    # context verified so AuthDecision skips re-verification — re-running it would
    # trip the nonce replay guard. Only set this after a genuine upstream verify.
    if Keyword.get(opts, :identity_verified, false),
      do: AuthContext.mark_verified(ctx),
      else: ctx
  end

  defp populate_store_capabilities(%{capabilities: []} = ctx) do
    case CapabilityStore.list_for_principal(ctx.principal_id) do
      {:ok, caps} when is_list(caps) -> %{ctx | capabilities: caps}
      _ -> ctx
    end
  rescue
    _ -> ctx
  catch
    :exit, _ -> ctx
  end

  defp populate_store_capabilities(ctx), do: ctx

  # Look up capability for side-effect operations (max_uses, receipt).
  @impl Arbor.Contracts.API.Security
  def grant_capability_to_principal_for_resource(opts) do
    principal_id = Keyword.fetch!(opts, :principal)
    resource_uri = Keyword.fetch!(opts, :resource)

    case Capability.new(
           resource_uri: resource_uri,
           principal_id: principal_id,
           expires_at: Keyword.get(opts, :expires_at),
           not_before: Keyword.get(opts, :not_before),
           constraints: Keyword.get(opts, :constraints, %{}),
           delegation_depth: Keyword.get(opts, :delegation_depth, 3),
           max_uses: Keyword.get(opts, :max_uses),
           allowed_delegatees: Keyword.get(opts, :allowed_delegatees),
           session_id: Keyword.get(opts, :session_id),
           task_id: Keyword.get(opts, :task_id),
           principal_scope: Keyword.get(opts, :principal_scope),
           metadata: Keyword.get(opts, :metadata, %{})
         ) do
      {:ok, cap} ->
        {:ok, signed_cap} = SystemAuthority.sign_capability(cap)

        case CapabilityStore.put(signed_cap) do
          {:ok, :stored} ->
            Events.record_capability_granted(signed_cap)
            {:ok, signed_cap}

          {:error, _} = error ->
            error
        end

      error ->
        error
    end
  end

  @impl Arbor.Contracts.API.Security
  def revoke_capability_by_id(capability_id, _opts) do
    case CapabilityStore.revoke(capability_id) do
      :ok ->
        Events.record_capability_revoked(capability_id)
        :ok

      error ->
        error
    end
  end

  @impl Arbor.Contracts.API.Security
  def list_capabilities_for_principal(principal_id, opts) do
    CapabilityStore.list_for_principal(principal_id, opts)
  end

  @impl Arbor.Contracts.API.Security
  def delegate_capability_from_principal_to_principal(capability_id, new_principal_id, opts) do
    with {:ok, parent_cap} <- CapabilityStore.get(capability_id),
         delegator_private_key = Keyword.fetch!(opts, :delegator_private_key),
         # Create the delegated capability once (without delegation record)
         {:ok, new_cap} <-
           Capability.delegate(parent_cap, new_principal_id,
             constraints: Keyword.get(opts, :constraints, %{}),
             expires_at: Keyword.get(opts, :expires_at)
           ),
         # Sign a delegation record over the new cap's payload
         delegation_record =
           Signer.sign_delegation(parent_cap, new_cap, delegator_private_key),
         # Attach the chain to the SAME capability (preserving id/timestamps)
         new_cap_with_chain = %{
           new_cap
           | delegation_chain: parent_cap.delegation_chain ++ [delegation_record]
         },
         # Sign the new capability with system authority
         {:ok, signed_cap} <- SystemAuthority.sign_capability(new_cap_with_chain),
         # Store with quota enforcement
         {:ok, :stored} <- CapabilityStore.put(signed_cap) do
      Events.record_capability_granted(signed_cap)
      Events.record_delegation_created(parent_cap.principal_id, new_principal_id, signed_cap.id)
      {:ok, signed_cap}
    end
  end

  # ===========================================================================
  # Identity contract implementations
  # ===========================================================================

  @impl Arbor.Contracts.API.Identity
  def generate_cryptographic_identity_keypair(opts) do
    Identity.generate(opts)
  end

  @impl Arbor.Contracts.API.Identity
  def register_agent_identity_with_public_key(%Identity{} = identity) do
    case Registry.register(Identity.public_only(identity)) do
      :ok ->
        Events.record_identity_registered(identity.agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @impl Arbor.Contracts.API.Identity
  def lookup_public_key_for_agent(agent_id) do
    Registry.lookup(agent_id)
  end

  @impl Arbor.Contracts.API.Identity
  def lookup_non_authoritative_principal_ids_by_identity_display_name(name)
      when is_binary(name) do
    if String.trim(name) == "" do
      {:error, :invalid_name}
    else
      Registry.lookup_by_name(name)
    end
  catch
    :exit, _ -> {:error, :registry_unavailable}
  end

  def lookup_non_authoritative_principal_ids_by_identity_display_name(_name),
    do: {:error, :invalid_name}

  @impl Arbor.Contracts.API.Identity
  def verify_signed_request_authenticity(request) do
    with {:ok, canonical} <- canonicalize_signed_request(request) do
      case Verifier.verify(canonical) do
        {:ok, agent_id} = success ->
          record_verification_success(canonical, agent_id)
          success

        {:error, reason} = error ->
          record_verification_failure(canonical, reason)
          error
      end
    end
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_unavailable}
  end

  defp canonicalize_signed_request(request) do
    case SignedRequest.canonicalize(request) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :malformed_request}
    end
  end

  defp record_verification_success(request, agent_id) do
    Events.record_identity_verification_succeeded(agent_id,
      signature: Base.encode64(request.signature),
      payload_hash: Base.encode16(:crypto.hash(:sha256, request.payload), case: :lower),
      nonce: Base.encode64(request.nonce),
      signed_at: DateTime.to_iso8601(request.timestamp)
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp record_verification_failure(request, reason) do
    Events.record_identity_verification_failed(request.agent_id, reason,
      nonce: Base.encode64(request.nonce),
      signed_at: DateTime.to_iso8601(request.timestamp)
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the security system.

  Normally started automatically by the application supervisor.
  """
  @impl Arbor.Contracts.API.Security
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Security.Application.start(:normal, opts)
  end

  @doc """
  Check if the security system is healthy.
  """
  @impl Arbor.Contracts.API.Security
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(CapabilityStore) != nil and
      Process.whereis(Registry) != nil and
      Process.whereis(Arbor.Security.Identity.NonceCache) != nil and
      Process.whereis(SystemAuthority) != nil and
      Process.whereis(RateLimiter) != nil and
      Process.whereis(Arbor.Security.Reflex.Registry) != nil
  end

  @doc """
  Get system statistics.
  """
  @spec stats() :: map()
  def stats do
    system_authority_id =
      if Process.whereis(SystemAuthority),
        do: SystemAuthority.agent_id(),
        else: nil

    rate_limiter_stats =
      if Process.whereis(RateLimiter),
        do: RateLimiter.stats(),
        else: %{bucket_count: 0, buckets: %{}}

    %{
      capabilities: CapabilityStore.stats(),
      identities: Registry.stats(),
      rate_limiter: rate_limiter_stats,
      system_authority_id: system_authority_id,
      healthy: healthy?()
    }
  end

  # ===========================================================================
  # Reflex System (Seed/Host Phase 4)
  # ===========================================================================

  @doc """
  Check context against all active reflexes.

  Returns `:ok`, `{:blocked, reflex, reason}`, or `{:warned, warnings}`.
  """
  defdelegate check_reflex(context), to: Reflex, as: :check

  @doc """
  Returns the canonical `arbor://` URI prefixes the registry recognizes.

  Pure (reads the compile-time prefix list) — usable without the registry
  GenServer running. Exposed for tooling such as the Security Sentinel's
  URI-registration-coverage detector.
  """
  defdelegate canonical_uri_prefixes(), to: UriRegistry, as: :canonical_prefixes

  @doc "Return whether a URI matches a canonical or runtime-registered prefix."
  @spec uri_registered?(String.t()) :: boolean()
  defdelegate uri_registered?(uri), to: UriRegistry, as: :registered?

  @doc "Register an additional runtime URI prefix."
  @spec register_uri_prefix(String.t()) :: :ok | {:error, term()}
  defdelegate register_uri_prefix(prefix), to: UriRegistry, as: :register

  # ===========================================================================
  # Keychain (Seed/Host Phase 4)
  # ===========================================================================

  @doc """
  Endorse an agent's identity by signing their public key with the system authority.
  """
  defdelegate endorse_agent(identity), to: SystemAuthority

  @doc """
  Verify an agent endorsement signed by the system authority.
  """
  defdelegate verify_agent_endorsement(endorsement), to: SystemAuthority

  @doc """
  Create a new keychain for an agent (signing + encryption keypairs).
  """
  defdelegate new_keychain(agent_id), to: Keychain, as: :new

  # ===========================================================================
  # Signing Key Storage
  # ===========================================================================

  @doc """
  Store an agent's signing private key (encrypted at rest).

  Called during agent creation to persist the Ed25519 private key.
  The key is encrypted with AES-256-GCM using a master key.
  """
  defdelegate store_signing_key(agent_id, private_key), to: SigningKeyStore, as: :put

  @doc """
  Load an agent's signing private key.

  Returns `{:ok, private_key}` or `{:error, :no_signing_key}`.
  """
  defdelegate load_signing_key(agent_id), to: SigningKeyStore, as: :get

  @doc """
  Check whether an agent's encrypted signing key is available for use.

  Returns only a bounded readiness result. Decrypted key material and storage
  records are never returned, and this operation does not mutate key state.
  """
  @spec signing_key_status(String.t()) ::
          {:ok, :available}
          | {:error,
             :invalid_principal | :store_unavailable | :no_signing_key | :invalid_key_material}
  def signing_key_status(agent_id), do: SigningKeyStore.status(agent_id)

  @doc """
  Delete an agent's signing key.

  Called during agent destruction.
  """
  defdelegate delete_signing_key(agent_id), to: SigningKeyStore, as: :delete

  @doc """
  Create a signer function for an agent.

  ## Legacy migration surface

  Prefer `build_signing_authority_acquisition_proof/3` +
  `open_signing_authority/1` + `sign_with_authority/2` for new code.
  Closures over private keys do not survive module reload and keep decrypted
  key material in caller process state. This function is retained for
  compatibility with callers not yet migrated (Engine, Session, OIDC, CLI,
  scheduler, heartbeat, CodingTaskExecutor). Behavior is unchanged.

  Returns a function that closes over the agent_id and private_key,
  producing a fresh SignedRequest for any given payload. The orchestrator
  receives this function — never the raw private key.

  ## Example

      {:ok, signer} = Arbor.Security.make_signer(agent_id, private_key)
      {:ok, signed} = signer.("arbor://fs/read")
  """
  @spec make_signer(String.t(), binary()) ::
          (binary() -> {:ok, SignedRequest.t()} | {:error, term()})
  def make_signer(agent_id, private_key)
      when is_binary(agent_id) and is_binary(private_key) do
    fn payload -> SignedRequest.sign(payload, agent_id, private_key) end
  end

  # ===========================================================================
  # Signing Authority (reload-stable)
  # ===========================================================================

  @doc """
  Transitional helper: build a one-shot SignedRequest possession proof for
  opening a signing authority.

  Callers that already hold the principal private key (pre-migration
  surfaces) prove cryptographic possession without the broker retaining the
  key, a signer callback, MFA, or the proof itself. The proof payload is a
  fixed canonical acquisition binding of principal, purpose, and owner
  process. It is single-use via NonceCache (freshness + replay defense run
  through the normal Security SignedRequest verifier).

  ## Options

  - `:purpose` (required) — open-time purpose label (`:session`, `:heartbeat`, …).
    Booleans and blank/whitespace-only values are rejected.
  - `:owner` (optional, default `self()`) — process that will call
    `open_signing_authority/1`. Must be the same PID that later opens; the
    broker infers owner from the GenServer caller and rejects substitution.

  ## Example

      {:ok, proof} =
        Arbor.Security.build_signing_authority_acquisition_proof(
          agent_id,
          private_key,
          purpose: :session,
          owner: self()
        )

      {:ok, authority} = Arbor.Security.open_signing_authority(proof)
  """
  @spec build_signing_authority_acquisition_proof(String.t(), binary(), keyword() | map()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def build_signing_authority_acquisition_proof(agent_id, private_key, opts \\ [])

  def build_signing_authority_acquisition_proof(agent_id, private_key, opts)
      when is_binary(agent_id) and (is_list(opts) or is_map(opts)) do
    with :ok <- SigningAuthorityValidator.validate_principal_id(agent_id),
         :ok <- validate_private_key_for_authority(private_key),
         {:ok, normalized_opts} <-
           SigningAuthorityValidator.extract_attributes(opts, [:purpose, :owner]),
         {:ok, purpose} <- fetch_acquisition_purpose(normalized_opts),
         :ok <- validate_authority_purpose(purpose),
         owner = Map.get(normalized_opts, :owner, self()),
         :ok <- validate_owner_pid(owner) do
      payload = SigningAuthorityBroker.acquisition_payload(agent_id, purpose, owner)
      sign_acquisition_proof(payload, agent_id, private_key)
    end
  end

  def build_signing_authority_acquisition_proof(_agent_id, _private_key, _opts) do
    {:error, :invalid_acquisition_proof_args}
  end

  @doc """
  Issue an opaque restart slot from an owner-bound possession proof.

  Issuance verifies the proof through the standard replay-protected verifier,
  requires the caller to be the owner PID bound into the proof, and confirms
  that the active principal has a persistent signing key. The returned value
  is not itself a signing authority and expires if it remains unclaimed.

  This API never accepts a principal id in place of a proof and never returns
  or loads a private key for the caller.

  ## Options

  - `:grace_ms` — positive slot grace in milliseconds. Defaults to Security
    configuration and is capped at the broker's conservative timer maximum.

  Unknown, duplicate, string-keyed, or mixed-key options fail closed before
  the possession proof is verified, so they do not consume its nonce.
  """
  @spec issue_signing_authority_bootstrap(SignedRequest.t(), keyword() | map()) ::
          {:ok, SigningAuthorityBootstrap.t()}
          | {:error, SecurityContract.signing_authority_bootstrap_error()}
  def issue_signing_authority_bootstrap(proof, opts \\ []) do
    issue_signing_authority_bootstrap_from_owner_bound_possession_proof(proof, opts)
  end

  @impl Arbor.Contracts.API.Security
  def issue_signing_authority_bootstrap_from_owner_bound_possession_proof(
        %SignedRequest{} = proof,
        opts
      )
      when is_list(opts) or is_map(opts) do
    SigningAuthorityBroker.issue_bootstrap(proof, opts)
  end

  def issue_signing_authority_bootstrap_from_owner_bound_possession_proof(
        %SignedRequest{},
        _opts
      ) do
    {:error, :invalid_options}
  end

  def issue_signing_authority_bootstrap_from_owner_bound_possession_proof(_proof, _opts) do
    {:error, :possession_proof_required}
  end

  @doc """
  Claim a bootstrap slot for the calling process.

  The broker infers and monitors the owner from the GenServer caller. A slot
  permits one live authority. After owner death a persistent-backed slot may
  be reclaimed during its configured grace period, producing a new authority
  bearer token.
  """
  @spec claim_signing_authority(SigningAuthorityBootstrap.t()) ::
          {:ok, SigningAuthority.t()}
          | {:error, SecurityContract.signing_authority_bootstrap_error()}
  def claim_signing_authority(bootstrap) do
    claim_signing_authority_from_bootstrap_for_calling_process(bootstrap)
  end

  @impl Arbor.Contracts.API.Security
  def claim_signing_authority_from_bootstrap_for_calling_process(bootstrap) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, canonical} -> SigningAuthorityBroker.claim_bootstrap(canonical)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Close a bootstrap slot and any live authority claimed from it.
  """
  @spec close_signing_authority_bootstrap(SigningAuthorityBootstrap.t()) ::
          :ok | {:error, SecurityContract.signing_authority_bootstrap_error()}
  def close_signing_authority_bootstrap(bootstrap) do
    close_signing_authority_bootstrap_and_active_authority(bootstrap)
  end

  @impl Arbor.Contracts.API.Security
  def close_signing_authority_bootstrap_and_active_authority(bootstrap) do
    case SigningAuthorityBootstrap.canonicalize(bootstrap) do
      {:ok, canonical} -> SigningAuthorityBroker.close_bootstrap(canonical)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Open a caller-owned ephemeral signing authority.

  Requires an owner-bound possession proof and the matching private key. The
  broker verifies the supplied key against the proof principal's registered
  public identity, wraps it only in broker memory, and never writes it to the
  persistent signing-key store. Broker or owner death invalidates the result.

  Decryption is scoped to individual sign/derive calls; BEAM zeroization is
  not claimed.
  """
  @spec open_ephemeral_signing_authority(SignedRequest.t(), binary()) ::
          {:ok, SigningAuthority.t()}
          | {:error, SecurityContract.signing_authority_acquisition_error()}
  def open_ephemeral_signing_authority(proof, private_key) do
    open_ephemeral_signing_authority_from_owner_bound_proof_and_private_key(
      proof,
      private_key
    )
  end

  @impl Arbor.Contracts.API.Security
  def open_ephemeral_signing_authority_from_owner_bound_proof_and_private_key(
        %SignedRequest{} = proof,
        private_key
      ) do
    SigningAuthorityBroker.open_ephemeral(proof, private_key)
  end

  def open_ephemeral_signing_authority_from_owner_bound_proof_and_private_key(
        _proof,
        _private_key
      ) do
    {:error, :possession_proof_required}
  end

  @doc """
  Open a reload-stable signing authority after verifying a possession proof.

  **Acquisition invariant:** this API does not accept an `agent_id` alone.
  Any in-process caller that only knows a stored identity's id must not be
  able to obtain a usable bearer lease. Callers must present a one-shot
  `SignedRequest` produced by `build_signing_authority_acquisition_proof/3`
  (or an equivalent signature over the same canonical payload).

  Returns an opaque `SigningAuthority` reference (broker bearer token +
  principal/purpose binding). The broker monitors the GenServer caller as
  owner and revokes the token on process death. Decrypted private keys and
  the acquisition proof are never retained in broker state.

  ## Example

      {:ok, proof} =
        Arbor.Security.build_signing_authority_acquisition_proof(
          agent_id,
          private_key,
          purpose: :session
        )

      {:ok, authority} = Arbor.Security.open_signing_authority(proof)
      {:ok, signed} = Arbor.Security.sign_with_authority(authority, "arbor://fs/read")
  """
  @spec open_signing_authority(SignedRequest.t()) ::
          {:ok, SigningAuthority.t()}
          | {:error, SecurityContract.signing_authority_acquisition_error()}
  def open_signing_authority(%SignedRequest{} = proof) do
    SigningAuthorityBroker.open(proof)
  end

  # Fail closed: agent_id alone (with or without opts) is never sufficient.
  # Kept as an explicit clause so callers get a clear security error rather
  # than a FunctionClauseError, without re-introducing the deputy open path.
  @spec open_signing_authority(term()) :: {:error, :possession_proof_required}
  def open_signing_authority(_agent_id_or_other) do
    {:error, :possession_proof_required}
  end

  @doc false
  @spec open_signing_authority(term(), term()) :: {:error, :possession_proof_required}
  def open_signing_authority(_agent_id, _opts) do
    {:error, :possession_proof_required}
  end

  @doc """
  Sign a payload using a previously opened signing authority.

  Fail-closed: forged, closed, owner-dead, suspended/revoked identity,
  purpose/principal tampering, and deleted-key authorities return explicit
  errors. Uses named dispatch only — safe across hot code reload of this module.

  Hostile partial struct-tagged maps (`%{__struct__: SigningAuthority, ...}`)
  are reconstructed via `SigningAuthority.canonicalize/1` and rejected with a
  shaped error — they must never raise or crash the broker GenServer.
  """
  @spec sign_with_authority(SigningAuthority.t(), binary()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def sign_with_authority(authority, payload) when is_binary(payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        SigningAuthorityBroker.sign(canonical, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sign_with_authority(authority, _payload) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Derive a domain-separated secret using a signing authority.

  `purpose` is mandatory domain separation material. The broker always
  prefixes a fixed namespace so undomained raw-key export is impossible.
  The persistent private key is never returned.

  Partial/forged struct-tagged maps are canonicalized and fail closed.
  """
  @spec derive_secret_with_authority(SigningAuthority.t(), atom() | String.t()) ::
          {:ok, binary()} | {:error, term()}
  def derive_secret_with_authority(authority, purpose) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        SigningAuthorityBroker.derive_secret(canonical, purpose)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Close a signing authority's live claim.

  For a bootstrap-backed authority, this revokes the current authority token
  and releases the slot into its bounded reclaim grace. It does not permanently
  revoke the restart slot. Use `close_signing_authority_bootstrap/1` to remove
  the slot and any active authority permanently.

  Partial/forged struct-tagged maps are canonicalized and fail closed without
  crashing the broker or exiting the caller.
  """
  @spec close_signing_authority(SigningAuthority.t()) :: :ok | {:error, term()}
  def close_signing_authority(authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        SigningAuthorityBroker.close(canonical)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_acquisition_purpose(opts) do
    case Map.fetch(opts, :purpose) do
      {:ok, purpose} when not is_nil(purpose) -> {:ok, purpose}
      _ -> {:error, :invalid_purpose}
    end
  end

  defp validate_owner_pid(pid) when is_pid(pid), do: :ok
  defp validate_owner_pid(_), do: {:error, :invalid_owner}

  # Ed25519 accepts 32-byte seeds and 64-byte expanded private keys only.
  # Other sizes (and non-binaries) must fail closed as a typed error — never
  # reach :crypto.sign/5, which raises ErlangError on bad key material.
  defp validate_private_key_for_authority(key)
       when is_binary(key) and byte_size(key) in [32, 64],
       do: :ok

  defp validate_private_key_for_authority(_), do: {:error, :invalid_private_key}

  defp sign_acquisition_proof(payload, agent_id, private_key) do
    try do
      SignedRequest.sign(payload, agent_id, private_key)
    rescue
      # This call's payload and agent id are constructed and validated above;
      # the private key is its only caller-supplied crypto argument. OTP has
      # changed the exact bad-key error tuple across releases, so do not bind
      # correctness to an internal message shape.
      ErlangError -> {:error, :invalid_private_key}
    end
  end

  # Booleans are atoms — reject before the generic atom accept.
  defp validate_authority_purpose(purpose) when is_boolean(purpose),
    do: {:error, :invalid_purpose}

  defp validate_authority_purpose(purpose) when is_atom(purpose) and not is_nil(purpose), do: :ok

  defp validate_authority_purpose(purpose) when is_binary(purpose) do
    if String.trim(purpose) == "", do: {:error, :invalid_purpose}, else: :ok
  end

  defp validate_authority_purpose(_), do: {:error, :invalid_purpose}

  # ===========================================================================
  # OIDC Authentication
  # ===========================================================================

  @doc """
  Authenticate a human operator via OIDC device flow.

  Starts the device authorization grant (RFC 8628), waits for the user
  to authorize in their browser, then binds persistent keypairs to the
  OIDC identity.

  Returns the persistent human principal plus a caller-owned signing authority.
  """
  @spec authenticate_oidc(map() | nil) ::
          {:ok, String.t(), SigningAuthority.t()} | {:error, term()}
  def authenticate_oidc(config \\ nil) do
    alias Arbor.Security.OIDC
    OIDC.authenticate_device_flow(config)
  end

  @doc """
  Authenticate using an existing OIDC ID token.

  Verifies the token, loads the bound keypair, and returns a caller-owned
  signing authority.
  """
  @spec authenticate_oidc_token(String.t(), map() | nil) ::
          {:ok, String.t(), SigningAuthority.t()} | {:error, term()}
  def authenticate_oidc_token(id_token, config \\ nil) do
    alias Arbor.Security.OIDC
    OIDC.authenticate_token(id_token, config)
  end

  @doc """
  Check if an agent ID represents a human (OIDC-authenticated) identity.
  """
  @spec human_identity?(String.t()) :: boolean()
  def human_identity?(agent_id) when is_binary(agent_id) do
    String.starts_with?(agent_id, "human_")
  end

  # ===========================================================================
  # Private functions
  # ===========================================================================

  # Old helpers moved to AuthDecision — deleted to avoid dead code.

  defp maybe_emit_receipt(cap, principal_id, resource_uri, action, result, opts) do
    if Config.invocation_receipts_enabled?() do
      case InvocationReceipt.new(
             capability_id: cap.id,
             principal_id: principal_id,
             resource_uri: resource_uri,
             action: action,
             result: result,
             delegation_chain: cap.delegation_chain,
             session_id: cap.session_id,
             task_id: cap.task_id
           ) do
        {:ok, receipt} ->
          case SystemAuthority.sign_receipt(receipt) do
            {:ok, signed_receipt} ->
              Events.record_invocation_receipt(signed_receipt)
              Keyword.get(opts, :receipt_callback, &Function.identity/1).(signed_receipt)

            {:error, _} ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp maybe_check_max_uses(%Capability{max_uses: nil}), do: :ok

  defp maybe_check_max_uses(%Capability{max_uses: max_uses} = cap) do
    case CapabilityStore.increment_usage(cap.id) do
      {:ok, count} when count >= max_uses ->
        CapabilityStore.revoke(cap.id)
        Events.record_capability_revoked(cap.id)

      {:ok, _count} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp maybe_enforce_constraints(cap, principal_id, resource_uri) do
    if Config.constraint_enforcement_enabled?() and cap.constraints != %{} do
      Constraint.enforce(cap.constraints, principal_id, resource_uri)
    else
      :ok
    end
  end

  # Synthesize the path-embedded URI when the caller passed a bare
  # `arbor://fs/<op>` URI plus the `:file_path` opt. Lets path-scoped
  # caps participate in the URI matcher directly.
  defp maybe_synthesize_fs_path_uri(resource_uri, opts) when is_binary(resource_uri) do
    case synthesize_fs_path_uri(resource_uri, opts) do
      {:ok, effective_uri} -> effective_uri
      {:error, _reason} -> resource_uri
    end
  end

  defp maybe_synthesize_fs_path_uri(resource_uri, _opts), do: resource_uri

  defp synthesize_fs_path_uri(resource_uri, opts) when is_binary(resource_uri) do
    case Keyword.get(opts, :file_path) do
      file_path when is_binary(file_path) ->
        if bare_fs_op_uri?(resource_uri) do
          with {:ok, path} <- normalize_fs_authorization_path(file_path, opts) do
            {:ok, append_fs_authorization_path(resource_uri, path)}
          else
            {:error, reason} -> {:error, {:invalid_file_path, reason}}
          end
        else
          {:ok, resource_uri}
        end

      nil ->
        {:ok, resource_uri}

      _other ->
        if bare_fs_op_uri?(resource_uri) do
          {:error, {:invalid_file_path, :not_binary}}
        else
          {:ok, resource_uri}
        end
    end
  end

  defp synthesize_fs_path_uri(resource_uri, _opts), do: {:ok, resource_uri}

  defp append_fs_authorization_path(resource_uri, ""), do: resource_uri
  defp append_fs_authorization_path(resource_uri, path), do: "#{resource_uri}/#{path}"

  defp normalize_fs_authorization_path(file_path, opts) do
    case workspace_root(opts) do
      {:ok, workspace} ->
        with {:ok, resolved} <- SafePath.resolve_within(file_path, workspace) do
          {:ok, relativize_path(resolved, workspace)}
        end

      :none ->
        normalize_unscoped_fs_path(file_path)
    end
  end

  defp workspace_root(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        {:ok, SafePath.normalize(workspace)}

      _ ->
        :none
    end
  end

  defp relativize_path(path, root) do
    case Path.relative_to(path, root) do
      "." -> ""
      relative -> String.trim_leading(relative, "/")
    end
  end

  defp normalize_unscoped_fs_path(file_path) do
    with :ok <- SafePath.validate(file_path) do
      if SafePath.absolute?(file_path) do
        {:ok, file_path |> SafePath.normalize() |> String.trim_leading("/")}
      else
        normalize_relative_fs_path(file_path)
      end
    end
  end

  defp normalize_relative_fs_path(file_path) do
    result =
      file_path
      |> Path.split()
      |> Enum.reduce_while({:ok, []}, fn
        ".", {:ok, parts} ->
          {:cont, {:ok, parts}}

        "..", {:ok, []} ->
          {:halt, {:error, :path_traversal}}

        "..", {:ok, [_ | rest]} ->
          {:cont, {:ok, rest}}

        part, {:ok, parts} ->
          {:cont, {:ok, [part | parts]}}
      end)

    case result do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join("/")}
      {:error, _reason} = error -> error
    end
  end

  defp file_guard_authorization_path(file_path, opts) do
    with {:ok, path} <- normalize_fs_authorization_path(file_path, opts) do
      {:ok, "/" <> path}
    end
  end

  # `arbor://fs/<op>` with no further path segments. Matches:
  #   "arbor://fs/read", "arbor://fs/write", "arbor://fs/list", etc.
  # Doesn't match: "arbor://fs/read/some/path" (already path-embedded).
  defp bare_fs_op_uri?("arbor://fs/" <> rest), do: not String.contains?(rest, "/")
  defp bare_fs_op_uri?(_), do: false

  # When authorizing arbor://fs/* URIs with a file_path option,
  # verify the path via FileGuard. This integrates path-scoped
  # authorization into the main auth chain instead of requiring
  # callers to call FileGuard separately.
  # Reduce maybe_check_file_guard's three-shape return to :ok / {:error, _}
  # for use in `with` chains that just need a pass/fail signal.
  defp normalize_file_guard_result(:ok), do: :ok
  defp normalize_file_guard_result({:ok, _resolved_path}), do: :ok
  defp normalize_file_guard_result({:error, _} = err), do: err

  defp maybe_check_file_guard(principal_id, resource_uri, opts, cap) do
    file_path = Keyword.get(opts, :file_path)
    file_guard = file_guard_module()

    cond do
      # Explicit path: caller knows they want path-bound checking. Full
      # FileGuard.authorize/3 lookup-and-resolve against the same canonical
      # path form used for capability lookup above.
      file_path && String.starts_with?(resource_uri, "arbor://fs/") ->
        if Code.ensure_loaded?(file_guard) do
          operation = infer_fs_operation(resource_uri)

          with {:ok, guard_path} <- file_guard_authorization_path(file_path, opts) do
            file_guard.authorize(principal_id, guard_path, operation)
          end
        else
          :ok
        end

      # Implicit path defense-in-depth: caller didn't pass :file_path, but
      # the URI itself is an fs:// URI and we have a matched cap. Run pure
      # path normalization (SafePath + symlink-escape detection) on the
      # URI's path-part against the cap's root. The URI matcher's prefix
      # check already accepted; this adds the SafePath layer that callers
      # used to have to opt into.
      cap != nil and String.starts_with?(resource_uri, "arbor://fs/") and
          Code.ensure_loaded?(file_guard) ->
        case file_guard.normalize_uri_path_for_capability(resource_uri, cap) do
          {:ok, resolved} -> {:ok, resolved}
          :not_applicable -> :ok
          {:error, _reason} = err -> err
        end

      true ->
        :ok
    end
  rescue
    # H2 review fix (2026-06-09): a crash in path validation must NOT skip
    # the path-binding check and authorize. In the explicit-path branch
    # FileGuard.authorize/3 IS the binding of a bare arbor://fs/<op> cap to
    # a concrete path — swallowing its exception and returning :ok would let
    # a broad fs cap write/read anywhere. Fail closed, matching
    # check_reflexes/5 in this same module. (Was `:ok`.)
    _ -> {:error, {:file_guard_error, :exception}}
  catch
    :exit, _ -> {:error, {:file_guard_error, :exit}}
  end

  # FileGuard module, overridable via config for tests / deployment swaps.
  defp file_guard_module do
    if Code.ensure_loaded?(Config) and function_exported?(Config, :file_guard_module, 0) do
      Config.file_guard_module()
    else
      Arbor.Security.FileGuard
    end
  end

  defp infer_fs_operation("arbor://fs/read" <> _), do: :read
  defp infer_fs_operation("arbor://fs/write" <> _), do: :write
  defp infer_fs_operation("arbor://fs/execute" <> _), do: :execute
  defp infer_fs_operation("arbor://fs/delete" <> _), do: :delete
  defp infer_fs_operation("arbor://fs/list" <> _), do: :list
  defp infer_fs_operation(_), do: :read

  # Reflex checking — instant safety blocks before expensive authorization
  defp check_reflexes(principal_id, context, resource_uri, action, _opts) do
    if Config.reflex_checking_enabled?() do
      case Reflex.check(context) do
        :ok ->
          :ok

        {:blocked, reflex, message} ->
          Events.record_reflex_triggered(principal_id, reflex, resource_uri, action, :blocked)
          {:error, {:reflex_blocked, reflex.id, message}}

        {:warned, warnings} ->
          # Log warnings but allow the request to proceed
          for {reflex, message} <- warnings do
            Events.record_reflex_warning(principal_id, reflex.id, message)
          end

          :ok
      end
    else
      :ok
    end
  rescue
    _ ->
      Logger.error("Reflex check failed due to exception — failing closed for safety")
      {:error, {:reflex_check_failed, :exception}}
  end

  defp build_reflex_context(resource_uri, action, opts) do
    context = %{resource: resource_uri, action: action}

    # Add command if provided in opts (for shell operations)
    context =
      case Keyword.get(opts, :command) do
        nil -> context
        cmd -> Map.put(context, :command, cmd)
      end

    # Add path if it can be extracted from the resource URI
    context =
      case extract_path_from_uri(resource_uri) do
        nil -> context
        path -> Map.put(context, :path, path)
      end

    # Add URL if provided
    context =
      case Keyword.get(opts, :url) do
        nil -> context
        url -> Map.put(context, :url, url)
      end

    context
  end

  # Extract file path from arbor:// resource URIs
  defp extract_path_from_uri("arbor://fs/" <> rest), do: "/" <> rest
  defp extract_path_from_uri(_), do: nil
end
