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
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Contracts.Security.SigningAuthority.Validator, as: SigningAuthorityValidator
  alias Arbor.Contracts.Security.SigningAuthorityBootstrap
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Common.SafePath
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Constraint
  alias Arbor.Security.Crypto
  alias Arbor.Security.Constraint.RateLimiter
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.ApprovalReceiptBroker
  alias Arbor.Security.DeliveryReceiptBroker
  alias Arbor.Security.DisclosureCapability
  alias Arbor.Security.EgressGate
  alias Arbor.Security.Events
  alias Arbor.Security.Extension.PlatformActivationAuthorization
  alias Arbor.Security.ExtensionEnvelopes
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.InvocationAudit
  alias Arbor.Security.InvocationReceiptBroker
  alias Arbor.Security.IssuerRegistry
  alias Arbor.Security.Keychain
  alias Arbor.Security.KeyFile
  alias Arbor.Security.Reflex
  alias Arbor.Security.RevocationFence
  alias Arbor.Security.SigningAuthorityBroker
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.Telemetry
  alias Arbor.Security.UriRegistry

  require Logger

  @scheduler_caps_signing_domain "arbor.scheduler.caps.v2"
  @max_scheduler_caps_payload_bytes 1_048_576

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
  def authorize(principal_id, resource_uri, action \\ nil, opts \\ []) do
    authorize_with_effect(principal_id, resource_uri, action, opts, :none)
  end

  defp authorize_with_effect(principal_id, resource_uri, action, opts, effect) do
    result =
      check_if_principal_has_capability_for_resource_action(
        principal_id,
        resource_uri,
        action,
        opts,
        effect
      )

    Arbor.Security.InvocationAudit.observe_authorization(result, principal_id, resource_uri)
  end

  @doc """
  Authorize and read a regular file through a descriptor bound to the selected
  filesystem capability's root.

  This is the file-read facade for agent-controlled paths. It keeps the live
  session/task scope on both the authorization decision and the descriptor
  open, preventing a symlink swap between an authorization check and a later
  File.read/1 call. `path` must be absolute; an owning workspace boundary must
  resolve relative input before calling this facade.
  """
  @spec read_authorized_file(String.t(), String.t(), keyword()) ::
          {:ok, binary(), String.t()}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def read_authorized_file(principal_id, path, opts \\ [])

  def read_authorized_file(principal_id, path, opts)
      when is_binary(principal_id) and is_binary(path) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, execution_path} <- normalize_authorized_file_read_path(path, opts) do
      auth_opts =
        opts
        |> Keyword.delete(:workspace)
        |> Keyword.put(:file_path, execution_path)

      case authorize_with_effect(
             principal_id,
             "arbor://fs/read",
             :execute,
             auth_opts,
             {:read_file, execution_path}
           ) do
        {:ok, :authorized, {:ok, content, opened_path}}
        when is_binary(content) and is_binary(opened_path) ->
          {:ok, content, opened_path}

        {:ok, :pending_approval, _proposal_id} = pending ->
          pending

        {:error, _reason} = error ->
          error

        _unexpected ->
          {:error, :invalid_file_read_result}
      end
    else
      false -> {:error, :invalid_file_read}
      {:error, _reason} = error -> error
    end
  end

  def read_authorized_file(_principal_id, _path, _opts), do: {:error, :invalid_file_read}

  defp normalize_authorized_file_read_path(path, _opts) do
    with true <- SafePath.absolute?(path),
         :ok <- SafePath.validate(path) do
      {:ok, SafePath.normalize(path)}
    else
      false -> {:error, :absolute_file_path_required}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validate closed notice facts and conservative payload-bound provenance; grants no authority."
  def validate_notice_publication_value(scope, value),
    do: Arbor.Security.ConversationNoticeCore.value(scope, value)

  @doc "Validate closed notice scope facts without granting resource authority."
  def validate_notice_publication_scope(scope),
    do: Arbor.Security.ConversationNoticeCore.scope(scope)

  @doc false
  def validate_native_notice_mailbox(principal, mailbox) do
    with true <- is_map(mailbox) and not is_struct(mailbox),
         true <-
           Enum.sort(Map.keys(mailbox)) ==
             Enum.sort(~w(mailbox_id recipient_subject_id owner_id engagement_id)),
         true <- Arbor.Security.ConversationNoticeCore.mailbox?(mailbox["mailbox_id"]),
         {:ok, scope} <-
           validate_notice_publication_scope(%{
             owner_id: mailbox["owner_id"],
             target_agent_id: principal,
             engagement_id: mailbox["engagement_id"]
           }),
         {:ok, _subject_scope} <-
           validate_notice_publication_scope(%{
             scope
             | owner_id: mailbox["recipient_subject_id"]
           }) do
      {:ok, mailbox}
    else
      _ -> {:error, :invalid_notice}
    end
  end

  @doc "Digest exact immutable notice facts; timestamps and source generations are excluded."
  def notice_publication_facts_digest(scope, value),
    do: Arbor.Security.ConversationNoticeCore.digest(scope, value)

  @doc "Pure exact-domain payload for an existing scoped notice read."
  defdelegate conversation_notice_read_request_payload(subject, target, page, expected),
    to: Arbor.Security.ConversationNoticeReadCore,
    as: :payload

  @doc """
  Fresh scoped visual read admission. The continuation receives only its pinned
  owner and a same-stack release check. Private proof and exact selected grant
  remain in this boundary and never enter a wire record or action parameters.
  """
  def with_authenticated_conversation_notice_read(subject, target, payload, opts, continuation)
      when is_function(continuation, 2) do
    resource = "arbor://chat/agent/" <> target

    with true <- Keyword.keyword?(opts),
         expected = Keyword.get(opts, :expected_engagement_id),
         true <-
           Arbor.Security.ConversationNoticeReadCore.valid_payload?(
             payload,
             subject,
             target,
             expected
           ),
         {:ok, proof_opts} <- validate_conversation_operation_opts(opts),
         :ok <- bind_conversation_operation_proof(subject, payload, proof_opts),
         :ok <- require_exact_active_identity(target),
         {:ok, :authorized, cap, _auth, _safe} <-
           chat_authorization_decision(subject, resource, proof_opts),
         :ok <- reusable_conversation_capability(cap),
         :ok <- conversation_stateless_constraints(cap.constraints, resource) do
      if String.starts_with?(subject, "human_") do
        with {:ok, owner} <- resolve_conversation_owner(subject) do
          digest = capability_notice_digest(cap)

          release = fn scope, page ->
            recheck_notice_visual_release(
              subject,
              target,
              owner,
              expected,
              resource,
              cap.id,
              digest,
              proof_opts,
              scope,
              page,
              payload
            )
          end

          continuation.(owner, release)
        end
      else
        {:error, :notice_subject_required}
      end
    else
      {:error, :unsupported_conversation_capability} = error -> error
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  # An exact same-owner visual sink, not provider export or speech permission.
  # This is a continuation recheck; it neither authenticates another request nor
  # consumes the already-admitted signed nonce or a use/rate allowance.
  defp recheck_notice_visual_release(
         subject,
         target,
         owner,
         expected,
         resource,
         cap_id,
         digest,
         proof_opts,
         scope,
         page,
         payload
       ) do
    # Bound/validate producer bytes before the last fresh authority check. Even
    # malformed data must not disguise a concurrent loss of human authority.
    page_validation =
      Arbor.Security.ConversationNoticeReadCore.validate_page(scope, page, payload)

    with true <- scope == %{owner_id: owner, target_agent_id: target, engagement_id: expected},
         :ok <- require_exact_active_identity(target),
         :ok <- require_exact_active_identity(subject),
         {:ok, ^owner} <- resolve_conversation_owner(subject),
         :ok <- recheck_notice_lease(subject, target, owner, proof_opts),
         :ok <-
           check_reflexes(subject, build_reflex_context(resource, :chat, []), resource, :chat, []),
         opts = [verify_identity: false, exact_capability_id: cap_id],
         {:ok, :authorized, cap, _} <-
           AuthDecision.evaluate(build_auth_context(subject, opts), resource, :chat, opts),
         true <- capability_notice_digest(cap) == digest,
         :ok <- reusable_conversation_capability(cap),
         :ok <- conversation_stateless_constraints(cap.constraints, resource) do
      page_validation
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  defp recheck_notice_lease(subject, target, owner, opts) do
    case Keyword.fetch(opts, :session_token) do
      {:ok, token} ->
        case recheck_conversation_session(subject, target, owner, token) do
          {:ok, :authorized} -> :ok
          _ -> {:error, :unauthorized}
        end

      :error ->
        :ok
    end
  end

  @doc false
  defdelegate begin_native_notice_profile_mutation(principal),
    to: Arbor.Security.NativeNoticeBroker,
    as: :begin_profile_mutation

  @doc false
  defdelegate finish_native_notice_profile_mutation(ticket),
    to: Arbor.Security.NativeNoticeBroker,
    as: :finish_profile_mutation

  @doc false
  defdelegate open_native_notice_source(authority),
    to: Arbor.Security.NativeConversationNotices,
    as: :open_source

  @doc false
  defdelegate delegate_native_notice_worker(source, worker),
    to: Arbor.Security.NativeConversationNotices,
    as: :delegate_worker

  @doc false
  defdelegate claim_native_notice_worker(bootstrap),
    to: Arbor.Security.NativeConversationNotices,
    as: :claim_worker

  @doc false
  defdelegate native_notice_action_resource(params),
    to: Arbor.Security.NativeConversationNotices,
    as: :resource

  @doc false
  defdelegate prepare_native_notice_publication(params, taints),
    to: Arbor.Security.NativeConversationNotices,
    as: :prepare

  @doc false
  defdelegate activate_native_notice_publication(prepared),
    to: Arbor.Security.NativeConversationNotices,
    as: :activate

  @doc false
  defdelegate native_notice_publication_value(params),
    to: Arbor.Security.NativeConversationNotices,
    as: :peek

  @doc false
  defdelegate consume_native_notice_commit(scope, value),
    to: Arbor.Security.NativeConversationNotices,
    as: :consume_value

  @doc false
  defdelegate reconcile_native_notice_commit(scope, value),
    to: Arbor.Security.NativeConversationNotices,
    as: :reconcile_value

  @doc false
  defdelegate finish_native_notice_publication(params, outcome),
    to: Arbor.Security.NativeConversationNotices,
    as: :finish

  @doc false
  defdelegate close_native_notice_worker(),
    to: Arbor.Security.NativeConversationNotices,
    as: :close_worker

  @doc false
  defdelegate discard_native_notice_publication(),
    to: Arbor.Security.NativeConversationNotices,
    as: :discard

  # Internal selected decision seam. It returns no usable publication receipt;
  # only the native broker holds it through the worker/Trust/taint admission.
  @doc false
  def prepare_native_notice_capability(principal, resource, payload, proof) do
    opts = [signed_request: proof, verify_identity: true, expected_resource: payload]

    with true <- match?(%SignedRequest{agent_id: ^principal, payload: ^payload}, proof),
         :ok <- require_exact_active_identity(principal),
         :ok <-
           check_reflexes(
             principal,
             build_reflex_context(resource, :execute, []),
             resource,
             :execute,
             []
           ),
         {:ok, disposition, cap, auth} <-
           AuthDecision.evaluate(build_auth_context(principal, opts), resource, :execute, opts),
         true <- disposition in [:authorized, :requires_approval],
         :ok <- reusable_conversation_capability(cap),
         true <- is_nil(cap.session_id) and is_nil(cap.task_id) and is_nil(cap.principal_scope),
         :ok <- conversation_stateless_constraints(cap.constraints, resource) do
      {:ok,
       %{
         principal: principal,
         resource: resource,
         capability: cap,
         auth: auth,
         capability_digest: capability_notice_digest(cap)
       }}
    else
      {:error, :unsupported_conversation_capability} -> {:error, :unsupported_notice_capability}
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  @doc false
  def recheck_native_notice_capability(decision) do
    case native_notice_current_capability(decision) do
      {:ok, _cap} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  @doc false
  def consume_native_notice_capability(decision) do
    with {:ok, cap} <- native_notice_current_capability(decision) do
      # The fresh proof was already checked once during private preparation.
      # Never emit it or its body-bearing expected payload in observability.
      handle_authorized(cap, decision.auth, decision.principal, decision.resource, :execute, [])
    end
  end

  defp native_notice_current_capability(decision) do
    with true <- is_map(decision) and not is_struct(decision),
         true <-
           Enum.sort(Map.keys(decision)) ==
             Enum.sort([:principal, :resource, :capability, :auth, :capability_digest]),
         %Capability{id: id} <- decision.capability,
         :ok <- require_exact_active_identity(decision.principal),
         :ok <-
           check_reflexes(
             decision.principal,
             build_reflex_context(decision.resource, :execute, []),
             decision.resource,
             :execute,
             []
           ),
         opts = [verify_identity: false, exact_capability_id: id],
         {:ok, :authorized, cap, _auth} <-
           AuthDecision.evaluate(
             build_auth_context(decision.principal, opts),
             decision.resource,
             :execute,
             opts
           ),
         true <- capability_notice_digest(cap) == decision.capability_digest,
         :ok <- reusable_conversation_capability(cap),
         :ok <- conversation_stateless_constraints(cap.constraints, decision.resource) do
      {:ok, cap}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp capability_notice_digest(cap),
    do: Base.encode16(:crypto.hash(:sha256, Capability.signing_payload(cap)), case: :lower)

  @doc "Run a trusted adapter invocation with durable source-owned attempt/decision/outcome evidence. Never accepts a caller invocation id."
  def with_invocation_audit(attributes, fun),
    do: Arbor.Security.InvocationAudit.run(attributes, fun)

  @doc "Current process-owned invocation id for correlation; nil outside an admitted invocation."
  def current_invocation_id, do: Arbor.Security.InvocationAudit.current_id()

  @doc "Durably admit the effect inside the current trusted invocation before starting it."
  def admit_invocation_effect, do: Arbor.Security.InvocationAudit.admit_effect()

  @doc "Read effective security enforcement for qualification; uses frozen owner policy where applicable."
  def execution_policy_snapshot do
    modules = Application.spec(:arbor_security, :modules) || []

    implementations =
      Enum.map(Enum.sort(modules), fn module ->
        Code.ensure_loaded!(module)
        {Atom.to_string(module), Base.encode16(module.module_info(:md5), case: :lower)}
      end)

    sink = Config.invocation_audit_sink()

    audit_identity =
      if is_atom(sink) and Code.ensure_loaded?(sink) and
           function_exported?(sink, :security_audit_identity, 0),
         do: sink.security_audit_identity(),
         else: {:error, :invocation_audit_unavailable}

    %{
      identity_verification: Config.identity_verification_enabled?(),
      capability_signing: Config.capability_signing_required?(),
      constraint_enforcement: Config.constraint_enforcement_enabled?(),
      delegation_verification: Config.delegation_chain_verification_enabled?(),
      egress_enforcing: EgressGate.enforcing?(),
      uri_registry_enforcement:
        Application.get_env(:arbor_security, :uri_registry_enforcement, true),
      invocation_audit: Config.invocation_audit_mode(),
      invocation_sink: sink,
      audit_identity: audit_identity,
      authority_journal: qualification_journal_identity(),
      implementations: implementations
    }
  end

  @doc """
  Capture current permission declarations for execution qualification.

  Exact qualification approvals are omitted so approval does not change its own
  subject. Replacing an ordinary root grant with the same permissions preserves
  the declaration identity; scope, constraints, validity and signature validity
  remain bound. Delegated grants retain their lineage and instance identity.
  This observation does not replace authorization at an effect boundary.
  """
  def execution_capability_snapshot(principal_id) when is_binary(principal_id) do
    with {:ok, capabilities} <- list_capabilities(principal_id) do
      declarations =
        capabilities
        |> Enum.reject(&qualification_approval_resource?(&1.resource_uri))
        |> Enum.map(&qualification_capability_declaration/1)
        |> Enum.uniq()
        |> Enum.sort()

      if :erlang.external_size(declarations) <= 1_048_576 do
        digest = :crypto.hash(:sha256, :erlang.term_to_binary(declarations, [:deterministic]))

        {:ok,
         %{
           "principal_id" => principal_id,
           "permissions_digest" => "sha256:" <> Base.encode16(digest, case: :lower)
         }}
      else
        {:error, :capability_profile_unavailable}
      end
    end
  rescue
    _ -> {:error, :capability_profile_unavailable}
  catch
    _, _ -> {:error, :capability_profile_unavailable}
  end

  def execution_capability_snapshot(_), do: {:error, :capability_profile_unavailable}

  # Only configuration-stable journal fields. This snapshot is digested into
  # the security-qualification fingerprint (SecurityQualification.capture/2),
  # so load-dependent readiness such as the journal's `admission_open` stays in
  # `audit_journal_status/0`: a delivery backlog must never change a qualified
  # profile's identity.
  defp qualification_journal_identity do
    case audit_journal_status() do
      {:ok, status} -> {:ok, Map.take(status, ~w(mode durability serving poisoned torn_tail))}
      _ -> {:error, :journal_unavailable}
    end
  end

  defp qualification_approval_resource?(uri) when is_binary(uri),
    do:
      Regex.match?(
        ~r/\Aarbor:\/\/agent\/security_qualification\/[0-9a-f]{64}\/[0-9a-f]{64}\z/,
        uri
      )

  defp qualification_approval_resource?(_), do: false

  defp qualification_capability_declaration(capability) do
    declaration =
      capability
      |> Map.from_struct()
      |> Map.drop([:issuer_signature, :signed_at])
      |> Map.put(:valid, Capability.valid?(capability))
      |> Map.put(:signature_valid, SystemAuthority.verify_capability_signature(capability) == :ok)

    if capability.parent_capability_id == nil and capability.delegation_chain == [],
      do: Map.drop(declaration, [:id, :granted_at]),
      else: declaration
  end

  @doc """
  Authorize a SELF-scoped resource, letting a capability on the canonical
  parent cover the principal's own child resource.

  Facades gate scoped resources (`arbor://historian/query/agent:<id>`,
  `arbor://memory/read/<id>`) while trust policy mints the canonical parent
  (`arbor://historian/query`). An exact capability never covers a descendant,
  so anything reached by minting rather than template grant was refused
  (2026-08-25). This relaxes CAPABILITY COVERAGE only, and only when:

    * `principal_id == subject_id` — self is the authenticated principal, never
      a parameter; and
    * `scoped_uri` is a strict segment-descendant of `parent_uri`.

  Otherwise it is exactly `authorize/4` on `scoped_uri`. Trust policy on the
  child (rules, ceilings) is the action layer's job and is not evaluated here.
  """
  @spec authorize_self_scoped(String.t(), String.t(), String.t(), String.t(), atom(), keyword()) ::
          {:ok, :authorized} | {:ok, :pending_approval, String.t()} | {:error, term()}
  def authorize_self_scoped(principal_id, scoped_uri, subject_id, parent_uri, action, opts \\ [])

  def authorize_self_scoped(principal_id, scoped_uri, subject_id, parent_uri, action, opts)
      when is_binary(principal_id) and is_binary(scoped_uri) and is_binary(subject_id) and
             is_binary(parent_uri) do
    self? = principal_id == subject_id and principal_id != ""
    descendant? = scoped_uri != parent_uri and CapabilityUri.prefix_match?(parent_uri, scoped_uri)

    case authorize(principal_id, scoped_uri, action, opts) do
      {:error, _} = denied when self? and descendant? ->
        case authorize(principal_id, parent_uri, action, opts) do
          {:ok, _} = ok -> ok
          {:ok, _, _} = ok -> ok
          _ -> denied
        end

      other ->
        other
    end
  end

  def authorize_self_scoped(principal_id, scoped_uri, _subject_id, _parent_uri, action, opts),
    do: authorize(principal_id, scoped_uri, action, opts)

  @exact_scope_keys MapSet.new([:session_id, :task_id, :principal_scope, :expected_egress])
  @exact_egress_keys MapSet.new([:max_tier, :destination])
  @exact_scalar_max_bytes 256
  @source_owned_egress_opt :source_owned_exact_egress_expectation

  @doc """
  Exercise one source-selected ordinary grant for a concrete resource.

  The caller must already own authenticated execution authority. This function
  does not authenticate an external caller: a capability id and payload digest
  are public provenance, not bearer authority. It accepts no generic options.

  The exact current stored capability must match the principal and lowercase
  SHA-256 of `Capability.signing_payload/1`, cover the concrete resource, and
  carry a current SystemAuthority signature. Only nondelegated, unscoped grants
  with no constraints or max-use limit are supported. Revocation, replacement,
  expiry, inactive identity, and unsupported shapes deny without selecting
  another covering grant or requesting approval.

  Normal authorization checks, FileGuard, events, and receipts still run.
  The caller separately intersects current owner trust policy at each effect.
  """
  @spec authorize_source_owned_selected_ordinary_capability(
          String.t(),
          String.t(),
          :execute,
          String.t(),
          String.t()
        ) :: {:ok, :authorized} | {:error, :invalid_request | :unauthorized}
  def authorize_source_owned_selected_ordinary_capability(
        principal_id,
        resource_uri,
        action,
        capability_id,
        expected_digest
      ) do
    with :ok <-
           validate_selected_capability_request(
             principal_id,
             resource_uri,
             action,
             capability_id,
             expected_digest
           ),
         :ok <- require_exact_active_identity(principal_id),
         {:ok, :authorized} <-
           check_if_principal_has_capability_for_resource_action(
             principal_id,
             resource_uri,
             action,
             verify_identity: false,
             exact_capability_id: capability_id,
             source_owned_selected_ordinary_digest: expected_digest
           ) do
      {:ok, :authorized}
    else
      {:error, :invalid_request} = error -> error
      _denied -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp validate_selected_capability_request(principal, uri, action, capability_id, digest) do
    with true <- bounded_exact_scalar?(principal),
         true <- is_binary(uri) and byte_size(uri) <= 4096,
         {:ok, %CapabilityUri{wildcard: :none} = parsed} <- CapabilityUri.parse(uri),
         true <- CapabilityUri.canonical(parsed) == uri,
         true <- action == :execute and canonical_exact_capability_id?(capability_id),
         true <- is_binary(digest) and byte_size(digest) == 64,
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

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

  # Delivery-receipt issue admits cryptographic proof keys and the HMAC-only
  # compare fence. Never silently strip. Explicitly forbidden: :identity_verified,
  # :verify_identity (caller), :task_id, :principal_scope.
  @issue_session_mode_keys [:session_token, :expected_engagement_id]

  @doc """
  Build the exact bytes to sign for a 90-second human conversation session.

  The versioned payload binds purpose, subject, target and fixed lifetime.
  Sign with `sign_key_file_request/2`; an ordinary signed chat request cannot
  be substituted. This function creates no authority or identity.
  """
  defdelegate conversation_session_request_payload(principal, target),
    to: Arbor.Security.ConversationSession,
    as: :request_payload

  @doc """
  Exchange a fresh purpose-bound human signature for a 90-second session proof.

  Requires a current reusable chat capability for the exact target, verifies
  identity and nonce once, and rechecks authority before returning. No capability
  is granted. The returned bearer token authenticates only `:chat` on this exact target and
  is rejected by generic session verification. It must remain private; desk operations
  retain it server-side and never return it through their control surface.
  """
  defdelegate issue_signed_conversation_session(principal, target, signed_request),
    to: Arbor.Security.ConversationSession,
    as: :issue

  if Mix.env() == :test do
    @doc false
    def issue_conversation_session_fixture(principal, target) do
      Arbor.Security.SessionToken.generate_conversation_fixture(principal, target)
    end
  end

  @doc "Exchange an exact authenticated chat receipt for a pending, caller-owned memory admission."
  defdelegate exchange_private_memory_receipt(receipt, agent_id, sender_id, context),
    to: Arbor.Security.PrivateMemory,
    as: :exchange

  @doc "Activate a pending admission once, binding immutable engagement provenance."
  defdelegate activate_private_memory_admission(admission, engagement_id),
    to: Arbor.Security.PrivateMemory,
    as: :activate

  @doc "Compare a receipt-owned engagement fence with the resolved private scope without activating it."
  defdelegate check_private_memory_engagement(admission, engagement_id),
    to: Arbor.Security.PrivateMemory,
    as: :check_engagement

  @doc "Check live receipt-derived pair scope and current chat and memory capabilities."
  defdelegate authorize_private_memory_turn(admission, operation),
    to: Arbor.Security.PrivateMemory,
    as: :authorize

  @doc "Close a memory admission. Only its owning process may close an active token."
  defdelegate close_private_memory_admission(admission),
    to: Arbor.Security.PrivateMemory,
    as: :close

  @doc "Attest one closed private memory record using admitted ownership and the persisted system root."
  defdelegate attest_private_memory_record(admission, descriptor),
    to: Arbor.Security.PrivateMemory,
    as: :attest

  @doc "Verify historical private record authenticity; this does not authorize a current read."
  defdelegate verify_private_memory_record(descriptor, stamp),
    to: Arbor.Security.PrivateMemory,
    as: :verify

  @doc "Attest a closed transcript source before append; the stamp does not prove commit."
  defdelegate attest_private_memory_source(admission, descriptor),
    to: Arbor.Security.PrivateMemory,
    as: :attest_source

  @doc "Verify historical transcript source provenance against the current persisted root."
  defdelegate verify_private_memory_source(descriptor, stamp),
    to: Arbor.Security.PrivateMemory,
    as: :verify_source

  @doc "Attest a vector record for a verified original source using current same-owner admission."
  defdelegate attest_private_memory_record_from_source(admission, descriptor, source, stamp),
    to: Arbor.Security.PrivateMemory,
    as: :attest_record_from_source

  @doc "Attest a closed private goal snapshot with current receipt-derived write authority."
  defdelegate attest_private_goal_snapshot(admission, descriptor),
    to: Arbor.Security.PrivateMemory,
    as: :attest_goal_snapshot

  @doc "Verify private goal snapshot origin under the persisted current root; not read authority."
  defdelegate verify_private_goal_snapshot(descriptor, stamp),
    to: Arbor.Security.PrivateMemory,
    as: :verify_goal_snapshot

  @doc "Attest a closed private relationship snapshot with current receipt-derived write authority."
  defdelegate attest_private_relationship_snapshot(admission, descriptor),
    to: Arbor.Security.PrivateMemory,
    as: :attest_relationship_snapshot

  @doc "Verify private relationship origin under the current persisted root; not read authority or freshness."
  defdelegate verify_private_relationship_snapshot(descriptor, stamp),
    to: Arbor.Security.PrivateMemory,
    as: :verify_relationship_snapshot

  @issue_signed_mode_keys [:signed_request, :signer, :session_id, :expected_resource]
  @issue_admitted_opts [
    :session_token,
    :signed_request,
    :signer,
    :session_id,
    :expected_resource,
    :expected_engagement_id
  ]
  @max_issue_human_principal_bytes 256

  @doc """
  Authorize a human principal and exchange success for a one-use delivery receipt.

  Raw `session_token` may enter only through this facade and is forwarded solely
  to `authorize/4`. The receipt carries no principal, resource, action, or
  session proof — only a Security-owned broker entry does.

  Exactly one active cryptographic proof mode is required:
  - `:session_token` — human HMAC session proof; for chat-agent receipts only,
    optional `:expected_engagement_id` is a compare-only private admission fence
    (`eng_` plus 32 lowercase hexadecimal digits), never a routing input
  - `:signed_request` — signed request proof; optional companions `:signer`,
    `:session_id`, `:expected_resource`. After closed option validation the
    wrapper injects `verify_identity: true` so verification always runs,
    regardless of the global identity-verification default.

  Public options may not select TTL, capacity, broker, clock, collaborators,
  `:identity_verified`, `:verify_identity`, `:task_id`, or `:principal_scope`.
  Modes are mutually exclusive; proof-specific companions cannot cross modes.
  Chat-agent receipts additionally require a reusable supported chat capability
  and resolvable canonical owner before any use/rate allowance is consumed;
  finite-use grants return `:unsupported_conversation_capability`. Non-chat
  receipt authorization keeps its existing behavior.
  """
  @spec authorize_and_issue_delivery_receipt(String.t(), String.t(), atom() | nil, keyword()) ::
          {:ok, DeliveryReceipt.t()}
          | {:error,
             :invalid_principal
             | :invalid_opts
             | :unauthorized
             | :pending_approval
             | :authorization_failed
             | :unsupported_conversation_capability
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
      cond do
        chat_agent_receipt?(resource_uri, action) ->
          issue_chat_receipt(principal_id, resource_uri, safe_opts, :allow_pending)

        Keyword.has_key?(safe_opts, :expected_engagement_id) ->
          {:error, :invalid_opts}

        true ->
          issue_ordinary_receipt(principal_id, resource_uri, action, safe_opts)
      end
    end
  rescue
    _ -> {:error, :authorization_failed}
  catch
    :throw, _ -> {:error, :authorization_failed}
    :exit, _ -> {:error, :authorization_failed}
  end

  defp chat_agent_receipt?("arbor://chat/agent/" <> _target, :chat), do: true
  defp chat_agent_receipt?(_, _), do: false

  defp issue_ordinary_receipt(principal_id, resource_uri, action, safe_opts) do
    case authorize(principal_id, resource_uri, action, safe_opts) do
      {:ok, :authorized} ->
        proof =
          receipt_issuance_proof(:delivery, %{
            principal_id: principal_id,
            resource_uri: resource_uri,
            action: action
          })

        case DeliveryReceiptBroker.issue_authorized(proof) do
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

  @doc """
  Authenticate one opt-in conversation request and issue its delivery receipt.

  Accepts exactly one session token or signed request, for a bounded chat-agent
  resource and action `:chat`. The selected capability must be reusable
  (`max_uses: nil`) and contain only supported chat constraints. Finite-use or
  unknown constraints are refused before any usage/rate counter is consumed.
  Ordinary constraint effects occur once, after proof verification and canonical
  owner resolution. Generic chat-agent receipts share this admission policy.
  Only HMAC requests may carry an optional `:expected_engagement_id` fence;
  Session checks the source-resolved engagement before queueing and activation.
  """
  @spec authorize_and_issue_conversation_receipt(String.t(), String.t(), :chat, keyword()) ::
          {:ok, DeliveryReceipt.t()}
          | {:error, :unauthorized | :unsupported_conversation_capability}
  def authorize_and_issue_conversation_receipt(principal, resource, action, opts) do
    with :ok <- validate_conversation_authorization_request(principal, resource, action),
         true <- Keyword.keyword?(opts),
         true <-
           Enum.all?(
             Keyword.keys(opts),
             &(&1 in [:session_token, :signed_request, :expected_engagement_id])
           ),
         {:ok, proof_opts} <- validate_issue_opts(opts),
         {:ok, receipt} <- issue_chat_receipt(principal, resource, proof_opts, :deny_pending) do
      {:ok, receipt}
    else
      {:error, :unsupported_conversation_capability} = error -> error
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  @doc """
  Authenticate one conversation control operation and bind its receipt to its payload.

  The owning conversation boundary supplies the closed serialized operation. A
  signed proof must contain these exact bytes. The winning source recomputes the
  payload and consumes this one-use receipt; it cannot be used as a chat delivery
  or private-memory admission. Chat admission, canonical ownership, audit and
  allowance effects are shared with ordinary conversation receipts.

  Either proof mode may supply a compare-only `:expected_engagement_id` fence.
  The receipt stores that fence privately; the operation source must compare it
  with its resolved engagement. This does not grant approval-answer authority.
  """
  @spec authorize_and_issue_conversation_operation_receipt(
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, DeliveryReceipt.t()}
          | {:error, :unauthorized | :unsupported_conversation_capability}
  def authorize_and_issue_conversation_operation_receipt(principal, resource, payload, opts) do
    with :ok <- validate_conversation_authorization_request(principal, resource, :chat),
         true <- valid_conversation_operation_payload?(payload),
         {:ok, proof_opts} <- validate_conversation_operation_opts(opts),
         :ok <- bind_conversation_operation_proof(principal, payload, proof_opts),
         {:ok, receipt} <-
           issue_chat_receipt(principal, resource, proof_opts, :deny_pending, payload) do
      {:ok, receipt}
    else
      {:error, :unsupported_conversation_capability} = error -> error
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp valid_conversation_operation_payload?(payload),
    do: is_binary(payload) and byte_size(payload) in 1..131_072 and String.valid?(payload)

  defp validate_conversation_operation_opts(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <-
           Enum.all?(keys, &(&1 in [:session_token, :signed_request, :expected_engagement_id])),
         true <- valid_issue_engagement_fence?(opts),
         {:ok, proof_opts} <- validate_issue_opts(Keyword.delete(opts, :expected_engagement_id)) do
      {:ok, Keyword.merge(proof_opts, Keyword.take(opts, [:expected_engagement_id]))}
    else
      _ -> {:error, :invalid_opts}
    end
  end

  defp bind_conversation_operation_proof(principal, payload, opts) do
    case Keyword.fetch(opts, :signed_request) do
      {:ok, %SignedRequest{agent_id: ^principal, payload: ^payload}} -> :ok
      :error -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  # Source-owned chat admission policy shared by both receipt facades. Select and
  # authenticate exactly once. Reject unsupported continuations and unresolved
  # owners before the authorization effect handler spends use/rate allowances.
  defp issue_chat_receipt(
         principal,
         resource,
         proof_opts,
         approval_policy,
         operation_payload \\ nil
       ) do
    {expected_engagement_id, proof_opts} = Keyword.pop(proof_opts, :expected_engagement_id)

    with :ok <- validate_conversation_authorization_request(principal, resource, :chat),
         {:ok, decision, cap, auth, safe_opts} <-
           chat_authorization_decision(principal, resource, proof_opts),
         true <- decision == :authorized or approval_policy == :allow_pending,
         :ok <- reusable_conversation_capability(cap),
         {:ok, canonical_owner} <- resolve_conversation_owner(principal) do
      authorization =
        case decision do
          :authorized ->
            handle_authorized(cap, auth, principal, resource, :chat, safe_opts)

          :requires_approval ->
            handle_requires_approval(cap, auth, principal, resource, :chat, safe_opts)
        end

      case InvocationAudit.observe_authorization(authorization, principal, resource) do
        {:ok, :authorized} ->
          if is_nil(operation_payload) do
            receipt_issuance_proof(:conversation_delivery, %{
              principal_id: principal,
              resource_uri: resource,
              canonical_owner_id: canonical_owner,
              expected_engagement_id: expected_engagement_id
            })
            |> DeliveryReceiptBroker.issue_conversation_authorized()
          else
            receipt_issuance_proof(:conversation_operation_delivery, %{
              principal_id: principal,
              resource_uri: resource,
              canonical_owner_id: canonical_owner,
              expected_engagement_id: expected_engagement_id,
              operation_digest: :crypto.hash(:sha256, operation_payload)
            })
            |> DeliveryReceiptBroker.issue_conversation_operation_authorized()
          end

        {:ok, :pending_approval, _} ->
          {:error, :pending_approval}

        _ ->
          {:error, :unauthorized}
      end
    else
      {:error, :unsupported_conversation_capability} ->
        deny_chat_receipt(principal, resource, :unsupported_conversation_capability)

      _ ->
        deny_chat_receipt(principal, resource, :unauthorized)
    end
  end

  # Preflight denials must retain the ordinary authorization observability and
  # invocation audit boundary. Never pass proof-bearing options to either sink.
  # Effect-handler denials are already recorded and do not pass through here.
  defp deny_chat_receipt(principal, resource, reason) do
    Events.record_authorization_denied(principal, resource, reason, [])

    case InvocationAudit.observe_authorization({:error, reason}, principal, resource) do
      {:error, ^reason} -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Resolve a private conversation owner through the configured trusted alias resolver.

  This does not authenticate or grant access. Both the exact proof subject and
  canonical owner must remain active humans. Unconfigured, unavailable, malformed,
  or chained resolver results fail closed; no raw-principal fallback is allowed.
  """
  @spec resolve_conversation_owner(String.t()) :: {:ok, String.t()} | {:error, :unauthorized}
  def resolve_conversation_owner(principal) do
    with :ok <- validate_issue_human_principal(principal),
         :ok <- require_exact_active_identity(principal),
         {:ok, owner} <- resolve_identity_alias(principal),
         :ok <- validate_issue_human_principal(owner),
         :ok <- require_exact_active_identity(owner),
         {:ok, ^owner} <- resolve_identity_alias(owner) do
      {:ok, owner}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  @doc false
  def conversation_receipt_owner(receipt, principal, target_agent) do
    with {:ok, token} <- DeliveryReceipt.bearer_token(receipt),
         {:ok, owner} <-
           DeliveryReceiptBroker.conversation_owner(
             token,
             principal,
             "arbor://chat/agent/" <> target_agent
           ),
         {:ok, ^owner} <- resolve_conversation_owner(principal) do
      {:ok, owner}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc false
  def private_memory_owner_binding(admission) do
    with {:ok, token} <- Arbor.Security.Contracts.PrivateMemoryAdmission.token(admission),
         {:ok, binding} <- DeliveryReceiptBroker.memory_binding(token),
         {:ok, owner} <- resolve_conversation_owner(binding.authenticated_principal_id),
         true <- owner == binding.canonical_owner_id do
      {:ok, binding}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Recheck the exact authenticated subject's grant and its pinned conversation owner.

  Alias changes, unlinking, owner revocation and resolver outages deny the
  continuation. They never transfer grants or rescope an admitted operation.
  """
  @spec recheck_conversation_owner(String.t(), String.t(), String.t()) ::
          {:ok, :authorized} | {:error, :unauthorized}
  def recheck_conversation_owner(principal, target_agent, owner) do
    with {:ok, ^owner} <- resolve_conversation_owner(principal),
         {:ok, :authorized} <- recheck_conversation_access(principal, target_agent) do
      {:ok, :authorized}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Authenticate the exact human subject of a general browser session.

  Checks the session signature and current expiry through the configured token
  verifier. Scoped conversation tokens are not general login proofs. This does
  not check registry status or grant resource authority; resource operations must
  still use their existing identity and capability authorization gates.
  """
  @spec verify_human_session(String.t(), String.t()) :: :ok | {:error, :unauthorized}
  def verify_human_session(principal, token)
      when is_binary(token) and byte_size(token) in 1..4096 do
    with :ok <- validate_issue_human_principal(principal),
         {:ok, ^principal} <- apply(Config.session_token_module(), :verify, [token]) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  def verify_human_session(_, _), do: {:error, :unauthorized}

  @doc """
  Recheck an admitted human conversation against its original session proof.

  Verifies the exact HMAC subject and current token expiry, then checks current
  canonical ownership and chat authority without consuming rate/use allowances.
  This continuation issues no receipt and cannot admit a new operation.
  """
  @spec recheck_conversation_session(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :authorized} | {:error, :unauthorized}
  def recheck_conversation_session(principal, target_agent, owner, token)
      when is_binary(token) and byte_size(token) in 1..4096 do
    verifier = Config.session_token_module()

    proof =
      if Code.ensure_loaded?(verifier) and function_exported?(verifier, :verify_for, 3),
        do: apply(verifier, :verify_for, [token, "arbor://chat/agent/" <> target_agent, :chat]),
        else: apply(verifier, :verify, [token])

    with {:ok, ^principal} <- proof,
         {:ok, :authorized} <- recheck_conversation_owner(principal, target_agent, owner) do
      {:ok, :authorized}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  def recheck_conversation_session(_, _, _, _), do: {:error, :unauthorized}

  @doc """
  Recheck current chat access after source-owned conversation authentication.

  This is a continuation check, not proof authentication and not an execution
  grant. Only a trusted boundary that already verified fresh proof may use it.
  Accepts no caller options, never consumes a signed nonce or usage/rate token,
  and issues no receipt. Current identity, reflex, capability, delegation,
  approval and supported stateless constraints still fail closed.
  """
  @spec recheck_conversation_access(String.t(), String.t()) ::
          {:ok, :authorized} | {:error, :unauthorized}
  def recheck_conversation_access(principal, target_agent) when is_binary(target_agent) do
    resource = "arbor://chat/agent/" <> target_agent

    with :ok <- validate_conversation_authorization_request(principal, resource, :chat),
         {:ok, cap, _auth, _opts} <-
           conversation_authorization_decision(principal, resource, verify_identity: false),
         :ok <- reusable_conversation_capability(cap),
         :ok <- conversation_stateless_constraints(cap.constraints, resource) do
      {:ok, :authorized}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  def recheck_conversation_access(_, _), do: {:error, :unauthorized}

  defp validate_conversation_authorization_request(principal, resource, :chat)
       when is_binary(resource) and byte_size(resource) <= 512 do
    with :ok <- validate_issue_human_principal(principal),
         true <- String.valid?(resource),
         "arbor://chat/agent/" <> target <- resource,
         true <- byte_size(target) <= 256,
         true <- Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, target) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp validate_conversation_authorization_request(_, _, _), do: {:error, :unauthorized}

  # Same decision stages as authorize/4, stopping before its stateful effects.
  # Extract HMAC proof before context/reflex/event work. Signed proof is checked
  # once by AuthDecision; initial admission passes the decision to the existing
  # effect handler rather than evaluating that nonce again.
  defp conversation_authorization_decision(principal, resource, opts) do
    case chat_authorization_decision(principal, resource, opts) do
      {:ok, :authorized, cap, auth, safe_opts} -> {:ok, cap, auth, safe_opts}
      _ -> {:error, :unauthorized}
    end
  end

  defp chat_authorization_decision(principal, resource, opts) do
    with :ok <- require_exact_active_identity(principal),
         {:ok, proof, safe_opts} <- extract_session_token(opts),
         {:ok, ^resource} <- normalize_authorization_resource_uri(resource, safe_opts),
         reflex_context = build_reflex_context(resource, :chat, safe_opts),
         :ok <- check_reflexes(principal, reflex_context, resource, :chat, safe_opts) do
      decision_opts =
        case proof do
          token when is_binary(token) -> Keyword.put(safe_opts, :session_token, token)
          _absent -> safe_opts
        end

      case AuthDecision.evaluate(
             build_auth_context(principal, safe_opts),
             resource,
             :chat,
             decision_opts
           ) do
        {:ok, decision, cap, auth} when decision in [:authorized, :requires_approval] ->
          {:ok, decision, cap, auth, safe_opts}

        _ ->
          {:error, :unauthorized}
      end
    end
  end

  defp reusable_conversation_capability(%Capability{max_uses: nil, constraints: constraints})
       when is_map(constraints) do
    if Enum.all?(constraints, &conversation_constraint?/1),
      do: :ok,
      else: {:error, :unsupported_conversation_capability}
  end

  defp reusable_conversation_capability(_), do: {:error, :unsupported_conversation_capability}
  defp conversation_constraint?({:rate_limit, nil}), do: true
  defp conversation_constraint?({:rate_limit, limit}), do: is_integer(limit) and limit > 0
  defp conversation_constraint?({:requires_approval, value}), do: value in [nil, false, true]
  defp conversation_constraint?({:time_window, nil}), do: true

  defp conversation_constraint?({:time_window, %{start_hour: start, end_hour: finish} = window}),
    do:
      map_size(window) == 2 and is_integer(start) and start in 0..23 and
        is_integer(finish) and finish in 0..24

  defp conversation_constraint?({:allowed_paths, nil}), do: true

  defp conversation_constraint?({:allowed_paths, paths}) when is_list(paths),
    do:
      length(paths) <= 256 and
        Enum.all?(paths, fn path ->
          is_binary(path) and byte_size(path) in 1..4096 and String.valid?(path)
        end)

  defp conversation_constraint?(_), do: false

  defp conversation_stateless_constraints(constraints, resource) do
    if Config.constraint_enforcement_enabled?() do
      with :ok <- Constraint.evaluate_time_window(Map.get(constraints, :time_window)) do
        Constraint.evaluate_allowed_paths(Map.get(constraints, :allowed_paths), resource)
      end
    else
      :ok
    end
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
  Consume a conversation control receipt against the source's recomputed payload.

  Returns only the authenticated subject, pinned owner and compare-only fence.
  Payload or resource mismatch spends the receipt, preventing later reuse.
  The owning source still checks current access, engagement and operation state.
  """
  @spec consume_conversation_operation_receipt(term(), String.t(), String.t()) ::
          {:ok,
           %{
             principal_id: String.t(),
             canonical_owner_id: String.t(),
             expected_engagement_id: String.t() | nil
           }}
          | {:error, :invalid_receipt | :broker_unavailable}
  def consume_conversation_operation_receipt(receipt, resource, payload) do
    with true <- is_binary(resource),
         true <- valid_conversation_operation_payload?(payload),
         {:ok, token} <- DeliveryReceipt.bearer_token(receipt) do
      DeliveryReceiptBroker.consume_conversation_operation(
        token,
        resource,
        :crypto.hash(:sha256, payload)
      )
    else
      _ -> {:error, :invalid_receipt}
    end
  rescue
    _ -> {:error, :invalid_receipt}
  catch
    :throw, _ -> {:error, :invalid_receipt}
    :exit, _ -> {:error, :broker_unavailable}
  end

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
        if Enum.all?(keys, &(&1 in @issue_session_mode_keys)) and
             valid_issue_engagement_fence?(opts) do
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

  defp valid_issue_engagement_fence?(opts) do
    case Keyword.fetch(opts, :expected_engagement_id) do
      :error -> true
      {:ok, id} when is_binary(id) -> Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, id)
      _ -> false
    end
  end

  @doc """
  Verify a human's current explicit authority to answer a pending approval.

  The owning transition supplies the original request's scoped approval URI.
  This narrow decision requires a matching active human session proof and
  refuses capabilities that themselves require approval. It never escalates,
  preventing recursion into the approval owner, and grants no new authority.
  Only an optional exact `:task_id` constraint is accepted.
  """
  @spec authorize_approval_answer(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :approval_answer_required}
  def authorize_approval_answer(actor_id, resource_uri, session_token, opts \\ []) do
    with true <- valid_approval_answer_options?(resource_uri, opts),
         :authorized <-
           AuthDecision.check(
             actor_id,
             resource_uri,
             :execute,
             Keyword.put(opts, :session_token, session_token)
           ) do
      :ok
    else
      _ -> {:error, :approval_answer_required}
    end
  rescue
    _ -> {:error, :approval_answer_required}
  catch
    _, _ -> {:error, :approval_answer_required}
  end

  defp valid_approval_answer_options?(resource_uri, opts) do
    is_binary(resource_uri) and byte_size(resource_uri) <= 512 and
      Regex.match?(
        ~r/\Aarbor:\/\/approval\/answer(?:\/[A-Za-z0-9][A-Za-z0-9._-]*|\/task\/[A-Za-z0-9][A-Za-z0-9._-]*)?\z/,
        resource_uri
      ) and
      is_list(opts) and Keyword.keyword?(opts) and
      case opts do
        [] ->
          true

        [task_id: task_id] ->
          is_binary(task_id) and byte_size(task_id) in 1..256 and
            resource_uri == "arbor://approval/answer/task/#{task_id}"

        _ ->
          false
      end
  end

  @doc """
  Check current human authority for graduation evidence or an explicit decision.

  Uses existing target-scoped trust resources and refuses further approval
  requirements without escalating back into Trust or an approval owner.
  """
  @spec authorize_trust_graduation(String.t(), String.t(), String.t(), :read | :accept | :decline) ::
          :ok | {:error, :graduation_authority_required}
  def authorize_trust_graduation(actor_id, target_agent, token, operation) do
    with true <- is_binary(target_agent) and byte_size(target_agent) in 1..256,
         true <- Regex.match?(~r/\Aagent_[A-Za-z0-9][A-Za-z0-9._-]*\z/, target_agent),
         prefix when is_binary(prefix) <- graduation_authority_prefix(operation),
         :authorized <-
           AuthDecision.check(actor_id, prefix <> "/" <> target_agent, :execute,
             session_token: token
           ) do
      :ok
    else
      _ -> {:error, :graduation_authority_required}
    end
  rescue
    _ -> {:error, :graduation_authority_required}
  catch
    _, _ -> {:error, :graduation_authority_required}
  end

  defp graduation_authority_prefix(:read), do: "arbor://trust/read"

  defp graduation_authority_prefix(operation) when operation in [:accept, :decline],
    do: "arbor://trust/auto_promote"

  defp graduation_authority_prefix(_operation), do: nil

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

  The general gate is inert (`:allow`) unless
  `config :arbor_security, :egress_gate_enforcing`. Keyless destinations
  (`opencode_zen` / `opencode.ai`) are decided even while that switch is dark:
  they require `allow_opencode_zen_egress` independently. The security kernel
  does not consult trust policy directly; callers that want profile standing
  pass `:egress_mode` in `opts` or use `Arbor.Trust.authorize_egress/3`.
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
  Resolve a principal id to the primary it is linked to.

  Returns `{:error, _}` when no resolver is configured or the store is
  unavailable — it never falls back to the input id, so a caller cannot mistake
  an outage for a successful resolution. See `Arbor.Security.IdentityAlias`.
  """
  @spec resolve_identity_alias(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_identity_alias(id), do: Arbor.Security.IdentityAlias.resolve(id)

  @doc """
  True when two principal ids name the same person, following alias links.

  Fails closed: any resolution error returns false. Identical ids compare equal
  without consulting the store.
  """
  @spec same_principal?(String.t(), String.t()) :: boolean()
  def same_principal?(a, b), do: Arbor.Security.IdentityAlias.same_principal?(a, b)

  @doc """
  The exact-approval capability URI for connecting MCP server `name` with
  `config` on an agent's behalf (Imp review D7). `Arbor.Agent.set_mcp_config/2`
  grants it and `Arbor.Gateway.connect_mcp_server/2` requires it for an
  agent-bound connection. Any change to what runs or where it connects changes
  the URI. See `Arbor.Security.McpServerApprovalCore`.
  """
  @spec mcp_server_approval_uri(String.t(), map()) ::
          {:ok, String.t()} | {:error, :invalid_mcp_server}
  def mcp_server_approval_uri(name, config),
    do: Arbor.Security.McpServerApprovalCore.resource_uri(name, config)

  @doc "The registered prefix of every MCP server approval URI."
  @spec mcp_server_approval_prefix() :: String.t()
  def mcp_server_approval_prefix, do: Arbor.Security.McpServerApprovalCore.prefix()

  @doc """
  Mint a new interactive disclosure capability (VP-05D2A0). See
  `Arbor.Security.DisclosureCapability.issue/1` for the option contract and
  invariants.
  """
  @spec issue_disclosure_capability(keyword()) :: {:ok, Capability.t()} | {:error, atom()}
  def issue_disclosure_capability(opts), do: DisclosureCapability.issue(opts)

  if Mix.env() == :test do
    @doc false
    @spec issue_disclosure_capability_fixture(keyword()) ::
            {:ok, Capability.t()} | {:error, atom()}
    def issue_disclosure_capability_fixture(opts), do: DisclosureCapability.issue_fixture(opts)
  end

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
      # Reports the level the gate actually decides with (missing/unknown taint
      # is :untrusted there — Imp review D3), so the event cannot claim "clean"
      # for an egress the gate treated as untrusted.
      egress_taint: EgressGate.effective_taint_level(Keyword.get(opts, :egress_taint)),
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
  def grant(opts) when is_list(opts), do: grant_capability_to_principal_for_resource(opts)

  def grant(_opts), do: {:error, :invalid_request}

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

  @doc """
  Revoke a capability using a live caller-owned authority.

  The actor must hold `arbor://security/revoke/<principal_id>`. The authority
  is checked again by `SystemAuthority`, and the resulting one-use receipt is
  bound to the exact current capability payload before the store deletes it.
  """
  @spec revoke(String.t(), keyword()) :: :ok | {:error, :not_found | term()}
  def revoke(capability_id, opts \\ []), do: revoke_capability_by_id(capability_id, opts)

  @doc """
  Revoke all session-scoped capabilities for a session.

  Used to clean up capabilities granted for a session's lifetime (e.g. after a
  trust-profile change or session termination). Capabilities not bound to the
  given `session_id` are left untouched.
  """
  @spec revoke_by_session(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_by_session(session_id, opts \\ []) do
    with {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         target = {:session_id, session_id},
         {:ok, receipt} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :revoke_by_scope,
             target
           ) do
      CapabilityStore.revoke_by_session_authorized(session_id, receipt)
    end
  end

  @doc """
  Revoke all task-scoped capabilities for a task.

  VP-05D2A0 exposes both task and session revocation at the security facade.
  Agent/Voice terminal lifecycle call sites are wired by VP-05D2A1/A2.
  """
  @spec revoke_by_task(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revoke_by_task(task_id, opts \\ []) do
    with {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         target = {:task_id, task_id},
         {:ok, receipt} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :revoke_by_scope,
             target
           ) do
      CapabilityStore.revoke_by_task_authorized(task_id, receipt)
    end
  end

  @doc "Revoke all capabilities held by a principal using an authenticated actor authority."
  @spec revoke_all(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all(principal_id, opts \\ []) do
    with {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         {:ok, receipt} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :revoke_all,
             principal_id
           ) do
      CapabilityStore.revoke_all_authorized(principal_id, receipt)
    end
  end

  @doc "Cascade-revoke a capability and its descendants using an authenticated actor authority."
  @spec cascade_revoke(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cascade_revoke(capability_id, opts \\ []) do
    with {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         {:ok, fence} <- current_capability_revocation_fence(capability_id),
         {:ok, receipt} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :cascade_revoke,
             fence
           ) do
      CapabilityStore.cascade_revoke_authorized(fence, receipt)
    end
  end

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
    with {:ok, actor_authority, actor_id} <- mutation_actor(opts),
         grant_opts <-
           opts
           |> Keyword.delete(:actor_authority)
           |> Keyword.put(
             :metadata,
             metadata_with_granter(Keyword.get(opts, :metadata, %{}), actor_id)
           ),
         {:ok, safe_opts} <- validate_acknowledged_grant_opts(grant_opts),
         {:ok, cap} <- build_acknowledged_grant(safe_opts),
         {:ok, authorized_cap, receipt} <-
           SystemAuthority.authorize_capability_mutation(
             actor_authority,
             :acknowledged_grant,
             cap
           ) do
      result =
        CapabilityStore.acknowledged_put_authorized(
          authorized_cap,
          :acknowledged_grant,
          receipt
        )

      emit_acknowledged_grant_audit(result, authorized_cap)
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
          {:error, :capability_mutation_unauthorized}
  def acknowledged_revoke(_capability_id),
    do: {:error, :capability_mutation_unauthorized}

  @doc """
  Revoke the exact current capability through the acknowledged durable path.

  `:actor_authority` is required. The security authority signs a one-use
  receipt bound to the capability id, principal, and current signing-payload
  digest; the store re-reads the authoritative record before its CAS delete.
  """
  @spec acknowledged_revoke(String.t(), keyword()) ::
          {:ok, :applied, String.t()}
          | {:error,
             :invalid_request
             | :not_found
             | :capability_mutation_unauthorized
             | :capability_store_unavailable
             | :outcome_unknown}
  def acknowledged_revoke(capability_id, opts) when is_list(opts) do
    with true <- canonical_exact_capability_id?(capability_id),
         {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         {:ok, fence} <- current_capability_revocation_fence(capability_id),
         {:ok, receipt} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :revoke,
             fence
           ) do
      result = CapabilityStore.acknowledged_revoke_authorized(fence, receipt)
      emit_acknowledged_revoke_audit(result)
      result
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, {:noproc, _} -> {:error, :capability_store_unavailable}
    :exit, :timeout -> {:error, :outcome_unknown}
    :exit, _ -> {:error, :outcome_unknown}
    :throw, _ -> {:error, :outcome_unknown}
  end

  def acknowledged_revoke(_capability_id, _opts_or_fence),
    do: {:error, :capability_mutation_unauthorized}

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

  defp build_acknowledged_grant(opts) do
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
        {:ok, %{cap | signed_at: cap.granted_at}}

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
  - `:actor_authority` - Caller-owned signing authority for the current parent
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

  - `:actor_authority` - Caller-owned signing authority for the parent (required)
  - `:resources` - List of resource URIs to delegate (required)

  ## Examples

      {:ok, caps} = Security.delegate_to_agent(human_id, agent_id,
        actor_authority: authority,
        resources: ["arbor://fs/read/**", "arbor://fs/**"]
      )
  """
  @spec delegate_to_agent(String.t(), String.t(), keyword()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def delegate_to_agent(parent_id, agent_id, opts \\ []) do
    actor_authority = Keyword.get(opts, :actor_authority)
    resources = Keyword.get(opts, :resources, [])

    if is_nil(actor_authority) do
      {:error, :capability_mutation_unauthorized}
    else
      delegated =
        Enum.reduce(resources, [], fn resource_uri, acc ->
          case CapabilityStore.find_authorizing(parent_id, resource_uri) do
            {:ok, parent_cap} ->
              case delegate(parent_cap.id, agent_id, actor_authority: actor_authority) do
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

    with {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         {:ok, resource_uris} <- Role.get(role_name) do
      delegation_depth = Keyword.get(opts, :delegation_depth, 3)

      granted =
        Enum.reduce(resource_uris, [], fn resource_uri, acc ->
          case grant(
                 principal: principal_id,
                 resource: resource_uri,
                 delegation_depth: delegation_depth,
                 actor_authority: actor_authority
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
    else
      {:error, _} = error -> error
    end
  end

  # Explicit test-fixture mutations keep ordinary test setup concise without
  # reopening any production deputy. These functions are absent from non-test
  # builds, and security regression tests exercise the public fail-closed APIs.
  if Mix.env() == :test do
    @doc false
    def grant_fixture(opts) when is_list(opts) do
      with true <- Keyword.keyword?(opts),
           {:ok, cap} <-
             Capability.new(
               resource_uri: Keyword.fetch!(opts, :resource),
               principal_id: Keyword.fetch!(opts, :principal),
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
             ),
           {:ok, signed_cap} <- SystemAuthority.sign_capability_for_test(cap),
           {:ok, :stored} <- CapabilityStore.put_fixture(signed_cap) do
        Events.record_capability_granted(signed_cap)
        {:ok, signed_cap}
      else
        false -> {:error, :invalid_request}
        {:error, _} = error -> error
      end
    rescue
      _ -> {:error, :invalid_request}
    end

    def grant_fixture(_opts), do: {:error, :invalid_request}

    @doc false
    @spec put_capability_fixture(Capability.t()) :: {:ok, :stored} | {:error, term()}
    def put_capability_fixture(%Capability{} = capability),
      do: CapabilityStore.put_fixture(capability)

    @doc false
    @spec get_capability_fixture(String.t()) :: {:ok, Capability.t()} | {:error, term()}
    def get_capability_fixture(capability_id), do: CapabilityStore.get(capability_id)

    @doc false
    @spec with_capability_store_unregistered_fixture((-> term())) :: term()
    def with_capability_store_unregistered_fixture(fun) when is_function(fun, 0) do
      name = CapabilityStore
      pid = Process.whereis(name)
      if is_pid(pid), do: Process.unregister(name)

      try do
        fun.()
      after
        if is_pid(pid) and Process.alive?(pid) and Process.whereis(name) == nil do
          Process.register(pid, name)
        end
      end
    end

    @doc false
    def acknowledged_grant_fixture(opts) when is_list(opts) do
      with {:ok, safe_opts} <- validate_acknowledged_grant_opts(opts),
           {:ok, cap} <- build_acknowledged_grant(safe_opts),
           {:ok, signed_cap} <- SystemAuthority.sign_capability_for_test(cap) do
        result = CapabilityStore.acknowledged_put_fixture(signed_cap)
        emit_acknowledged_grant_audit(result, signed_cap)
        result
      end
    rescue
      _ -> {:error, :outcome_unknown}
    end

    def acknowledged_grant_fixture(_opts), do: {:error, :invalid_request}

    @doc false
    def revoke_fixture(capability_id), do: CapabilityStore.revoke_fixture(capability_id)

    @doc false
    def acknowledged_revoke_fixture(capability_id) do
      result = CapabilityStore.acknowledged_revoke_fixture(capability_id)
      emit_acknowledged_revoke_audit(result)
      result
    end

    @doc false
    def acknowledged_revoke_fixture(capability_id, fence) do
      result = CapabilityStore.acknowledged_revoke_fixture(capability_id, fence)
      emit_acknowledged_revoke_audit(result)
      result
    end

    @doc false
    def revoke_all_fixture(principal_id), do: CapabilityStore.revoke_all_fixture(principal_id)

    @doc false
    def revoke_by_session_fixture(session_id),
      do: CapabilityStore.revoke_by_session_fixture(session_id)

    @doc false
    def revoke_by_task_fixture(task_id), do: CapabilityStore.revoke_by_task_fixture(task_id)

    @doc false
    def cascade_revoke_fixture(capability_id),
      do: CapabilityStore.cascade_revoke_fixture(capability_id)

    @doc false
    def assign_role_fixture(principal_id, role_name, opts \\ []) do
      alias Arbor.Security.Role

      with {:ok, resources} <- Role.get(role_name) do
        resources
        |> Enum.reduce_while({:ok, []}, fn resource, {:ok, caps} ->
          case grant_fixture(
                 principal: principal_id,
                 resource: resource,
                 delegation_depth: Keyword.get(opts, :delegation_depth, 3)
               ) do
            {:ok, cap} -> {:cont, {:ok, [cap | caps]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, caps} -> {:ok, Enum.reverse(caps)}
          error -> error
        end
      end
    end

    @doc false
    def delegate_fixture(capability_id, new_principal_id, opts \\ []) do
      with {:ok, parent_cap} <- CapabilityStore.get(capability_id),
           private_key when is_binary(private_key) <- Keyword.get(opts, :delegator_private_key),
           {:ok, child} <-
             Capability.delegate(parent_cap, new_principal_id,
               constraints: Keyword.get(opts, :constraints, %{}),
               expires_at: Keyword.get(opts, :expires_at),
               delegation_depth:
                 Keyword.get(opts, :delegation_depth, max(parent_cap.delegation_depth - 1, 0)),
               max_uses: Keyword.get(opts, :max_uses),
               session_id: Keyword.get(opts, :session_id),
               task_id: Keyword.get(opts, :task_id),
               principal_scope: Keyword.get(opts, :principal_scope),
               metadata: Keyword.get(opts, :metadata, %{})
             ),
           record <- Signer.sign_delegation(parent_cap, child, private_key),
           child = %{child | delegation_chain: parent_cap.delegation_chain ++ [record]},
           {:ok, signed_cap} <- SystemAuthority.sign_capability_for_test(child),
           {:ok, :stored} <- CapabilityStore.put_fixture(signed_cap) do
        {:ok, signed_cap}
      else
        _ -> {:error, :capability_mutation_unauthorized}
      end
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

      :ok = Arbor.Security.register_identity(identity, actor_authority)
  """
  @spec register_identity(Identity.t()) :: {:error, :identity_registration_unauthorized}
  def register_identity(_identity), do: {:error, :identity_registration_unauthorized}

  if Mix.env() == :test do
    @doc false
    @spec register_identity_fixture(Identity.t()) :: :ok | {:error, term()}
    def register_identity_fixture(%Identity{} = identity) do
      case Registry.register_fixture(identity) do
        :ok ->
          Events.record_identity_registered(identity.agent_id)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  defp identity_status_actor(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :actor_authority) do
        {:ok, authority} when not is_nil(authority) -> {:ok, authority}
        _ -> {:error, :identity_status_mutation_unauthorized}
      end
    else
      {:error, :identity_status_mutation_unauthorized}
    end
  end

  defp identity_status_actor(_opts),
    do: {:error, :identity_status_mutation_unauthorized}

  defp identity_status_reason(opts) do
    case Keyword.get(opts, :reason) do
      nil -> {:ok, nil}
      reason when is_binary(reason) -> {:ok, reason}
      reason when is_atom(reason) -> {:ok, Atom.to_string(reason)}
      _ -> {:error, :identity_status_mutation_unauthorized}
    end
  end

  if Mix.env() == :test do
    defp normalize_fixture_reason(nil), do: nil
    defp normalize_fixture_reason(reason) when is_binary(reason), do: reason
    defp normalize_fixture_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp normalize_fixture_reason(reason), do: inspect(reason)
  end

  @doc """
  Register an agent identity using both target-key possession and an
  authenticated, currently authorized actor authority.
  """
  @spec register_identity(Identity.t(), term()) :: :ok | {:error, term()}
  def register_identity(%Identity{} = identity, actor_authority) do
    public_identity = Identity.public_only(identity)

    with {:ok, possession_proof} <- Registry.registration_proof(identity),
         {:ok, target_digest} <- Registry.registration_payload_digest(public_identity),
         {:ok, actor_attestation} <-
           SystemAuthority.issue_identity_registration_attestation(
             actor_authority,
             target_digest
           ),
         :ok <-
           Registry.register_authorized(
             public_identity,
             possession_proof,
             actor_attestation
           ) do
      Events.record_identity_registered(public_identity.agent_id)
      :ok
    end
  end

  def register_identity(_identity, _actor_authority),
    do: {:error, :identity_registration_unauthorized}

  @doc """
  Re-register a public agent identity whose private key is already held by the
  encrypted signing-key store. The store signs the registry's exact
  domain-separated registration payload internally; private key bytes never
  leave the security boundary.
  """
  @spec register_stored_identity(Identity.t()) ::
          {:error, :identity_registration_unauthorized}
  def register_stored_identity(_identity), do: {:error, :identity_registration_unauthorized}

  @spec register_stored_identity(Identity.t(), term()) :: :ok | {:error, term()}
  def register_stored_identity(%Identity{} = identity, actor_authority) do
    public_identity = Identity.public_only(identity)

    with {:ok, possession_proof} <- SigningKeyStore.build_registration_proof(public_identity) do
      register_stored_identity(public_identity, actor_authority, possession_proof)
    end
  end

  def register_stored_identity(_identity, _actor_authority),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_stored_identity(Identity.t(), term(), binary()) :: :ok | {:error, term()}
  def register_stored_identity(
        %Identity{} = identity,
        actor_authority,
        possession_proof
      )
      when is_binary(possession_proof) do
    public_identity = Identity.public_only(identity)

    with {:ok, target_digest} <- Registry.registration_payload_digest(public_identity),
         {:ok, actor_attestation} <-
           SystemAuthority.issue_identity_registration_attestation(
             actor_authority,
             target_digest
           ),
         :ok <-
           Registry.register_authorized(
             public_identity,
             possession_proof,
             actor_attestation
           ) do
      Events.record_identity_registered(public_identity.agent_id)
      :ok
    end
  end

  def register_stored_identity(_identity, _actor_authority, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_scheduler_identity(Identity.t(), binary()) :: :ok | {:error, term()}
  def register_scheduler_identity(%Identity{} = identity, possession_proof)
      when is_binary(possession_proof) do
    public_identity = Identity.public_only(identity)

    case Registry.register_scheduler_identity(public_identity, possession_proof) do
      :ok ->
        Events.record_identity_registered(public_identity.agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  def register_scheduler_identity(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec register_trust_capability_grant_identity(Identity.t(), binary()) ::
          :ok | {:error, term()}
  def register_trust_capability_grant_identity(%Identity{} = identity, possession_proof)
      when is_binary(possession_proof) do
    public_identity = Identity.public_only(identity)

    case Registry.register_trust_capability_grant_identity(public_identity, possession_proof) do
      :ok ->
        Events.record_identity_registered(public_identity.agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  def register_trust_capability_grant_identity(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  # Self-registration for the D4 system lifecycle principal. The Registry admits
  # only the configured `:system_lifecycle_owner` process and a possession proof
  # for the identity's own key; it confers no capabilities.
  @spec register_system_lifecycle_identity(Identity.t(), binary()) :: :ok | {:error, term()}
  def register_system_lifecycle_identity(%Identity{} = identity, possession_proof)
      when is_binary(possession_proof) do
    public_identity = Identity.public_only(identity)

    case Registry.register_system_lifecycle_identity(public_identity, possession_proof) do
      :ok ->
        Events.record_identity_registered(public_identity.agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  def register_system_lifecycle_identity(_identity, _possession_proof),
    do: {:error, :identity_registration_unauthorized}

  @doc false
  @spec build_stored_identity_registration_proof(Identity.t()) ::
          {:ok, binary()} | {:error, term()}
  def build_stored_identity_registration_proof(%Identity{} = identity) do
    identity
    |> Identity.public_only()
    |> SigningKeyStore.build_registration_proof()
  end

  def build_stored_identity_registration_proof(_identity),
    do: {:error, :identity_registration_unauthorized}

  @doc """
  Whether OIDC is configured with at least one provider or a device flow.

  Exposed so callers outside this library can tell "no authenticated login is
  possible here" from "a login exists and simply has not happened". Notably CLI
  Mix tasks use it to decide whether resolving a local-operator principal is
  legitimate — it never is once a real login path exists.
  """
  @spec oidc_enabled?() :: boolean()
  def oidc_enabled?, do: Arbor.Security.OIDC.Config.enabled?()

  @doc """
  The local operator's `human_` principal id, derived without creating anything.

  Same claims as `create_local_human_identity/1`, so it returns exactly the id
  `mix arbor.user.init` produced — that id is a deterministic hash of
  `iss:sub`, not stored state.

  Read-only ON PURPOSE. Callers that merely need to NAME the operator (a CLI
  turn identifying its sender) must not mint an identity as a side effect of
  asking who they are; and if `arbor.user.init` was never run, the derived id
  simply is not registered and downstream checks fail closed.
  """
  @spec local_human_principal_id(keyword()) :: String.t()
  def local_human_principal_id(opts \\ []) do
    Arbor.Security.OIDC.IdentityStore.derive_agent_id(local_human_claims(opts))
  end

  @doc """
  Create (or load) the LOCAL human identity for a single-operator dev install.

  **This is a deliberate, gated carve-out from `:oidc_proof_required`.**
  `Identity.Registry.register/2` refuses `human_` identities precisely so a
  human principal cannot be minted without an authenticated login. That is the
  right rule for production, and this function does not change it — it exists
  because a laptop with no identity provider has no way to obtain that proof,
  and is otherwise unable to complete a first turn.

  Production expects a working OIDC provider. This path must never be reachable
  there, and refuses on its own rather than trusting callers:

    * `config :arbor_security, :allow_local_human_identity` must be `true`
      (default `false`; set only in `dev.exs`)
    * no OIDC provider may be configured — once a real login exists, use it

  The identity is derived from local claims (`iss: "arbor://local"`), so it is
  deterministic and idempotent: the same host+user always yields the same
  `human_<hash>`, and re-running loads the existing keypair rather than
  minting a second one. It gets a real Ed25519 + X25519 keypair stored
  encrypted through `SigningKeyStore`, exactly like an OIDC-derived human.

  It is intended as the PRIMARY account a first-time operator accumulates
  grants under; later OIDC logins derive their own id and are folded onto it
  with `mix arbor.user.link`.

  Returns `{:ok, identity, :created | :existing}`.
  """
  @spec create_local_human_identity(keyword()) ::
          {:ok, Identity.t(), :created | :existing} | {:error, atom()}
  def create_local_human_identity(opts \\ []) do
    with :ok <- admit_local_human_identity(),
         {:ok, identity, status} <-
           Arbor.Security.OIDC.IdentityStore.load_or_create_local(local_human_claims(opts)),
         :ok <- ensure_local_human_registered(identity) do
      {:ok, identity, status}
    end
  end

  # `load_or_create/1` stores the keypair but never registers the identity —
  # `AuthDecision` resolves every principal through `identity_status/1`, so an
  # unregistered identity holds capabilities it can never exercise. Registering
  # is idempotent here: an already-registered identity is success, not an error.
  defp ensure_local_human_registered(identity) do
    case Registry.register_local_human(Identity.public_only(identity)) do
      :ok -> :ok
      {:error, {:already_registered, _id}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_local_human_identity do
    cond do
      Application.get_env(:arbor_security, :allow_local_human_identity, false) != true ->
        {:error, :local_human_identity_disabled}

      oidc_enabled?() ->
        {:error, :oidc_configured}

      true ->
        :ok
    end
  end

  # Stable per host+user so the derived id is idempotent across runs. Not a
  # secret and not a proof of anything — it is a local namespace, which is
  # exactly why this path is gated rather than general.
  defp local_human_claims(opts) do
    user =
      Keyword.get(opts, :user) || System.get_env("USER") || System.get_env("USERNAME") ||
        "operator"

    host = Keyword.get(opts, :host) || elem(:inet.gethostname(), 1) |> to_string()

    %{
      iss: "arbor://local",
      sub: "#{user}@#{host}",
      name: Keyword.get(opts, :name, "#{user} (local operator)")
    }
  end

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

    result =
      case identity do
        %Identity{private_key: private_key} when is_binary(private_key) ->
          Registry.register_oidc(identity, id_token, provider_config)

        %Identity{} ->
          with {:ok, proof} <-
                 SigningKeyStore.build_oidc_registration_proof(
                   public_identity,
                   id_token,
                   provider_config
                 ) do
            Registry.register_oidc_proven(public_identity, id_token, provider_config, proof)
          end

        _ ->
          {:error, :invalid_oidc_registration}
      end

    case result do
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
  @spec deregister_identity(String.t()) :: {:error, :identity_status_mutation_unauthorized}
  def deregister_identity(_agent_id), do: {:error, :identity_status_mutation_unauthorized}

  @spec deregister_identity(String.t(), keyword()) :: :ok | {:error, term()}
  def deregister_identity(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    with {:ok, actor_authority} <- identity_status_actor(opts),
         {:ok, digest} <- Registry.identity_status_payload_digest(agent_id, :deregister, nil),
         {:ok, attestation} <-
           SystemAuthority.issue_identity_status_mutation_attestation(
             actor_authority,
             :deregister,
             agent_id,
             digest
           ),
         :ok <- Registry.deregister_authorized(agent_id, attestation) do
      :ok
    end
  end

  def deregister_identity(_agent_id, _opts),
    do: {:error, :identity_status_mutation_unauthorized}

  if Mix.env() == :test do
    @doc false
    def deregister_identity_fixture(agent_id) when is_binary(agent_id),
      do: Registry.deregister_fixture(agent_id)
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

  if Mix.env() == :test do
    @doc false
    @spec sign_ed25519_fixture(binary(), binary()) :: binary()
    def sign_ed25519_fixture(message, private_key), do: Crypto.sign(message, private_key)
  end

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
  def suspend_identity(agent_id, opts \\ [])

  def suspend_identity(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    with {:ok, actor_authority} <- identity_status_actor(opts),
         {:ok, reason} <- identity_status_reason(opts),
         {:ok, digest} <- Registry.identity_status_payload_digest(agent_id, :suspend, reason),
         {:ok, attestation} <-
           SystemAuthority.issue_identity_status_mutation_attestation(
             actor_authority,
             :suspend,
             agent_id,
             digest
           ) do
      case Registry.suspend_authorized(agent_id, reason, attestation) do
        :ok ->
          Events.record_identity_suspended(agent_id, reason)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  def suspend_identity(_agent_id, _opts),
    do: {:error, :identity_status_mutation_unauthorized}

  @doc """
  Resume a suspended identity.

  Sets the identity status back to `:active`. Only works for `:suspended`
  identities — revoked identities cannot be resumed.

  ## Examples

      :ok = Arbor.Security.resume_identity("agent_001")
  """
  @spec resume_identity(String.t()) :: {:error, :identity_status_mutation_unauthorized}
  def resume_identity(_agent_id), do: {:error, :identity_status_mutation_unauthorized}

  @spec resume_identity(String.t(), keyword()) :: :ok | {:error, term()}
  def resume_identity(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    with {:ok, actor_authority} <- identity_status_actor(opts),
         {:ok, digest} <- Registry.identity_status_payload_digest(agent_id, :resume, nil),
         {:ok, attestation} <-
           SystemAuthority.issue_identity_status_mutation_attestation(
             actor_authority,
             :resume,
             agent_id,
             digest
           ) do
      case Registry.resume_authorized(agent_id, attestation) do
        :ok ->
          Events.record_identity_resumed(agent_id)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  def resume_identity(_agent_id, _opts),
    do: {:error, :identity_status_mutation_unauthorized}

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
  def revoke_identity(agent_id, opts \\ [])

  def revoke_identity(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    with {:ok, actor_authority} <- identity_status_actor(opts),
         {:ok, reason} <- identity_status_reason(opts),
         {:ok, digest} <- Registry.identity_status_payload_digest(agent_id, :revoke, reason),
         {:ok, status_attestation} <-
           SystemAuthority.issue_identity_status_mutation_attestation(
             actor_authority,
             :revoke,
             agent_id,
             digest
           ),
         {:ok, capability_attestation} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :revoke_all,
             agent_id
           ),
         {:ok, _registry_count} <-
           Registry.revoke_identity_authorized(agent_id, reason, status_attestation) do
      case CapabilityStore.revoke_all_authorized(agent_id, capability_attestation) do
        {:ok, cascade_count} ->
          Events.record_identity_revoked(agent_id, reason, cascade_count)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  def revoke_identity(_agent_id, _opts),
    do: {:error, :identity_status_mutation_unauthorized}

  if Mix.env() == :test do
    @doc false
    def suspend_identity_fixture(agent_id, reason \\ nil) do
      case Registry.suspend_fixture(agent_id, normalize_fixture_reason(reason)) do
        :ok ->
          Events.record_identity_suspended(agent_id, normalize_fixture_reason(reason))
          :ok

        other ->
          other
      end
    end

    @doc false
    def resume_identity_fixture(agent_id) do
      case Registry.resume_fixture(agent_id) do
        :ok ->
          Events.record_identity_resumed(agent_id)
          :ok

        other ->
          other
      end
    end

    @doc false
    def revoke_identity_fixture(agent_id, reason \\ nil) do
      normalized = normalize_fixture_reason(reason)

      case Registry.revoke_identity_fixture(agent_id, normalized) do
        {:ok, cascade_count} ->
          Events.record_identity_revoked(agent_id, normalized, cascade_count)
          :ok

        other ->
          other
      end
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
    check_if_principal_has_capability_for_resource_action(
      principal_id,
      resource_uri,
      action,
      opts,
      :none
    )
  end

  defp check_if_principal_has_capability_for_resource_action(
         principal_id,
         resource_uri,
         action,
         opts,
         effect
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
               {:ok, approval_receipt, decision_opts} <-
                 admit_approval_receipt(
                   principal_id,
                   resource_uri,
                   action,
                   decision_opts
                 ),
               event_opts = redact_approval_opts(safe_opts),
               reflex_context = build_reflex_context(resource_uri, action, event_opts),
               :ok <-
                 check_reflexes(principal_id, reflex_context, resource_uri, action, event_opts) do
            auth = build_auth_context(principal_id, event_opts)

            case AuthDecision.evaluate(auth, resource_uri, action, decision_opts) do
              {:ok, :authorized, cap, auth} ->
                with :ok <-
                       consume_approval_receipt(
                         approval_receipt,
                         principal_id,
                         resource_uri,
                         action
                       ) do
                  handle_authorized(
                    cap,
                    auth,
                    principal_id,
                    resource_uri,
                    action,
                    event_opts,
                    effect
                  )
                else
                  {:error, reason} = error ->
                    Events.record_authorization_denied(
                      principal_id,
                      resource_uri,
                      reason,
                      event_opts
                    )

                    error
                end

              {:ok, :requires_approval, cap, auth} ->
                handle_requires_approval(
                  cap,
                  auth,
                  principal_id,
                  resource_uri,
                  action,
                  event_opts,
                  effect
                )

              {:error, reason, _auth} ->
                Events.record_authorization_denied(principal_id, resource_uri, reason, event_opts)
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

  @doc "Return the canonical digest used to bind one approval to exact arguments."
  @spec approval_argument_digest(term()) :: {:ok, String.t()} | {:error, atom()}
  def approval_argument_digest(arguments) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(arguments) do
      {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    else
      _ -> {:error, :invalid_approval_arguments}
    end
  rescue
    _ -> {:error, :invalid_approval_arguments}
  catch
    _, _ -> {:error, :invalid_approval_arguments}
  end

  @doc "Issue a short-lived signed one-use receipt for an approved exact invocation."
  @spec issue_approval_receipt(String.t(), String.t(), atom() | nil, String.t(), term()) ::
          {:ok, map()} | {:error, atom()}
  def issue_approval_receipt(principal_id, resource_uri, action, request_id, arguments) do
    with {:ok, digest} <- approval_argument_digest(arguments) do
      ApprovalReceiptBroker.issue(principal_id, resource_uri, action, digest, request_id)
    end
  end

  @doc false
  @spec claim_approval_receipt_issuer(keyword()) :: {:ok, binary()} | {:error, atom()}
  def claim_approval_receipt_issuer(opts \\ []), do: ApprovalReceiptBroker.claim_issuer(opts)

  @doc false
  @spec issue_approval_receipt(
          String.t(),
          String.t(),
          atom() | nil,
          String.t(),
          term(),
          binary()
        ) :: {:ok, map()} | {:error, atom()}
  def issue_approval_receipt(
        principal_id,
        resource_uri,
        action,
        request_id,
        arguments,
        issuer_custody
      ) do
    with {:ok, digest} <- approval_argument_digest(arguments) do
      ApprovalReceiptBroker.issue_authorized(
        principal_id,
        resource_uri,
        action,
        digest,
        request_id,
        issuer_custody
      )
    end
  end

  @doc false
  def confirm_consumed_approval_receipt(
        receipt,
        principal_id,
        resource_uri,
        action,
        argument_digest
      ) do
    ApprovalReceiptBroker.confirm_security_consumed(
      receipt,
      principal_id,
      resource_uri,
      action,
      argument_digest
    )
  end

  if Mix.env() == :test do
    @doc false
    defdelegate build_identity_registration_proof_fixture(identity),
      to: Registry,
      as: :registration_proof

    @doc false
    defdelegate issue_approval_receipt_fixture(
                  principal_id,
                  resource_uri,
                  action,
                  argument_digest,
                  request_id
                ),
                to: ApprovalReceiptBroker,
                as: :issue_for_test

    @doc false
    defdelegate consume_approval_receipt_fixture(
                  receipt,
                  principal_id,
                  resource_uri,
                  action,
                  argument_digest
                ),
                to: ApprovalReceiptBroker,
                as: :consume
  end

  defp admit_approval_receipt(principal_id, resource_uri, action, opts) do
    receipts = Keyword.get_values(opts, :approved_invocation)
    digests = Keyword.get_values(opts, :argument_digest)
    stripped = Keyword.drop(opts, [:approved_invocation, :argument_digest])

    case {receipts, digests} do
      {[], []} ->
        {:ok, :none, stripped}

      {[], [digest]} when is_binary(digest) ->
        {:ok, :none, stripped}

      {[receipt], [digest]} when is_binary(digest) ->
        case ApprovalReceiptBroker.verify(receipt, principal_id, resource_uri, action, digest) do
          :ok ->
            {:ok, %{receipt: receipt, digest: digest},
             Keyword.put(stripped, :approved_invocation, :security_verified)}

          {:error, _reason} ->
            {:error, :invalid_approval_receipt}
        end

      _ ->
        {:error, :invalid_approval_receipt}
    end
  rescue
    _ -> {:error, :invalid_approval_receipt}
  catch
    _, _ -> {:error, :invalid_approval_receipt}
  end

  defp consume_approval_receipt(:none, _principal, _resource, _action), do: :ok

  defp consume_approval_receipt(
         %{receipt: receipt, digest: digest},
         principal,
         resource,
         action
       ) do
    ApprovalReceiptBroker.consume(receipt, principal, resource, action, digest)
  end

  defp redact_approval_opts(opts) do
    Keyword.drop(opts, [:approved_invocation, :argument_digest])
  rescue
    _ -> []
  end

  # Side effects for authorized decisions
  defp handle_authorized(cap, _auth, principal_id, resource_uri, action, opts) do
    handle_authorized(cap, nil, principal_id, resource_uri, action, opts, :none)
  end

  defp handle_authorized(cap, _auth, principal_id, resource_uri, action, opts, effect) do
    safe_opts = Keyword.delete(opts, @source_owned_egress_opt)

    # Stateful constraint checks (rate limiting) — cap was already found by AuthDecision
    with :ok <- enforce_source_owned_egress_expectation(cap, opts),
         :ok <-
           if(cap, do: maybe_enforce_constraints(cap, principal_id, resource_uri), else: :ok) do
      # FileGuard for fs:// URIs — runs explicit (caller passed :file_path)
      # OR implicit (we have a matched cap and the URI's path-part is the
      # implicit file_path) defense-in-depth normalization.
      file_guard_result =
        maybe_check_file_guard_for_effect(
          effect,
          principal_id,
          resource_uri,
          safe_opts,
          cap
        )

      case normalize_file_guard_result(file_guard_result) do
        :ok ->
          finalize_authorized_effect(
            cap,
            principal_id,
            resource_uri,
            action,
            safe_opts,
            effect
          )

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

  defp finalize_authorized_effect(
         cap,
         principal_id,
         resource_uri,
         action,
         safe_opts,
         effect
       ) do
    with :ok <- if(cap, do: maybe_consume_max_use(cap), else: :ok) do
      effect
      |> apply_authorized_effect(cap)
      |> record_authorized_effect(
        cap,
        principal_id,
        resource_uri,
        action,
        safe_opts
      )
    else
      {:error, reason} = error ->
        Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
        error
    end
  end

  defp record_authorized_effect(
         {:ok, :authorized} = result,
         cap,
         principal_id,
         resource_uri,
         action,
         safe_opts
       ) do
    record_authorized_effect_success(
      result,
      cap,
      principal_id,
      resource_uri,
      action,
      safe_opts
    )
  end

  defp record_authorized_effect(
         {:ok, :authorized, _effect_result} = result,
         cap,
         principal_id,
         resource_uri,
         action,
         safe_opts
       ) do
    record_authorized_effect_success(
      result,
      cap,
      principal_id,
      resource_uri,
      action,
      safe_opts
    )
  end

  defp record_authorized_effect(
         {:error, reason} = error,
         _cap,
         principal_id,
         resource_uri,
         _action,
         safe_opts
       ) do
    Events.record_authorization_denied(principal_id, resource_uri, reason, safe_opts)
    error
  end

  defp record_authorized_effect(
         _unexpected,
         _cap,
         principal_id,
         resource_uri,
         _action,
         safe_opts
       ) do
    Events.record_authorization_denied(
      principal_id,
      resource_uri,
      :invalid_authorized_effect,
      safe_opts
    )

    {:error, :invalid_authorized_effect}
  end

  defp record_authorized_effect_success(
         result,
         cap,
         principal_id,
         resource_uri,
         action,
         safe_opts
       ) do
    Events.record_authorization_granted(principal_id, resource_uri, safe_opts)

    if cap,
      do: maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, safe_opts)

    result
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
    handle_requires_approval(cap, nil, principal_id, resource_uri, action, opts, :none)
  end

  defp handle_requires_approval(
         cap,
         _auth,
         principal_id,
         resource_uri,
         action,
         opts,
         effect
       ) do
    safe_opts = Keyword.delete(opts, @source_owned_egress_opt)

    # Standing capability constraints escalate as-is. Dynamic egress :ask uses a
    # request-local copy with requires_approval set so Escalation.maybe_escalate/4
    # does not treat unconstrained caps as already graduated.
    {escalate_cap, escalation_opts} =
      if capability_requires_approval?(cap) do
        {cap,
         safe_opts
         |> Keyword.put_new(:gate, :capability_constraint)
         |> Keyword.put_new(:reason, :capability_requires_approval)}
      else
        {request_local_approval_capability(cap),
         safe_opts
         |> Keyword.put_new(:gate, :egress_policy)
         |> Keyword.put_new(:reason, :egress_requires_approval)}
      end

    with :ok <- enforce_source_owned_egress_expectation(cap, opts) do
      case Arbor.Security.Escalation.maybe_escalate(
             escalate_cap,
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
               fg_result <-
                 maybe_check_file_guard_for_effect(
                   effect,
                   principal_id,
                   resource_uri,
                   safe_opts,
                   cap
                 ),
               :ok <- normalize_file_guard_result(fg_result) do
            finalize_authorized_effect(
              cap,
              principal_id,
              resource_uri,
              action,
              safe_opts,
              effect
            )
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

  defp capability_requires_approval?(cap) do
    constraints = Map.get(cap, :constraints)

    is_map(constraints) and
      (constraints[:requires_approval] == true or
         constraints["requires_approval"] == true)
  end

  defp request_local_approval_capability(cap) do
    constraints =
      case Map.get(cap, :constraints) do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{cap | constraints: Map.put(constraints, :requires_approval, true)}
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
    with {:ok, actor_authority, actor_id} <- mutation_actor(opts),
         {:ok, cap} <- build_grant_capability(opts, actor_id),
         {:ok, authorized_cap, receipt} <-
           SystemAuthority.authorize_capability_mutation(actor_authority, :grant, cap),
         {:ok, signed_cap} <- CapabilityStore.put_authorized(authorized_cap, :grant, receipt) do
      Events.record_capability_granted(signed_cap)
      {:ok, signed_cap}
    else
      {:error, _} = error -> error
    end
  end

  defp build_grant_capability(opts, actor_id) when is_list(opts) and is_binary(actor_id) do
    with true <- Keyword.keyword?(opts),
         principal_id when is_binary(principal_id) <- Keyword.get(opts, :principal),
         resource_uri when is_binary(resource_uri) <- Keyword.get(opts, :resource) do
      Capability.new(
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
        metadata: metadata_with_granter(Keyword.get(opts, :metadata, %{}), actor_id)
      )
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp build_grant_capability(_opts, _actor_id), do: {:error, :invalid_request}

  @impl Arbor.Contracts.API.Security
  def revoke_capability_by_id(capability_id, opts) do
    with {:ok, actor_authority, _actor_id} <- mutation_actor(opts),
         {:ok, fence} <- current_capability_revocation_fence(capability_id),
         {:ok, receipt} <-
           SystemAuthority.issue_capability_revocation_attestation(
             actor_authority,
             :revoke,
             fence
           ) do
      case CapabilityStore.revoke_authorized(fence, receipt) do
        :ok ->
          Events.record_capability_revoked(capability_id)
          :ok

        error ->
          error
      end
    end
  end

  @impl Arbor.Contracts.API.Security
  def list_capabilities_for_principal(principal_id, opts) do
    CapabilityStore.list_for_principal(principal_id, opts)
  end

  @impl Arbor.Contracts.API.Security
  def delegate_capability_from_principal_to_principal(capability_id, new_principal_id, opts) do
    with {:ok, parent_cap} <- CapabilityStore.get(capability_id),
         {:ok, actor_authority, actor_id} <- mutation_actor(opts),
         true <- actor_id == parent_cap.principal_id,
         # Create the delegated capability once (without delegation record)
         {:ok, new_cap} <-
           Capability.delegate(parent_cap, new_principal_id,
             constraints: Keyword.get(opts, :constraints, %{}),
             expires_at: Keyword.get(opts, :expires_at),
             not_before: Keyword.get(opts, :not_before),
             delegation_depth:
               Keyword.get(opts, :delegation_depth, max(parent_cap.delegation_depth - 1, 0)),
             max_uses: Keyword.get(opts, :max_uses),
             allowed_delegatees: Keyword.get(opts, :allowed_delegatees),
             session_id: Keyword.get(opts, :session_id),
             task_id: Keyword.get(opts, :task_id),
             principal_scope: Keyword.get(opts, :principal_scope),
             metadata: metadata_with_granter(Keyword.get(opts, :metadata, %{}), actor_id)
           ),
         # Sign a delegation record over the new cap's payload
         {:ok, delegation_record} <-
           SigningAuthorityBroker.sign_delegation(actor_authority, parent_cap, new_cap),
         # Attach the chain to the SAME capability (preserving id/timestamps)
         new_cap_with_chain = %{
           new_cap
           | delegation_chain: parent_cap.delegation_chain ++ [delegation_record]
         },
         # The claimed delegator is selected from the current parent capability,
         # never from caller input. Verify the complete chain before the system
         # authority signs or the store observes it; possession of an unrelated
         # private key must not create a record attributed to the parent.
         :ok <- Signer.verify_delegation_chain(new_cap_with_chain, &Registry.lookup/1),
         {:ok, authorized_cap, receipt} <-
           SystemAuthority.authorize_capability_mutation(
             actor_authority,
             :delegate,
             new_cap_with_chain
           ),
         {:ok, signed_cap} <-
           CapabilityStore.put_authorized(authorized_cap, :delegate, receipt) do
      Events.record_capability_granted(signed_cap)
      Events.record_delegation_created(parent_cap.principal_id, new_principal_id, signed_cap.id)
      {:ok, signed_cap}
    else
      false -> {:error, :capability_mutation_unauthorized}
      {:error, _} = error -> error
    end
  end

  defp mutation_actor(opts) when is_list(opts) do
    with authority when not is_nil(authority) <- Keyword.get(opts, :actor_authority),
         {:ok, %{principal_id: actor_id}} <- SigningAuthorityBroker.owned_identity(authority) do
      {:ok, authority, actor_id}
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  defp mutation_actor(_opts), do: {:error, :capability_mutation_unauthorized}

  defp metadata_with_granter(metadata, actor_id) when is_map(metadata) do
    metadata
    |> Map.delete(:granter_id)
    |> Map.delete("granter_id")
    |> Map.put("granter_id", actor_id)
  end

  defp metadata_with_granter(_metadata, _actor_id), do: %{}

  defp current_capability_revocation_fence(capability_id) when is_binary(capability_id) do
    with {:ok, %Capability{} = cap} <- CapabilityStore.get(capability_id) do
      {:ok,
       %{
         capability_id: cap.id,
         principal_id: cap.principal_id,
         capability_digest:
           cap
           |> Capability.signing_payload()
           |> then(&:crypto.hash(:sha256, &1))
           |> Base.encode16(case: :lower)
       }}
    end
  rescue
    _ -> {:error, :capability_mutation_unauthorized}
  catch
    _, _ -> {:error, :capability_mutation_unauthorized}
  end

  defp current_capability_revocation_fence(_capability_id),
    do: {:error, :capability_mutation_unauthorized}

  # ===========================================================================
  # Identity contract implementations
  # ===========================================================================

  @impl Arbor.Contracts.API.Identity
  def generate_cryptographic_identity_keypair(opts) do
    Identity.generate(opts)
  end

  @impl Arbor.Contracts.API.Identity
  def register_agent_identity_with_public_key(%Identity{}),
    do: {:error, :identity_registration_unauthorized}

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
    # The cluster replay gate is NOT consulted here: Verifier.verify/1 already
    # gates as its first step. Gating twice doubled the ReplayPeers reads per
    # verification, and the early bail skipped record_verification_failure, so
    # gate refusals never reached the security events journal.
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
  Check whether the capability authorization service is available.

  Cross-application callers use this semantic facade instead of depending on
  the internal capability-store process name.
  """
  @spec capability_authorization_available?() :: boolean()
  def capability_authorization_available?, do: Process.whereis(CapabilityStore) != nil

  @doc "Whether a module is part of the Security runtime and must not be hot-loaded."
  @spec protected_runtime_module?(module()) :: boolean()
  def protected_runtime_module?(module) when is_atom(module) do
    module in [__MODULE__, Arbor.Security.Kernel, CapabilityStore]
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

  @doc "Legacy raw-prefix mutation is retired; providers register their immutable projection."
  @spec register_uri_prefix(String.t()) :: {:error, :uri_mutation_unauthorized}
  def register_uri_prefix(_prefix), do: {:error, :uri_mutation_unauthorized}

  @doc "Register the immutable URI-prefix projection of a configured provider module."
  @spec register_uri_provider(module()) :: :ok | {:error, term()}
  def register_uri_provider(provider) when is_atom(provider),
    do: UriRegistry.register_provider(provider)

  def register_uri_provider(_provider), do: {:error, :uri_mutation_unauthorized}

  @doc "Look up an enrolled, active capability issuer and its envelope."
  @spec lookup_issuer(String.t()) :: {:ok, map()} | {:error, atom()}
  def lookup_issuer(issuer_id) when is_binary(issuer_id), do: IssuerRegistry.lookup(issuer_id)
  def lookup_issuer(_issuer_id), do: {:error, :not_found}

  @doc "Register a capability issuer through an authenticated actor authority."
  @spec register_issuer(String.t(), Capability.t() | [Capability.t()], keyword()) ::
          :ok | {:error, term()}
  def register_issuer(issuer_id, envelopes, opts \\ []) when is_list(opts) do
    envelope_list = List.wrap(envelopes)
    actor_authority = Keyword.get(opts, :actor_authority)
    actor_proof = Keyword.get(opts, :actor_proof)
    registry_opts = Keyword.drop(opts, [:actor_authority, :actor_proof])

    with :ok <- validate_exactly_one_actor_proof(actor_authority, actor_proof),
         {:ok, digest} <-
           IssuerRegistry.mutation_payload_digest(
             :register,
             issuer_id,
             envelope_list,
             registry_opts
           ),
         {:ok, proof} <-
           issue_issuer_actor_attestation(actor_authority, actor_proof, :register, digest) do
      IssuerRegistry.register_authorized(issuer_id, envelope_list, registry_opts, proof)
    else
      {:error, _} = error -> error
      _ -> {:error, :issuer_mutation_unauthorized}
    end
  end

  @doc "Update a capability issuer's envelopes through an authenticated actor authority."
  @spec update_issuer_envelopes(String.t(), [Capability.t()], keyword()) ::
          :ok | {:error, term()}
  def update_issuer_envelopes(issuer_id, envelopes, opts \\ []) when is_list(opts) do
    actor_authority = Keyword.get(opts, :actor_authority)
    actor_proof = Keyword.get(opts, :actor_proof)
    registry_opts = Keyword.drop(opts, [:actor_authority, :actor_proof])

    with :ok <- validate_exactly_one_actor_proof(actor_authority, actor_proof),
         {:ok, digest} <-
           IssuerRegistry.mutation_payload_digest(:update, issuer_id, envelopes, registry_opts),
         {:ok, proof} <-
           issue_issuer_actor_attestation(actor_authority, actor_proof, :update, digest) do
      IssuerRegistry.update_envelopes_authorized(
        issuer_id,
        envelopes,
        registry_opts,
        proof
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :issuer_mutation_unauthorized}
    end
  end

  @doc "Revoke a capability issuer through an authenticated actor authority."
  @spec revoke_issuer(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def revoke_issuer(issuer_id, reason \\ nil, opts \\ []) when is_list(opts) do
    actor_authority = Keyword.get(opts, :actor_authority)
    actor_proof = Keyword.get(opts, :actor_proof)

    with :ok <- validate_exactly_one_actor_proof(actor_authority, actor_proof),
         true <- Enum.sort(Keyword.keys(opts)) in [[:actor_authority], [:actor_proof]],
         {:ok, digest} <- IssuerRegistry.mutation_payload_digest(:revoke, issuer_id, reason, []),
         {:ok, proof} <-
           issue_issuer_actor_attestation(actor_authority, actor_proof, :revoke, digest) do
      IssuerRegistry.revoke_authorized(issuer_id, reason, proof)
    else
      false -> {:error, :issuer_mutation_unauthorized}
      {:error, _} = error -> error
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec list_issuers_fixture() :: [map()] | {:error, term()}
    def list_issuers_fixture, do: IssuerRegistry.list()

    @doc false
    @spec register_issuer_fixture(String.t(), Capability.t() | [Capability.t()], keyword()) ::
            :ok | {:error, term()}
    def register_issuer_fixture(issuer_id, envelopes, opts \\ []),
      do: IssuerRegistry.register_fixture(issuer_id, envelopes, opts)

    @doc false
    @spec revoke_issuer_fixture(String.t(), String.t() | nil) :: :ok | {:error, term()}
    def revoke_issuer_fixture(issuer_id, reason \\ nil),
      do: IssuerRegistry.revoke_fixture(issuer_id, reason)
  end

  @doc "Return the canonical full issuer-mutation digest used by actor proofs."
  @spec issuer_mutation_payload_digest(atom(), String.t(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def issuer_mutation_payload_digest(operation, issuer_id, payload, opts \\ []) do
    IssuerRegistry.mutation_payload_digest(operation, issuer_id, payload, opts)
  end

  defp validate_exactly_one_actor_proof(authority, proof) do
    case {is_nil(authority), is_nil(proof)} do
      {false, true} -> :ok
      {true, false} -> :ok
      _ -> {:error, :issuer_mutation_unauthorized}
    end
  end

  defp issue_issuer_actor_attestation(authority, nil, operation, digest),
    do: SystemAuthority.issue_issuer_mutation_attestation(authority, operation, digest)

  defp issue_issuer_actor_attestation(nil, proof, operation, digest),
    do: SystemAuthority.issue_issuer_mutation_attestation_proof(proof, operation, digest)

  defp issue_issuer_actor_attestation(_authority, _proof, _operation, _digest),
    do: {:error, :issuer_mutation_unauthorized}

  # ===========================================================================
  # Keychain (Seed/Host Phase 4)
  # ===========================================================================

  @doc """
  Endorse a registered self-certifying identity through an authenticated actor.
  """
  @spec endorse_agent(Identity.t()) :: {:error, :identity_endorsement_unauthorized}
  def endorse_agent(%Identity{}), do: {:error, :identity_endorsement_unauthorized}

  @spec endorse_agent(Identity.t(), term()) :: {:ok, map()} | {:error, term()}
  def endorse_agent(%Identity{} = identity, actor_authority),
    do: SystemAuthority.endorse_agent(identity, actor_authority)

  @doc """
  Verify an agent endorsement signed by the system authority.
  """
  defdelegate verify_agent_endorsement(endorsement), to: SystemAuthority

  @doc """
  Create a new keychain for an agent (signing + encryption keypairs).
  """
  defdelegate new_keychain(agent_id), to: Keychain, as: :new

  @doc "Seal plaintext for a peer through the public Security facade."
  @spec keychain_seal_for_peer(term(), String.t(), binary()) ::
          {:ok, term()} | {:ok, term(), term()} | {:error, term()}
  def keychain_seal_for_peer(keychain, peer_agent_id, plaintext),
    do: Keychain.seal_for_peer(keychain, peer_agent_id, plaintext)

  @doc "Unseal peer ciphertext through the public Security facade."
  @spec keychain_unseal_from_peer(term(), String.t(), term()) ::
          {:ok, binary()} | {:ok, binary(), term()} | {:error, term()}
  def keychain_unseal_from_peer(keychain, sender_agent_id, sealed),
    do: Keychain.unseal_from_peer(keychain, sender_agent_id, sealed)

  @doc "Issue a caller-bound, operation-specific authority for internal channel crypto."
  @spec issue_channel_authority(term(), :send | :read) :: {:ok, term()} | {:error, term()}
  def issue_channel_authority(signing_authority, operation),
    do: Arbor.Security.ChannelAuthorityBroker.issue(signing_authority, operation)

  @doc "Close a caller-bound internal channel authority."
  @spec close_channel_authority(term()) :: :ok | {:error, term()}
  def close_channel_authority(channel_authority),
    do: Arbor.Security.ChannelAuthorityBroker.close(channel_authority)

  @doc "Resolve the authenticated principal bound to a live channel authority."
  @spec channel_authority_principal(term(), :send | :read) ::
          {:ok, String.t()} | {:error, term()}
  def channel_authority_principal(channel_authority, operation),
    do: Arbor.Security.ChannelAuthorityBroker.principal(channel_authority, operation)

  @doc "Sign one internal channel message without exporting signing key material."
  @spec sign_channel_message(term(), String.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign_channel_message(channel_authority, channel_id, content),
    do: Arbor.Security.ChannelAuthorityBroker.sign(channel_authority, channel_id, content)

  @doc "Seal one direct message without exporting either agent's key material."
  @spec seal_channel_message(term(), String.t(), binary()) ::
          {:ok, map()} | {:error, term()}
  def seal_channel_message(channel_authority, peer_id, content),
    do: Arbor.Security.ChannelAuthorityBroker.seal(channel_authority, peer_id, content)

  @doc "Unseal one direct message without exporting either agent's key material."
  @spec unseal_channel_message(term(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def unseal_channel_message(channel_authority, sender_id, sealed),
    do: Arbor.Security.ChannelAuthorityBroker.unseal(channel_authority, sender_id, sealed)

  @doc "Verify a domain-bound internal channel message signature."
  @spec verify_channel_message_signature(String.t(), String.t(), binary(), binary()) ::
          boolean() | nil
  def verify_channel_message_signature(sender_id, channel_id, content, signature),
    do:
      Arbor.Security.ChannelAuthorityBroker.verify(
        sender_id,
        channel_id,
        content,
        signature
      )

  # ===========================================================================
  # Signing Key Storage
  # ===========================================================================

  @typedoc "Caller-held key material read from a private `.arbor.key` file."
  @type key_file_material :: %{agent_id: String.t(), private_key: binary()}

  @doc "Parse bounded caller-supplied operator key-file contents."
  @spec parse_operator_key_file_contents(binary()) ::
          {:ok, key_file_material()} | {:error, term()}
  def parse_operator_key_file_contents(contents), do: KeyFile.parse(contents)

  @doc "Write a new mode-0600 `.arbor.key` file without overwriting an existing file."
  @spec write_key_file(Path.t(), key_file_material()) :: {:ok, String.t()} | {:error, term()}
  defdelegate write_key_file(path, key_material), to: KeyFile, as: :write

  @doc "Read only the principal id from a mode-private `.arbor.key` file."
  @spec key_file_principal(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def key_file_principal(path) when is_binary(path) do
    with {:ok, %{agent_id: principal_id}} <- KeyFile.read(path), do: {:ok, principal_id}
  end

  def key_file_principal(_path), do: {:error, :invalid_key_file_path}

  @doc "Sign one payload from a caller-opened, mode-private key-file handle."
  @spec sign_key_file_request(term(), binary()) ::
          {:ok, String.t(), SignedRequest.t()} | {:error, term()}
  def sign_key_file_request(io_device, payload)
      when not is_binary(io_device) and is_binary(payload) do
    with {:ok, %{agent_id: principal_id, private_key: private_key}} <-
           KeyFile.read_device(io_device),
         {:ok, signed_request} <- SignedRequest.sign(payload, principal_id, private_key) do
      {:ok, principal_id, signed_request}
    end
  end

  def sign_key_file_request(_io_device, _payload),
    do: {:error, :key_file_signing_authority_required}

  @doc """
  Sign one canonical scheduler capability-attestation payload from a
  caller-opened, mode-private key-file handle.

  The payload must already begin with the exact length-prefixed
  `arbor.scheduler.caps.v2` domain emitted by `Arbor.Scheduler.CapsFile`.
  Security signs those bytes unchanged and never returns private key material.
  """
  @spec sign_scheduler_caps_payload(term(), binary()) ::
          {:ok, String.t(), binary()} | {:error, term()}
  def sign_scheduler_caps_payload(io_device, payload)
      when not is_binary(io_device) and is_binary(payload) do
    with :ok <- validate_scheduler_caps_payload(payload),
         {:ok, %{agent_id: principal_id, private_key: private_key}} <-
           KeyFile.read_device(io_device) do
      {:ok, principal_id, Crypto.sign(payload, private_key)}
    end
  end

  def sign_scheduler_caps_payload(_io_device, _payload),
    do: {:error, :scheduler_caps_signing_authority_required}

  defp validate_scheduler_caps_payload(payload) do
    domain_prefix =
      <<byte_size(@scheduler_caps_signing_domain)::unsigned-big-integer-size(32),
        @scheduler_caps_signing_domain::binary>>

    if byte_size(payload) > byte_size(domain_prefix) and
         byte_size(payload) <= @max_scheduler_caps_payload_bytes and
         :binary.part(payload, 0, byte_size(domain_prefix)) == domain_prefix do
      :ok
    else
      {:error, :invalid_scheduler_caps_payload}
    end
  end

  @doc """
  Build an exact, signed capability-grant request in an offline CLI process.

  The returned capability and proof are submitted together with
  `submit_signed_capability_grant/2`. The caller must open the key file and
  pass its file handle; this facade never opens a caller-nominated path.
  """
  @spec prepare_key_file_capability_grant(term(), keyword()) ::
          {:ok, Capability.t(), SignedRequest.t()} | {:error, term()}
  def prepare_key_file_capability_grant(io_device, opts)
      when not is_binary(io_device) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         false <- Keyword.has_key?(opts, :actor_authority),
         {:ok, %{agent_id: actor_id, private_key: private_key}} <-
           KeyFile.read_device(io_device),
         {:ok, cap} <- build_grant_capability(opts, actor_id),
         {:ok, payload} <- SystemAuthority.capability_mutation_request_payload(:grant, cap),
         {:ok, proof} <- SignedRequest.sign(payload, actor_id, private_key) do
      {:ok, cap, proof}
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  def prepare_key_file_capability_grant(_path, _opts),
    do: {:error, :capability_mutation_unauthorized}

  @doc "Submit a capability and its exact one-use actor proof to the authority boundary."
  @spec submit_signed_capability_grant(Capability.t(), SignedRequest.t()) ::
          {:ok, Capability.t()} | {:error, term()}
  def submit_signed_capability_grant(%Capability{} = cap, %SignedRequest{} = actor_proof) do
    with {:ok, authorized_cap, receipt} <-
           SystemAuthority.authorize_capability_mutation_proof(actor_proof, :grant, cap),
         {:ok, signed_cap} <- CapabilityStore.put_authorized(authorized_cap, :grant, receipt) do
      Events.record_capability_granted(signed_cap)
      {:ok, signed_cap}
    else
      {:error, _} = error -> error
    end
  end

  def submit_signed_capability_grant(_cap, _actor_proof),
    do: {:error, :capability_mutation_unauthorized}

  @doc "Sign an exact issuer-mutation digest in an offline CLI process."
  @spec prepare_key_file_issuer_mutation(term(), atom(), String.t()) ::
          {:ok, String.t(), SignedRequest.t()} | {:error, term()}
  def prepare_key_file_issuer_mutation(io_device, operation, payload_digest)
      when not is_binary(io_device) do
    with {:ok, payload} <-
           SystemAuthority.issuer_mutation_request_payload(operation, payload_digest),
         {:ok, %{agent_id: actor_id, private_key: private_key}} <-
           KeyFile.read_device(io_device),
         {:ok, proof} <- SignedRequest.sign(payload, actor_id, private_key) do
      {:ok, actor_id, proof}
    else
      _ -> {:error, :issuer_mutation_unauthorized}
    end
  end

  def prepare_key_file_issuer_mutation(_io_device, _operation, _payload_digest),
    do: {:error, :issuer_mutation_unauthorized}

  @doc """
  Store an agent's signing private key (encrypted at rest).

  Called during agent creation to persist the Ed25519 private key.
  The key is encrypted with AES-256-GCM using a master key.
  """
  defdelegate store_signing_key(agent_id, private_key), to: SigningKeyStore, as: :put

  @doc false
  @spec store_signing_keypair(String.t(), binary(), binary()) :: :ok | {:error, term()}
  def store_signing_keypair(agent_id, signing_private_key, encryption_private_key),
    do: SigningKeyStore.put_keypair(agent_id, signing_private_key, encryption_private_key)

  if Mix.env() == :test do
    @doc false
    defdelegate store_signing_key_fixture(agent_id, private_key),
      to: SigningKeyStore,
      as: :put_fixture

    @doc false
    defdelegate store_signing_keypair_fixture(
                  agent_id,
                  signing_private_key,
                  encryption_private_key
                ),
                to: SigningKeyStore,
                as: :put_keypair_fixture

    @doc false
    defdelegate delete_signing_key_fixture(agent_id),
      to: SigningKeyStore,
      as: :delete_fixture
  end

  @doc """
  Retired raw-key API.

  Private signing material is never returned through the public facade. Use an
  owner-bound `SigningAuthority` for signing operations.
  """
  @spec load_signing_key(term()) :: {:error, :unauthorized}
  def load_signing_key(_agent_id), do: {:error, :unauthorized}

  @doc false
  @spec build_stored_signing_authority_acquisition_proof(String.t(), atom(), pid(), atom()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def build_stored_signing_authority_acquisition_proof(
        principal_id,
        purpose,
        owner,
        registered_owner
      ) do
    SigningKeyStore.build_named_acquisition_proof(
      principal_id,
      purpose,
      owner,
      registered_owner
    )
  end

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

  @doc false
  @spec signing_key_public_identity(String.t(), keyword()) ::
          {:ok, Identity.t()} | {:error, term()}
  def signing_key_public_identity(agent_id, opts \\ []),
    do: SigningKeyStore.load_public_identity(agent_id, opts)

  @doc false
  def migrate_legacy_signing_key_locator(locator, opts \\ []),
    do: SigningKeyStore.migrate_legacy_locator(locator, opts)

  @doc """
  Delete an agent's signing key.

  Called during agent destruction.
  """
  defdelegate delete_signing_key(agent_id), to: SigningKeyStore, as: :delete

  @doc """
  Bounded JSON-clean status of the Security authority-mutation audit journal.

  Returns mode, durability, availability, a closed dormant/degraded reason,
  a redacted last-error code, counts, pending age, and capacity. Never returns
  file handles, PIDs, paths, reducer internals, capability payloads, or signing
  material.

  Terminal-identity retirement fields:

  - `"capacity"` adds `"retirable_operation_count"` (delivered identities the
    next retiring publication would retire), `"retired_operation_total"`,
    `"retire_batch"` and `"remaining_increase_admissions"` (increase headroom
    after that retirement; retirement counts as zero while the ledger is
    paused, while the last retiring publication attempt has failed
    (`retirement.last_error` not `"none"`), or where no retiring publication
    exists, i.e. small journals; ephemeral operational journals retire in
    memory and report real headroom), plus
    `"reserved_entries"`/`"reserved_bytes"` (records pending operations have
    reserved; every admission is checked against written plus reserved). The
    existing map-size fields are unchanged, so an empty queue is never read as
    capacity.
  - `"admission_open"`: readiness, not the admission decision. True when the
    journal is serving, the ledger is not paused, and one more increase
    would pass the retained (`remaining_increase_admissions > 0`), entry
    (`remaining_soft_entries - reserved_entries >= 3`) and soft-byte (room for
    a maximum-size record beyond reservations) clauses. It is intentionally
    absent from `execution_policy_snapshot/0`, whose digest binds security
    qualification: a Historian backlog must not un-qualify sessions (decision
    H9: expose, do not gate).
  - `"last_refusal"`: the last prepare refusal since the owner started,
    `"none" | "soft_capacity_exhausted" | "capacity_exhausted" |
    "retired_version" | "operation_terminal"`.
  - `"retirement"`: `"floor"` (admission floor, 1 or 3), `"ledger_state"`
    (`"none"` without a retirement ledger, i.e. ephemeral and small
    journals, else `"absent" | "bound" |
    "bound_orphan" | "mismatch" | "ahead"`), `"ledger_frames"` (frames bound
    by the published snapshot), `"prepared_count"`,
    `"oldest_prepared_age_seconds"` and `"last_error"` (`"none"` or the
    reason the last retirement publication was not published).

  `"ledger_state"` reflects the handle's last open or adopted publication: after
  an unpublished attempt that left an orphan frame, a live owner may report
  `"absent"` while a restart over the same bytes reports `"bound_orphan"`;
  both are retiring postures. `"mismatch"`/`"ahead"` (paused) change only by
  restart after the journal/ledger pair is restored.
  """
  @spec audit_journal_status() :: {:ok, map()} | {:error, :journal_unavailable}
  def audit_journal_status, do: AuditJournalOwner.status()

  @doc """
  Bounded JSON-clean pending operations in the Security audit journal.

  Each item is a bounded JSON-clean string-keyed map whose only keys are
  `"operation_id"`, `"status"`, `"effect_class"`, and `"intent_sha256"`.
  """
  @spec audit_journal_pending_operations() :: {:ok, [map()]} | {:error, :journal_unavailable}
  def audit_journal_pending_operations, do: AuditJournalOwner.pending_operations()

  @doc """
  Last serialized capability mutation audit status; diagnostic, not durable evidence.

  `:effect` and `:audit` as before (a refused grant reports
  `effect: :not_applied, audit: :refused`), plus `:reason` — the closed class
  of the last journal refusal (`:none | :capacity | :identity | :unavailable`)
  — and `:degraded_reductions`, the number of reductions the CapabilityStore
  process executed without a journal record since it started. Public mutation
  results are unchanged (`{:error, :audit_unavailable}` for a refused grant).
  """
  def capability_mutation_audit_status do
    GenServer.call(CapabilityStore, :mutation_audit_status)
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
  end

  @doc "Source-owned Historian pull boundary; only its configured registered consumer is admitted."
  def authority_audit_delivery_batch, do: AuditJournalOwner.delivery_batch()

  @doc "Reobserve pending mutation effects at their serialized owner before audit delivery."
  def reconcile_authority_audit do
    CapabilityStore.reconcile_authority_audit()
  end

  @doc "Acknowledge the exact journal intent after the owning Historian consumer proves durable content."
  def acknowledge_authority_audit(id, intent_sha256),
    do: AuditJournalOwner.acknowledge_delivery(id, intent_sha256)

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
  @spec open_agent_lifecycle_authority(binary()) ::
          {:ok, SigningAuthority.t()} | {:error, term()}
  def open_agent_lifecycle_authority(session_token) when is_binary(session_token) do
    SigningAuthorityBroker.open_agent_lifecycle_session(session_token)
  end

  def open_agent_lifecycle_authority(_session_token), do: {:error, :invalid_session_token}

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

  @doc "Sign a canonical peer identity endorsement with an owner-bound signing authority."
  @spec sign_identity_endorsement(SigningAuthority.t(), String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign_identity_endorsement(authority, signer_id, target_id, target_public_key) do
    SigningAuthorityBroker.sign_identity_endorsement(
      authority,
      signer_id,
      target_id,
      target_public_key
    )
  end

  @doc "Verify a canonical peer identity endorsement against the registered signer identity."
  @spec verify_identity_endorsement(String.t(), String.t(), binary(), binary()) ::
          :ok | {:error, :invalid_identity_endorsement}
  def verify_identity_endorsement(signer_id, target_id, target_public_key, signature)
      when is_binary(signature) do
    with {:ok, payload} <-
           SigningAuthorityBroker.identity_endorsement_payload(
             signer_id,
             target_id,
             target_public_key
           ),
         {:ok, signer_public_key} <- lookup_public_key(signer_id),
         true <- Crypto.verify(payload, signature, signer_public_key) do
      :ok
    else
      _ -> {:error, :invalid_identity_endorsement}
    end
  rescue
    _ -> {:error, :invalid_identity_endorsement}
  catch
    _, _ -> {:error, :invalid_identity_endorsement}
  end

  def verify_identity_endorsement(_signer_id, _target_id, _target_public_key, _signature),
    do: {:error, :invalid_identity_endorsement}

  @doc "Return the principal bound to a live authority owned by the calling process."
  @spec signing_authority_principal(SigningAuthority.t()) ::
          {:ok, String.t()} | {:error, term()}
  def signing_authority_principal(authority) do
    with {:ok, %{principal_id: principal_id}} <- SigningAuthorityBroker.owned_identity(authority),
         true <- is_binary(principal_id) and principal_id != "" do
      {:ok, principal_id}
    else
      _ -> {:error, :signing_authority_unauthorized}
    end
  end

  @doc false
  @spec validate_signing_authority_owner(term(), pid(), String.t()) ::
          :ok | {:error, :signing_authority_unauthorized}
  def validate_signing_authority_owner(authority, owner, principal_id)
      when is_pid(owner) and is_binary(principal_id) do
    case SigningAuthorityBroker.recorded_identity(authority, owner) do
      {:ok, %{principal_id: ^principal_id}} -> :ok
      _ -> {:error, :signing_authority_unauthorized}
    end
  end

  def validate_signing_authority_owner(_authority, _owner, _principal_id),
    do: {:error, :signing_authority_unauthorized}

  @doc """
  Sign a domain-tagged detached message using a previously opened signing authority.

  Used for forge projection signing (`arbor-forge-projection-v1`). This path is
  separate from `sign_with_authority/2`, which produces MCP `SignedRequest` envelopes.
  """
  @spec sign_detached_with_authority(SigningAuthority.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign_detached_with_authority(authority, domain_tag, message)
      when is_binary(domain_tag) and is_binary(message) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, canonical} ->
        SigningAuthorityBroker.sign_detached_with_domain(canonical, domain_tag, message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def sign_detached_with_authority(authority, _domain_tag, _message) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, _canonical} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verify a detached Ed25519 signature over a raw message.
  """
  @spec verify_detached(binary(), binary(), binary()) :: :ok | {:error, term()}
  def verify_detached(message, signature, public_key)
      when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    case Crypto.verify(message, signature, public_key) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  catch
    _ -> {:error, :invalid_signature}
  end

  def verify_detached(_message, _signature, _public_key), do: {:error, :invalid_signature}

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

  @doc """
  Issue a canonical signed Platform activation authorization.

  Requires an already acquired owner-scoped signing authority whose principal
  is the boot-derived Platform identity and whose purpose is exactly
  `:platform_activation`. Issuer, key, boot digest, profile id, epoch, and
  validity bounds are taken only from `Arbor.KernelRuntime.boot_profile/0`.

  `context` is a closed atom-keyed map or keyword with exactly:

      %{
        audience_host_id: binary,
        audience_install_id: binary,
        nonce: binary
      }

  The broker supplies the issuance instant and a short expiry from its own clock,
  and reserves the nonce before signing. Caller-supplied time, boot, key, issuer,
  transaction digest, or private material is rejected. Success returns a
  validated `arbor.extension.signed_envelope.v1`
  wrapping `arbor.extension.activation_authorization.v1` after detached
  Ed25519 verification against the boot-bound Platform public key.
  """
  @spec issue_platform_activation_authorization(term(), term(), term()) ::
          {:ok, map()} | {:error, SecurityContract.platform_activation_authorization_error()}
  def issue_platform_activation_authorization(authority, transaction, context) do
    issue_signed_platform_activation_authorization_from_live_authority_and_transaction(
      authority,
      transaction,
      context
    )
  end

  @impl Arbor.Contracts.API.Security
  def issue_signed_platform_activation_authorization_from_live_authority_and_transaction(
        authority,
        transaction,
        context
      ) do
    PlatformActivationAuthorization.issue(authority, transaction, context)
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
  Begin a bounded terminal device login for one chat target using only the
  configured device-flow provider. Existing human registration and chat grants
  are required; this API never provisions either. The handle remains bound to
  the trusted transport source that admitted the flow.
  """
  @spec begin_terminal_login(String.t()) :: {:error, :terminal_login_source_required}
  def begin_terminal_login(_target), do: {:error, :terminal_login_source_required}

  @spec begin_terminal_login(String.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def begin_terminal_login(target, source),
    do: Arbor.Security.TerminalLogin.begin(target, source)

  @doc """
  Poll a terminal login handle from its trusted admission source. Successful
  credential retrieval is one-shot; a lost success response requires a new
  login. No OIDC token or key is returned.
  """
  @spec terminal_login_status(String.t()) :: {:ok, :pending | map()} | {:error, :unauthorized}
  defdelegate terminal_login_status(handle), to: Arbor.Security.TerminalLogin, as: :status

  @spec terminal_login_status(String.t(), term()) ::
          {:ok, :pending | map()} | {:error, :unauthorized}
  defdelegate terminal_login_status(handle, source),
    to: Arbor.Security.TerminalLogin,
    as: :status

  @doc "Cancel a pending login and await retirement of its exact device-flow worker."
  @spec cancel_terminal_login(String.t()) :: :ok | {:error, :unauthorized}
  defdelegate cancel_terminal_login(handle), to: Arbor.Security.TerminalLogin, as: :cancel

  @spec cancel_terminal_login(String.t(), term()) :: :ok | {:error, :unauthorized}
  defdelegate cancel_terminal_login(handle, source),
    to: Arbor.Security.TerminalLogin,
    as: :cancel

  @doc """
  Preflight an unclaimed or disconnected terminal credential for socket upgrade.
  Returns public binding metadata only, never a signing proof. Preflight does not
  claim a connection or extend its bounded initial-attach/reconnect deadline.
  """
  @spec preflight_terminal_session(String.t()) ::
          {:ok, map()} | {:error, :unauthorized | :session_in_use}
  defdelegate preflight_terminal_session(credential),
    to: Arbor.Security.TerminalLogin,
    as: :preflight

  @doc """
  Claim a terminal credential for the actual calling connection process. Only
  one live owner may hold it. Owner death begins the bounded reconnect grace;
  an attached connection has no total-age cutoff. A caller cannot choose a PID.
  """
  @spec claim_terminal_session(String.t()) :: {:ok, map()} | {:error, :unauthorized}
  defdelegate claim_terminal_session(credential), to: Arbor.Security.TerminalLogin, as: :claim

  @doc """
  Verify the calling connection owns an opaque terminal credential and retains
  current human/target/owner authority. Returns a fresh, short-lived scoped proof.
  The returned HMAC proof is SERVER-ONLY: trusted Gateway code may pass it to
  Agent, but must never serialize it to a client, renderer, log, or status API.
  No provider refresh, identity provisioning, or new grants occur.
  """
  @spec verify_terminal_session(String.t()) :: {:ok, map()} | {:error, :unauthorized}
  defdelegate verify_terminal_session(credential), to: Arbor.Security.TerminalLogin, as: :verify

  @doc "Revoke an opaque terminal credential. Idempotent while the broker is available."
  @spec revoke_terminal_session(String.t()) :: :ok | {:error, :unauthorized}
  defdelegate revoke_terminal_session(credential), to: Arbor.Security.TerminalLogin, as: :revoke

  @doc "Return the configured OIDC providers through the Security facade."
  @spec oidc_providers() :: [map()]
  def oidc_providers, do: Arbor.Security.OIDC.Config.providers()

  @doc "Generate a cryptographically random OIDC state value."
  @spec generate_oidc_state() :: String.t()
  def generate_oidc_state, do: Arbor.Security.OIDC.AuthCodeFlow.generate_state()

  @doc "Generate a cryptographically random OIDC nonce."
  @spec generate_oidc_nonce() :: String.t()
  def generate_oidc_nonce, do: Arbor.Security.OIDC.AuthCodeFlow.generate_nonce()

  @doc "Build a validated OIDC authorization URL with PKCE."
  @spec build_oidc_authorize_url(term(), String.t(), String.t(), term()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def build_oidc_authorize_url(provider, redirect_uri, state, opts \\ []),
    do: Arbor.Security.OIDC.AuthCodeFlow.build_authorize_url(provider, redirect_uri, state, opts)

  @doc "Exchange a validated OIDC authorization code for tokens."
  @spec exchange_oidc_code(term(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_oidc_code(provider, code, redirect_uri, code_verifier),
    do:
      Arbor.Security.OIDC.AuthCodeFlow.exchange_code(provider, code, redirect_uri, code_verifier)

  @doc "Verify an OIDC ID token and return its admitted claims."
  @spec verify_oidc_token(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify_oidc_token(id_token, provider),
    do: Arbor.Security.OIDC.TokenVerifier.verify(id_token, provider)

  if Mix.env() == :test do
    @doc false
    @spec derive_oidc_principal_id_fixture(map()) :: String.t()
    def derive_oidc_principal_id_fixture(claims),
      do: Arbor.Security.OIDC.IdentityStore.derive_agent_id(claims)

    @doc false
    @spec restore_runtime_fixture() :: :ok | :skipped
    def restore_runtime_fixture, do: Arbor.Security.TestBootstrap.start!()

    @doc false
    @spec put_oidc_jwks_fixture(map(), map(), pos_integer()) :: :ok | {:error, atom()}
    def put_oidc_jwks_fixture(provider, jwks, ttl_ms \\ 60_000),
      do: Arbor.Security.OIDC.JwksCache.put_fixture(provider, jwks, ttl_ms)

    @doc false
    @spec delete_oidc_jwks_fixture(map()) :: :ok
    def delete_oidc_jwks_fixture(provider),
      do: Arbor.Security.OIDC.JwksCache.delete_fixture(provider)

    @doc false
    @spec identity_security_sync_subscriber_fixture() :: map()
    def identity_security_sync_subscriber_fixture do
      %{
        owner: Registry,
        supervisor: {:application, :arbor_security},
        child_id: Registry,
        events: [
          :identity_registered,
          :identity_deregistered,
          :identity_suspended,
          :identity_resumed,
          :identity_revoked
        ]
      }
    end

    @doc false
    @spec load_or_create_oidc_identity_fixture(map()) ::
            {:ok, Identity.t(), :existing | :created} | {:error, term()}
    def load_or_create_oidc_identity_fixture(claims),
      do: Arbor.Security.OIDC.IdentityStore.load_or_create_fixture(claims)
  end

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
  Issue a bounded human-session token from a caller-owned authority.

  The authority must be live, owned by the calling process, and bound to the
  same human principal. This keeps token minting coupled to the authenticated
  OIDC result instead of exposing an ambient principal-id minting deputy.
  """
  @spec issue_human_session_token(String.t(), SigningAuthority.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def issue_human_session_token(principal_id, authority, opts \\ [])

  def issue_human_session_token(principal_id, authority, opts)
      when is_binary(principal_id) and is_list(opts) do
    if human_identity?(principal_id),
      do: Arbor.Security.SessionToken.generate_authorized(principal_id, authority, opts),
      else: {:error, :session_token_issuance_unauthorized}
  end

  def issue_human_session_token(_principal_id, _authority, _opts),
    do: {:error, :session_token_issuance_unauthorized}

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
    if Config.invocation_receipts_enabled?() and result == :granted do
      proof =
        receipt_issuance_proof(:invocation, %{
          capability: cap,
          principal_id: principal_id,
          resource_uri: resource_uri,
          action: action
        })

      case InvocationReceiptBroker.issue_authorized(proof) do
        {:ok, signed_receipt} ->
          Events.record_invocation_receipt(signed_receipt)
          Keyword.get(opts, :receipt_callback, &Function.identity/1).(signed_receipt)

        {:error, _} ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  # This local closure is an unforgeable, caller-bound capability within the
  # normal BEAM application boundary. Security-owned GenServers admit only local
  # closures created by this module, then challenge them and require the issuing
  # process and operation kind to match the GenServer call being handled. The
  # proof never leaves this private authorization path or appears in
  # caller-visible data.
  defp receipt_issuance_proof(kind, payload) when is_atom(kind) and is_map(payload) do
    caller = self()

    fn challenge ->
      {:arbor_security_receipt_issuance_v1, challenge, caller, kind, payload}
    end
  end

  defp maybe_consume_max_use(%Capability{max_uses: nil}), do: :ok

  defp maybe_consume_max_use(%Capability{} = cap) do
    proof = receipt_issuance_proof(:capability_usage, %{capability: cap})

    case CapabilityStore.consume_usage_authorized(proof) do
      {:ok, :available} ->
        :ok

      {:ok, :exhausted} ->
        Events.record_capability_revoked(cap.id)
        :ok

      {:error, reason} when reason in [:not_found, :usage_exhausted] ->
        {:error, :max_uses_exhausted}

      {:error, reason} ->
        {:error, {:max_uses_unavailable, reason}}
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

      {:error, _reason} = error ->
        error

      :none ->
        normalize_unscoped_fs_path(file_path)
    end
  end

  defp workspace_root(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        SafePath.resolve_within(workspace, "/")

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

  # Descriptor-bound reads validate and open against the exact capability
  # selected by AuthDecision. Running the legacy explicit FileGuard lookup
  # first would select a second capability and lose that binding.
  defp maybe_check_file_guard_for_effect(
         {:read_file, _path},
         _principal_id,
         _resource_uri,
         _opts,
         %Capability{}
       ),
       do: :ok

  defp maybe_check_file_guard_for_effect(
         effect,
         principal_id,
         resource_uri,
         opts,
         cap
       )
       when effect == :none do
    maybe_check_file_guard(principal_id, resource_uri, opts, cap)
  end

  defp maybe_check_file_guard_for_effect(
         _effect,
         _principal_id,
         _resource_uri,
         _opts,
         _cap
       ),
       do: {:error, :invalid_authorized_effect}

  defp apply_authorized_effect(:none, _cap), do: {:ok, :authorized}

  defp apply_authorized_effect({:read_file, path}, %Capability{} = cap)
       when is_binary(path) do
    file_guard = file_guard_module()

    with true <- Code.ensure_loaded?(file_guard),
         true <- function_exported?(file_guard, :prepare_read_for_capability, 2),
         true <- function_exported?(file_guard, :validate_opened_read_for_capability, 3),
         {:ok, %{root_binding: root_binding, mode: mode}}
         when mode in [:exact, :within_root] <-
           file_guard.prepare_read_for_capability(path, cap),
         root when is_binary(root) <- SafePath.binding_root(root_binding),
         validator = fn opened_path ->
           file_guard.validate_opened_read_for_capability(opened_path, root, cap)
         end,
         {:ok, content, opened_path} <-
           execute_authorized_read(mode, path, root_binding, validator),
         :ok <- file_guard.validate_opened_read_for_capability(opened_path, root, cap) do
      {:ok, :authorized, {:ok, content, opened_path}}
    else
      false -> {:error, :file_guard_unavailable}
      {:error, _reason} = error -> error
      _unexpected -> {:error, :invalid_file_read_result}
    end
  rescue
    _ -> {:error, :file_guard_error}
  catch
    :exit, _ -> {:error, :file_guard_error}
  end

  defp apply_authorized_effect(_effect, _cap),
    do: {:error, :invalid_authorized_effect}

  defp execute_authorized_read(:exact, path, root_binding, validator),
    do: SafePath.read_exact_bound_checked(path, root_binding, validator)

  defp execute_authorized_read(:within_root, path, root_binding, validator),
    do: SafePath.read_within_bound_checked(path, root_binding, validator)

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

  # Extract the filesystem path, excluding the URI operation segment. Reflex
  # path matching performs its own lexical/real-path normalization.
  defp extract_path_from_uri("arbor://fs/" <> _ = resource_uri) do
    case Arbor.Security.FileGuard.parse_resource_uri(resource_uri) do
      {:ok, _operation, path} -> path
      _ -> nil
    end
  end

  defp extract_path_from_uri(_), do: nil
end
