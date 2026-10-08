defmodule Arbor.Agent do
  @moduledoc """
  Agent orchestration framework for Arbor.

  Provides the public API for managing Jido-based agents with durability support.
  Agents are supervised processes that wrap Jido agent structs with:

  - **Supervision** - Automatic restarts on failure via DynamicSupervisor
  - **Registration** - Discovery and lookup via ETS-backed registry
  - **Checkpointing** - State persistence and recovery via pluggable storage
  - **Action execution** - Consistent plan-and-execute pattern

  ## Quick Start

      # Define a Jido agent module
      defmodule MyAgent do
        use Jido.Agent,
          name: "my_agent",
          description: "Example agent",
          actions: [MyApp.Actions.DoWork],
          schema: [counter: [type: :integer, default: 0]]
      end

      # Start an agent
      {:ok, pid} = Arbor.Agent.start("agent-001", MyAgent, %{counter: 0})

      # Execute an action
      {:ok, result} = Arbor.Agent.run_action("agent-001", {MyApp.Actions.DoWork, %{input: "data"}})

      # Get agent state
      {:ok, state} = Arbor.Agent.get_state("agent-001")

      # Stop the agent (saves checkpoint)
      :ok = Arbor.Agent.stop("agent-001")

  ## Checkpointing

  Enable durable state by providing a checkpoint storage backend:

      {:ok, pid} = Arbor.Agent.start("agent-001", MyAgent, %{counter: 0},
        checkpoint_storage: Arbor.Persistence.Checkpoint.Store.ETS,
        auto_checkpoint_interval: 30_000
      )

  The agent will automatically:
  - Attempt to restore from checkpoint on startup
  - Save checkpoints at the configured interval
  - Save a final checkpoint on graceful shutdown
  """

  alias Arbor.Agent.{ConversationFacade, ExternalRegistration, Lifecycle, ProfileStore, Registry}

  require Logger

  @doc "Loaded source identity of the bounded hostile-document acceptance producer; no inference."
  defdelegate security_qualification_producer_identity(),
    to: Arbor.Agent.Eval.SecurityJourney,
    as: :identity

  @doc "The fixed synthetic document used by the hostile-export acceptance journey."
  defdelegate security_qualification_fixture(), to: Arbor.Agent.Eval.SecurityJourney, as: :fixture

  @doc "Run acceptance using a dedicated existing read cap and signing authority, which are consumed."
  defdelegate run_security_qualification_journey(profile, opts),
    to: Arbor.Agent.Eval.SecurityJourney,
    as: :run

  @doc "Compose a persisted journey and reviewed artifact observations; approval remains separate."
  defdelegate compose_security_qualification(profile, journey_id, artifacts),
    to: Arbor.Agent.Eval.SecurityQualificationReport,
    as: :compose

  # ===========================================================================
  # Public API — Agent Lifecycle (Phase 4: Seed/Host)
  # ===========================================================================

  @doc """
  Create a new agent from a template or options.

  ## Examples

      {:ok, profile} = Arbor.Agent.create_agent("scout-1",
        template: "scout")

      {:ok, profile} = Arbor.Agent.create_agent("custom",
        character: Character.new(name: "My Agent"))
  """
  defdelegate create_agent(agent_id, opts \\ []), to: Lifecycle, as: :create

  @doc "Return the fixed external-agent registration profiles."
  @spec external_agent_types() :: [map()]
  defdelegate external_agent_types(), to: ExternalRegistration, as: :types

  @doc "Register a fixed-policy external agent after caller authorization."
  @spec register_external_agent(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Arbor.Agent.Profile.t(), Arbor.Contracts.Security.Identity.t()}
          | {:error, term()}
  defdelegate register_external_agent(caller_id, display_name, type, opts \\ []),
    to: ExternalRegistration,
    as: :register

  @doc "Restore an agent from a persisted profile."
  defdelegate restore_agent(agent_id), to: Lifecycle, as: :restore

  @doc "Start an agent's executor (subscribe to intents, begin processing)."
  defdelegate start_agent(agent_id, opts \\ []), to: Lifecycle, as: :start

  @doc "Issue an opaque, restartable signing-authority bootstrap for an agent-owned consumer."
  defdelegate issue_signing_authority_bootstrap(agent_id, purpose), to: Lifecycle

  @doc false
  defdelegate transfer_signing_authority_handoff(agent_id, purpose, claimant, context),
    to: Lifecycle

  @doc "Verify a retained coding candidate through a TaskStore-owned authority handoff."
  @spec verify_coding_candidate_for_operator(term(), term()) ::
          {:ok, map()} | {:error, term()}
  def verify_coding_candidate_for_operator(plan, request) do
    Arbor.Agent.Orchestration.TaskStore.verify_coding_candidate_for_operator(
      plan,
      request,
      self()
    )
  end

  @doc false
  @spec verify_coding_candidate_for_operator_rpc(pid(), pid(), binary(), term(), term()) :: :ok
  def verify_coding_candidate_for_operator_rpc(
        requester,
        reply_to,
        correlation_id,
        plan,
        request
      )
      when is_pid(requester) and is_pid(reply_to) and is_binary(correlation_id) and
             byte_size(correlation_id) == 16 do
    result =
      Arbor.Agent.Orchestration.TaskStore.verify_coding_candidate_for_operator(
        plan,
        request,
        requester
      )

    case result do
      {:error, {:candidate_verification_cancelled, status}} ->
        send(
          reply_to,
          {:arbor_operator_candidate_verification_rpc_cancelled, correlation_id, status}
        )

      _ ->
        send(
          reply_to,
          {:arbor_operator_candidate_verification_rpc_result, correlation_id, result}
        )
    end

    :ok
  end

  def verify_coding_candidate_for_operator_rpc(
        _requester,
        _reply_to,
        _correlation_id,
        _plan,
        _request
      ),
      do: :ok

  @doc "Stop an agent's executor cleanly."
  defdelegate stop_agent(agent_id), to: Lifecycle, as: :stop

  @doc "List all persisted agent profiles."
  defdelegate list_agents(), to: Lifecycle

  @doc """
  Project persisted agents into Monitor-shaped directory rows.

  Returns `{:ok, agents}` where each agent is `%{agent_id, display_name}` only.
  """
  @spec list_monitor_agents() ::
          {:ok, [%{agent_id: String.t(), display_name: String.t() | nil}]}
          | {:error, :directory_unavailable}
  def list_monitor_agents do
    agents =
      Enum.flat_map(list_agents(), fn
        %{agent_id: id} = profile when is_binary(id) ->
          name = Map.get(profile, :display_name)
          display_name = if is_binary(name) or is_nil(name), do: name, else: nil
          [%{agent_id: id, display_name: display_name}]

        _other ->
          []
      end)

    {:ok, agents}
  rescue
    _ -> {:error, :directory_unavailable}
  catch
    _, _ -> {:error, :directory_unavailable}
  end

  @doc "List all running agents across the cluster via `:pg` process groups."
  defdelegate list_cluster(), to: Registry, as: :list_cluster

  @doc "Find a specific agent across the cluster by agent_id."
  defdelegate whereis_cluster(agent_id), to: Registry, as: :whereis_cluster

  @doc "Delete an agent and all its data."
  defdelegate destroy_agent(agent_id), to: Lifecycle, as: :destroy
  defdelegate destroy_agent(agent_id, opts), to: Lifecycle, as: :destroy

  @doc "Load a single agent profile by ID."
  defdelegate load_profile(agent_id), to: ProfileStore

  @doc "Rename a persisted agent profile."
  defdelegate rename_agent(agent_id, display_name), to: Lifecycle, as: :rename

  @doc "Store an agent profile."
  defdelegate store_profile(profile), to: ProfileStore

  @doc "List all profiles with auto_start: true."
  defdelegate list_auto_start_profiles(), to: ProfileStore

  @doc """
  Select a running agent associated with a principal, with a legacy first-agent fallback.

  This is a selector only, not read or delivery authority. Callers must separately
  authenticate and authorize the selected agent through the conversation APIs.
  """
  @spec find_agent_for_principal(String.t()) :: {:ok, String.t(), pid(), map()} | :not_found
  defdelegate find_agent_for_principal(principal_id), to: Arbor.Agent.Manager

  @doc """
  Set the auto_start flag on an agent's persisted profile.

  Requires the human's `:actor_authority`: enabling delegates the per-agent
  start rights to the system lifecycle principal, disabling revokes them (see
  `Arbor.Agent.Manager.set_auto_start/3`). The two-argument form fails closed
  with `{:error, :capability_mutation_unauthorized}`.
  """
  defdelegate set_auto_start(agent_id, enabled), to: Arbor.Agent.Manager
  defdelegate set_auto_start(agent_id, enabled, opts), to: Arbor.Agent.Manager

  @doc "Update an agent's display name."
  defdelegate set_display_name(agent_id, name), to: Arbor.Agent.Manager

  @doc "Set MCP server configuration for an agent."
  defdelegate set_mcp_config(agent_id, servers), to: Arbor.Agent.Manager
  defdelegate set_mcp_config(agent_id, servers, opts), to: Arbor.Agent.Manager

  @doc "Connect to MCP servers configured in an agent's profile."
  defdelegate connect_mcp_servers(agent_id), to: Arbor.Agent.Manager

  # ===========================================================================
  # Public API — Authorized live message (owner-scoped chat)
  # ===========================================================================

  @doc """
  Build the exact signed payload for `send_message/4` or `send_message_response/4`.

  This Elixir-native/RPC `arbor.message.v1` binding hashes deterministic ETF of
  the complete native `UserMessage` envelope, including timestamp and metadata.
  Set its final authenticated `sender_id` before calling this helper and deliver
  that exact envelope unchanged. JSON clients should use the conversation v2
  APIs and `conversation_request_payload/5` instead.
  """
  @spec message_request_payload(String.t(), String.t(), Arbor.Contracts.Session.UserMessage.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def message_request_payload(caller, target, message),
    do: Arbor.Agent.MessageFacade.request_payload(caller, target, message)

  @doc """
  Send one `UserMessage` to a running agent and return assistant text.

  Structured sibling: `send_message_response/4` (same auth/delivery branches,
  returns `%Arbor.Contracts.Pipeline.Response{}` on the authenticated path).

  ## Branches

  - **Absent proof** — ordinary compatibility path: requires an
    engagement-tagged envelope, authorizes via `Arbor.Security.authorize/4`,
    and delivers through `Arbor.Agent.Manager.chat/3` (no turn authority).
  - **Present `:session_token` or `:signed_request`** — authenticated path: requires
    `engagement_id == nil`, exchanges the proof for a one-use delivery receipt
    inside `MessageFacade` only, and delivers through
    `Manager.chat_authenticated/4` → Session (no APIAgent fallback).

  ## Options

  - `:timeout` — positive integer milliseconds, max `300_000` (default `30_000`)
  - `:session_token` — optional human session proof (never forwarded to Manager
    opts, signals, logs, or errors)
  - `:signed_request` — alternative fresh proof of `message_request_payload/3`;
    arbitrary or modified payloads are rejected before receipt or nonce use.
  - `:expected_engagement_id` — optional `eng_` plus 32 lowercase hexadecimal
    digits, supported only with `:session_token`. Session compares this with its
    source-resolved private engagement before queueing and activation; it never
    selects a conversation. Signed and ordinary delivery reject this option.

  Unknown, duplicate, zero, or oversized options are rejected before effects.
  Present but invalid `:session_token` values (`nil`, empty, non-binary,
  oversized, duplicate keys) are rejected as `:invalid_opts` before
  authorization.

  ## Returns

  - `{:ok, reply_text}` when delivery returns a binary reply
  - `{:error, :delivery_ambiguous}` when an authenticated delivery reaches its
    timeout after dispatch and therefore may already have been accepted
  - `{:error, reason}` with a closed atom vocabulary (no content/capability leakage)
  """
  @spec send_message(
          String.t(),
          String.t(),
          Arbor.Contracts.Session.UserMessage.t(),
          keyword()
        ) ::
          {:ok, String.t()}
          | {:error,
             :invalid_opts
             | :invalid_timeout
             | :invalid_caller_id
             | :invalid_agent_id
             | :invalid_message
             | :invalid_content
             | :invalid_sender
             | :invalid_engagement_id
             | :unauthorized
             | :unsupported_conversation_capability
             | :delivery_ambiguous
             | :delivery_failed}
  def send_message(caller_id, target_agent_id, message, opts \\ []) do
    # Fixed production collaborators only — never selectable via public opts or
    # ambient process/application state (see MessageFacade for test injects).
    Arbor.Agent.MessageFacade.deliver_text(caller_id, target_agent_id, message, opts)
  end

  @doc """
  Consult an agent internally on behalf of one source-owned Voice turn.

  Requires a `:session_token` and the same caller, target and engagement gates as
  `send_message/4`. Signed ordinary-message proofs do not authorize this separate
  purpose. `parent_voice_id` is `voice_` followed by 32 lowercase hex digits.
  The backend exchange remains durable and available to private memory, but is
  not a second visible chat turn. Returns the bounded text-delivery vocabulary.
  """
  @spec consult_conversation(
          String.t(),
          String.t(),
          Arbor.Contracts.Session.UserMessage.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, Arbor.Agent.MessageFacade.error_reason()}
  def consult_conversation(caller, target, message, parent_voice_id, opts \\ []) do
    Arbor.Agent.MessageFacade.consult(caller, target, message, parent_voice_id, opts)
  end

  @doc """
  Send one `UserMessage` to a running agent and return a structured response.

  Text sibling: `send_message/4` (same auth/delivery branches, returns binary
  assistant text).

  Same authorization and delivery branches as `send_message/4`:

  - Absent proof → ordinary `Manager.chat_response/3` map shape
  - Present session token or bound signed request → authenticated Session path returning
    `%Arbor.Contracts.Pipeline.Response{}` after closed projection

  Options and closed error vocabulary match `send_message/4`.
  """
  @spec send_message_response(
          String.t(),
          String.t(),
          Arbor.Contracts.Session.UserMessage.t(),
          keyword()
        ) ::
          {:ok, Arbor.Contracts.Pipeline.Response.t() | map()}
          | {:error,
             :invalid_opts
             | :invalid_timeout
             | :invalid_caller_id
             | :invalid_agent_id
             | :invalid_message
             | :invalid_content
             | :invalid_sender
             | :invalid_engagement_id
             | :unauthorized
             | :unsupported_conversation_capability
             | :delivery_ambiguous
             | :delivery_failed}
  def send_message_response(caller_id, target_agent_id, message, opts \\ []) do
    Arbor.Agent.MessageFacade.deliver_response(caller_id, target_agent_id, message, opts)
  end

  @doc """
  Admit an opt-in durable chat delivery command `%{id: id, text: text}`.

  Requires exactly one `:session_token` or `:signed_request` and a reusable chat
  capability (`max_uses: nil`). Finite-use and unsupported constraints fail
  before consuming usage/rate counters. Live access rechecks do not charge
  constraints again. `:timeout` bounds
  the existing Session delivery (default 30s, maximum 300s). Returns a durable
  command receipt without waiting for the turn. Reusing the same id and exact
  text returns its existing state; changed text conflicts. Every request is
  authenticated before lookup. All conversation APIs accept an optional
  `:expected_engagement_id` continuity fence: it is compared against the owner's
  resolved engagement before any read or admission, never used as a route.
  A mismatch returns `:conversation_scope_changed` and requires clearing cached
  private data and pending commands before reconnecting. After authentication,
  ownership and that fence, a stopped target rejects a new command with
  `:agent_not_running` before admission or dispatch. Saved commands still replay
  their existing state without dispatch; changed text still conflicts. This
  check does not reserve a running Session: a stop after admission retains the
  existing uncertain-delivery semantics. A claimed command is never redispatched,
  even after restart. `:dispatch_started` means its outcome is unknown; `:uncertain`
  is an immutable terminal delivery uncertainty, not permission to retry.

  Session owns execution/transcript commits. Its existing steering semantics
  remain: a delivery is not a promise of an independent Engine turn. These APIs
  are opt-in and do not change existing UI routes or send_message behavior.
  """
  def submit_conversation_command(caller_id, target_agent_id, command, opts \\ []) do
    ConversationFacade.run(:submit, caller_id, target_agent_id, command, opts)
  end

  @doc """
  Build the exact payload a fresh SignedRequest must bind for a conversation operation.

  The versioned JSON array binds operation, original proof subject, full target,
  input, supplied page bounds and the compare-only expected engagement fence.
  Existing version 2 operations have seven array elements. Window reads use the
  separate five-element `arbor.conversation.window.v1` array. Absent bounds and
  fences encode as null. The timeout and proof are not part of this payload.
  Sign the returned bytes without an HTTP
  method/path prefix; never reuse a nonce across operations or retries.
  """
  def conversation_request_payload(operation, caller_id, target_agent_id, input, opts \\ []) do
    ConversationFacade.request_payload(operation, caller_id, target_agent_id, input, opts)
  end

  @doc """
  List an authenticated human's durable private conversations with current chat access.

  Requires exactly one general browser `:session_token` or fresh operation-bound
  `:signed_request`. Linked identities share only canonical conversation ownership;
  grants and revocation remain those of the exact proof subject. `:limit` is 1..100
  (default 20); `:cursor` is a nonnegative position in the live activity order.
  A page may contain no authorized rows while `:has_more` is true. It is not a
  stable history snapshot. Storage/owner/proof failures stay explicit errors.
  Names and 160-grapheme previews are released only after per-agent checks.
  """
  def list_conversations(caller_id, opts \\ []),
    do: Arbor.Agent.ConversationDirectory.run(:list, caller_id, nil, opts)

  @doc """
  Resolve a deep-link reference inside the authenticated human's private directory.

  The server derives its target; an engagement ID grants no authority. Foreign,
  absent or currently denied references return `:not_found`. Subsequent transcript
  reads and sends still use fresh proof and the returned engagement as a comparison
  fence. Options admit only exactly one general session token or signed request.
  """
  def resolve_conversation_reference(caller_id, engagement_id, opts \\ []),
    do: Arbor.Agent.ConversationDirectory.run(:reference, caller_id, engagement_id, opts)

  @doc "Build distinct exact signed bytes for :list or :reference without altering v2/window operation payloads."
  def conversation_index_request_payload(operation, caller_id, input, opts \\ []),
    do: Arbor.Agent.ConversationDirectory.request_payload(operation, caller_id, input, opts)

  @doc "Read one owned command with fresh proof and current release authorization."
  def conversation_command(caller_id, target_agent_id, command_id, opts \\ []) do
    ConversationFacade.run(:command, caller_id, target_agent_id, command_id, opts)
  end

  @doc """
  Replay owned command-journal events after a cursor, with fresh proof.

  Options besides exactly one proof: `:through` pins a replay head and `:limit`
  bounds the page (1..100). This cursor belongs to the command journal, not the
  legacy transcript. The result includes the authoritative `:engagement_id`,
  including empty pages. `:expected_engagement_id` fences every continuation.
  Read access is rechecked immediately before publication.
  """
  def conversation_events(caller_id, target_agent_id, cursor, opts \\ []) do
    ConversationFacade.run(:events, caller_id, target_agent_id, cursor, opts)
  end

  @doc """
  Read the authenticated principal's private legacy transcript page.

  Options besides exactly one proof: `:after`, `:through`, and `:limit` (1..100).
  The transcript ordinal cursor is separate from conversation_events/4 and may
  contain gaps caused by other engagements. `:expected_engagement_id` is a
  compare-only continuity fence; no caller-supplied engagement route is accepted. A stored transcript is not proof that a delivery command settled.
  """
  def conversation_history(caller_id, target_agent_id, opts \\ []) do
    ConversationFacade.run(:history, caller_id, target_agent_id, nil, opts)
  end

  @doc """
  Read a bounded, authenticated notice page from an existing private human
  conversation. Requires a fresh proof and exact expected engagement fence.
  Notice ordinals and pagination are independent from transcript and activity.
  """
  def conversation_notices(subject, target, opts \\ []),
    do: Arbor.Agent.ConversationNotices.read(subject, target, opts)

  @doc "Pure payload for a fresh existing-scope notice read."
  def conversation_notice_request_payload(subject, target, opts \\ []),
    do: Arbor.Agent.ConversationNotices.request_payload(subject, target, opts)

  @doc "Fresh authenticated bounded command activity."
  def conversation_activity(caller_id, target_agent_id, opts \\ []) do
    Arbor.Agent.ConversationFacade.run(:activity, caller_id, target_agent_id, nil, opts)
  end

  @doc """
  Persist intent to cancel one original source command before contacting its
  Session. The acknowledgement distinguishes requested from confirmed stop.
  """
  def cancel_conversation_command(caller_id, target_agent_id, command_id, opts \\ []) do
    Arbor.Agent.ConversationFacade.run(:cancel, caller_id, target_agent_id, command_id, opts)
  end

  @doc """
  Read source-bound choices and approvals for one private conversation command.
  Requires fresh chat proof. This grants no authority to answer an approval.
  """
  def conversation_interactions(caller_id, target_agent_id, command_id, opts \\ []) do
    Arbor.Agent.ConversationInteractions.run(
      :interactions,
      caller_id,
      target_agent_id,
      command_id,
      opts
    )
  end

  @doc """
  Answer the exact pending choice, including its command, request, operation,
  revision and choice IDs. The owning source checks and consumes fresh proof.
  """
  def answer_conversation_choice(caller_id, target_agent_id, input, opts \\ []) do
    Arbor.Agent.ConversationInteractions.run(
      :interaction_choice,
      caller_id,
      target_agent_id,
      input,
      opts
    )
  end

  @doc """
  Answer the exact pending approval with a current general human session and
  the original request's scoped approval-answer authority. A terminal chat
  session alone cannot answer a protected approval.
  """
  def answer_conversation_approval(caller_id, target_agent_id, input, opts \\ []) do
    Arbor.Agent.ConversationInteractions.run(
      :interaction_approval,
      caller_id,
      target_agent_id,
      input,
      opts
    )
  end

  @doc """
  Build the closed payload to sign for an interaction read or answer.
  The optional engagement ID is a compare-only continuity fence.
  """
  def conversation_interaction_request_payload(
        operation,
        caller_id,
        target_agent_id,
        input,
        expected_engagement_id \\ nil
      ) do
    Arbor.Agent.ConversationInteractions.request_payload(
      operation,
      caller_id,
      target_agent_id,
      input,
      expected_engagement_id
    )
  end

  @doc """
  Read a bounded latest/older/newer private transcript window with fresh proof.

  `:before` and `:after` are exclusive ordinal selectors; omit both for the
  latest window. `:through` pins its head, and `:limit` is 1..100 (default 20).
  Returned entries are ascending and source-identified. Navigation flags and
  first/last ordinals concern transcript entries, never command-journal cursors.
  The server derives the engagement; `:expected_engagement_id` only compares it.

  Signed callers bind the distinct `arbor.conversation.window.v1` payload from
  `conversation_request_payload(:window, caller, target, nil, opts)`. Existing
  history, events and command v2 payloads are unchanged. Reads are authorized
  again immediately before private output is released.
  """
  def conversation_window(caller_id, target_agent_id, opts \\ []) do
    ConversationFacade.run(:window, caller_id, target_agent_id, nil, opts)
  end

  # ===========================================================================
  # Public API — Authorized managed-task dispatch (owner-scoped)
  # ===========================================================================

  @doc """
  Dispatch one managed, owner-scoped async task after capability authorization.

  Delegates to `Arbor.Agent.Orchestration.dispatch/3` with fixed production
  collaborators. The optional `:session_token` human proof is forwarded only
  into `Arbor.Security.authorize/4` and is stripped before TaskStore, grants,
  audit, or retained orchestration state.

  ## Options

  - `:session_token` — optional human session proof (non-empty binary ≤4096)

  Unknown, duplicate, nil, empty, non-binary, or oversized options are rejected
  before authorization or dispatch. Absence of `:session_token` is allowed.

  ## Returns

  - `{:ok, task_id}` when orchestration returns a stable task id immediately
  - `{:error, reason}` with a closed atom vocabulary (no content/capability leakage)
  """
  @spec dispatch_task(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             :invalid_opts
             | :invalid_caller_id
             | :invalid_agent_id
             | :invalid_task
             | :unauthorized
             | :dispatch_failed}
  def dispatch_task(caller_id, target_agent_id, task, opts \\ []) do
    # Fixed production collaborator only — never selectable via public opts.
    # Tests inject via DispatchFacade.dispatch/5, never module/MFA opts.
    Arbor.Agent.DispatchFacade.dispatch(
      caller_id,
      target_agent_id,
      task,
      opts,
      &Arbor.Agent.Orchestration.dispatch/3
    )
  end

  @doc """
  Project one read-only Agent-owned coding-dispatch readiness report.

  Aggregates bounded Security restore health, coordinator liveness, exact
  template provenance/drift, six-member task-control provisioning readiness,
  and the configured executor projection — before any TaskStore identity
  exists. Reuses the dispatch authorization gate. Authorized calls always
  return `{:ok, report}` even when readiness is blocked or degraded.

  ## Options

  - `:session_token` — optional human session proof (non-empty binary ≤4096)
  - `:timeout` — optional positive integer milliseconds forwarded unchanged into
    the configured executor readiness context (never as a task id). Any positive
    timeout is accepted and forwarded; there is no artificial facade ceiling.

  Unknown, duplicate, nil, empty, non-binary, non-positive, or oversized options
  are rejected before authorization. Session proofs reach only
  `Security.authorize/4`.
  """
  @spec coding_dispatch_readiness(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :invalid_opts
             | :invalid_caller_id
             | :invalid_agent_id
             | :invalid_task
             | :unauthorized
             | :readiness_failed}
  def coding_dispatch_readiness(caller_id, target_agent_id, task, opts \\ []) do
    Arbor.Agent.DispatchReadinessFacade.project(
      caller_id,
      target_agent_id,
      task,
      opts,
      &Arbor.Agent.Orchestration.coding_dispatch_readiness/3
    )
  end

  @doc """
  Project one read-only target-scoped template-authority reconciliation preview.

  Classifies only source-tagged authority-template grants and exact legacy
  persisted-template matches as managed, compares effective desired authority
  with managed live capabilities and trust, and returns a bounded JSON-clean
  report with a deterministic reconciliation digest. Reuses the dispatch
  authorization gate. Authorized calls always return `{:ok, report}` even when
  observed state is drifted, unmanaged, invalid, or unavailable.

  ## Options

  - `:session_token` — optional human session proof (non-empty binary ≤4096)

  Unknown, duplicate, nil, empty, non-binary, or oversized options are rejected
  before authorization. Session proofs reach only `Security.authorize/4`.
  Dependency injection is unavailable through public options.
  """
  @spec template_authority_preview(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :invalid_opts
             | :invalid_caller_id
             | :invalid_agent_id
             | :unauthorized
             | :preview_failed}
  def template_authority_preview(caller_id, target_agent_id, opts \\ []) do
    # Fixed production collaborator only — never selectable via public opts.
    Arbor.Agent.TemplateAuthorityPreviewFacade.project(
      caller_id,
      target_agent_id,
      opts,
      &Arbor.Agent.Orchestration.template_authority_preview/2
    )
  end

  # ===========================================================================
  # Public API — Authorized versions (for callers that need capability checks)
  # ===========================================================================

  @doc """
  Start a supervised agent with authorization check.

  Verifies the caller has the `arbor://agent/spawn` capability before
  creating the agent. Use this when spawning agents on behalf of another
  agent or external request.

  ## Parameters

  - `caller_id` - The ID of the entity requesting agent spawn
  - `agent_id` - Unique identifier for the new agent
  - `agent_module` - The Jido agent module to run
  - `initial_state` - Initial state map (default: %{})
  - `opts` - Additional options (same as `start/4`)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, :unauthorized}` if caller lacks capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other failure
  """
  @spec authorize_spawn(String.t(), String.t(), module(), map(), keyword()) ::
          {:ok, pid()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
  def authorize_spawn(caller_id, agent_id, agent_module, initial_state \\ %{}, opts \\ []) do
    resource = "arbor://agent/spawn"

    case Arbor.Security.authorize(caller_id, resource, :spawn) do
      {:ok, :authorized} ->
        start(agent_id, agent_module, initial_state, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Execute an action on a running agent with authorization check.

  Verifies the caller has the canonical facade capability (e.g. `arbor://fs/read`)
  before executing. Use this when an agent is executing actions on behalf of
  another agent or external request.

  ## Parameters

  - `caller_id` - The ID of the entity requesting action execution
  - `agent_id` - The target agent's ID
  - `action` - Action module or `{action_module, params}` tuple
  - `timeout` - Call timeout in ms (default: 5000)

  ## Returns

  - `{:ok, result}` on success
  - `{:error, :unauthorized}` if caller lacks capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other failure
  """
  @spec authorize_action(String.t(), String.t(), module() | {module(), map()}, timeout()) ::
          {:ok, any()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | :not_found | any()}
  def authorize_action(caller_id, agent_id, action, timeout \\ 5000) do
    action_module = extract_action_module(action)
    resource = Arbor.Actions.canonical_uri_for(action_module, %{})

    case Arbor.Security.authorize(caller_id, resource, :execute) do
      {:ok, :authorized} ->
        run_action(agent_id, action, timeout)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Stop a running agent with authorization check.

  Verifies the caller has the `arbor://agent/stop/{agent_id}` capability
  before stopping the agent.

  ## Parameters

  - `caller_id` - The ID of the entity requesting the stop
  - `agent_id` - The agent to stop
  - `opts` - Existing Gateway signed proof, or only `:session_token` for a
    general human session. Present session proof always uses the strict session
    path and cannot be combined with other authority options.

  ## Returns

  - `:ok` on success
  - `{:error, {:unauthorized, reason}}` if caller lacks capability
  - `{:ok, :pending_approval, proposal_id}` without stopping the agent if approval is required
  - `{:error, :not_found}` if agent is not running
  """
  @spec authorize_stop(String.t(), String.t(), keyword()) ::
          :ok
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | :not_found}
  def authorize_stop(caller_id, agent_id, opts \\ [])

  def authorize_stop(caller_id, agent_id, opts) when is_binary(agent_id) do
    resource = "arbor://agent/stop/#{agent_id}"

    authorization =
      if is_list(opts) and Keyword.keyword?(opts) do
        if Keyword.has_key?(opts, :session_token),
          do: authorize_management_session(caller_id, agent_id, resource, :stop, opts),
          else: authorize(caller_id, resource, :stop, opts)
      else
        {:error, :invalid_management_options}
      end

    case authorization do
      :ok -> stop(agent_id)
      {:ok, :pending_approval, _proposal_id} = pending -> pending
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  def authorize_stop(_, _, _), do: {:error, {:unauthorized, :invalid_management_options}}

  @doc """
  Create an agent with authorization check.

  Verifies the caller has the `arbor://agent/lifecycle/create` capability.
  Pending approval is returned to the caller without creating an agent.
  An unavailable security service denies the operation.

  ## Parameters

  - `caller_id` - The ID of the entity creating the agent
  - `agent_id` - The new agent's ID
  - `opts` - Options passed to `create_agent/2`
  """
  @spec authorize_create(String.t(), String.t(), keyword()) ::
          {:ok, term()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_create(caller_id, agent_id, opts \\ []) do
    resource = "arbor://agent/lifecycle/create"
    {auth, create_opts} = Keyword.pop(opts, :signed_request)
    {session_token, create_opts} = Keyword.pop(create_opts, :session_token)
    {actor_authority, create_opts} = Keyword.pop(create_opts, :actor_authority)

    auth_opts =
      [signed_request: auth]
      |> maybe_put_authorization_opt(:session_token, session_token)

    case authorize(caller_id, resource, :create, auth_opts) do
      :ok ->
        create_with_actor_authority(
          caller_id,
          agent_id,
          create_opts,
          actor_authority,
          session_token
        )

      {:ok, :pending_approval, _proposal_id} = pending ->
        pending

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  defp create_with_actor_authority(caller_id, agent_id, create_opts, authority, _session_token)
       when not is_nil(authority) do
    with_matching_authority(caller_id, authority, fn ->
      create_agent(agent_id, Keyword.put(create_opts, :actor_authority, authority))
    end)
  end

  defp create_with_actor_authority(caller_id, agent_id, create_opts, nil, session_token)
       when is_binary(session_token) do
    case Arbor.Security.open_agent_lifecycle_authority(session_token) do
      {:ok, authority} ->
        try do
          with_matching_authority(caller_id, authority, fn ->
            create_agent(agent_id, Keyword.put(create_opts, :actor_authority, authority))
          end)
        after
          Arbor.Security.close_signing_authority(authority)
        end

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  defp create_with_actor_authority(_caller_id, _agent_id, _create_opts, nil, _session_token),
    do: {:error, {:unauthorized, :capability_mutation_unauthorized}}

  defp maybe_put_authorization_opt(opts, _key, nil), do: opts
  defp maybe_put_authorization_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Destroy an agent with authorization check.

  Verifies the caller has the `arbor://agent/lifecycle/destroy` capability.
  This is a high-privilege operation that deletes all agent data.
  Pending approval and unavailable security never permit deletion.

  ## Parameters

  - `caller_id` - The ID of the entity requesting destruction
  - `agent_id` - The agent to destroy
  """
  @spec authorize_destroy(String.t(), String.t()) ::
          :ok
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_destroy(_caller_id, _agent_id),
    do: {:error, {:unauthorized, :capability_mutation_unauthorized}}

  @doc """
  Destroy an exact agent using a general human session proof.

  Requires `arbor://agent/lifecycle/destroy/{agent_id}` and an active general
  human session belonging to `caller_id`. Only `:session_token` is accepted;
  missing, mixed or malformed proof never falls back to the legacy two-argument
  management API. Pending approval returns without deleting any agent data.
  """
  @spec authorize_destroy(String.t(), String.t(), keyword()) ::
          :ok | {:ok, :pending_approval, String.t()} | {:error, {:unauthorized, term()} | term()}
  def authorize_destroy(caller_id, agent_id, opts) when is_binary(agent_id) do
    resource = "arbor://agent/lifecycle/destroy/#{agent_id}"

    if is_list(opts) and Keyword.keyword?(opts) do
      {actor_authority, auth_opts} = Keyword.pop(opts, :actor_authority)
      session_token = Keyword.get(auth_opts, :session_token)

      authorization =
        if is_binary(session_token) do
          authorize_management_session(caller_id, agent_id, resource, :destroy, auth_opts)
        else
          authorize(caller_id, resource, :destroy, auth_opts)
        end

      case authorization do
        :ok ->
          destroy_with_actor_authority(caller_id, agent_id, actor_authority, session_token)

        {:ok, :pending_approval, _proposal_id} = pending ->
          pending

        {:error, reason} ->
          {:error, {:unauthorized, reason}}
      end
    else
      {:error, {:unauthorized, :invalid_management_options}}
    end
  end

  def authorize_destroy(_, _, _), do: {:error, {:unauthorized, :invalid_management_options}}

  defp destroy_with_actor_authority(caller_id, agent_id, authority, _session_token)
       when not is_nil(authority) do
    with_matching_authority(caller_id, authority, fn ->
      Lifecycle.destroy(agent_id, actor_authority: authority)
    end)
  end

  defp destroy_with_actor_authority(caller_id, agent_id, nil, session_token)
       when is_binary(session_token) do
    case Arbor.Security.open_agent_lifecycle_authority(session_token) do
      {:ok, authority} ->
        try do
          with_matching_authority(caller_id, authority, fn ->
            Lifecycle.destroy(agent_id, actor_authority: authority)
          end)
        after
          Arbor.Security.close_signing_authority(authority)
        end

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  defp destroy_with_actor_authority(_caller_id, _agent_id, nil, _session_token),
    do: {:error, {:unauthorized, :capability_mutation_unauthorized}}

  defp with_matching_authority(caller_id, authority, callback) when is_function(callback, 0) do
    case Arbor.Security.signing_authority_principal(authority) do
      {:ok, ^caller_id} -> callback.()
      _ -> {:error, {:unauthorized, :capability_mutation_unauthorized}}
    end
  end

  @doc """
  Restore an agent with authorization check.

  Verifies the caller has the `arbor://agent/lifecycle/restore` capability.
  Pending approval is returned without reading or migrating a stored profile.
  An unavailable security service denies the operation.

  ## Parameters

  - `caller_id` - The ID of the entity requesting the restore
  - `agent_id` - The agent to restore
  """
  @spec authorize_restore(String.t(), String.t(), keyword()) ::
          {:ok, term()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_restore(caller_id, agent_id, opts \\ []) do
    resource = "arbor://agent/lifecycle/restore"

    case authorize(caller_id, resource, :restore, opts) do
      :ok -> restore_agent(agent_id)
      {:ok, :pending_approval, _proposal_id} = pending -> pending
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  # ===========================================================================
  # Public API — Unchecked versions (for system-level callers)
  # ===========================================================================

  @doc """
  Start a supervised agent.

  ## Parameters

  - `agent_id` - Unique identifier for the agent
  - `agent_module` - The Jido agent module to run
  - `initial_state` - Initial state map (default: %{})
  - `opts` - Additional options

  ## Options

  - `:checkpoint_storage` - Storage backend module (e.g., `Arbor.Persistence.Checkpoint.Store.ETS`)
  - `:auto_checkpoint_interval` - Auto-save interval in ms (e.g., 30_000)
  - `:metadata` - Additional metadata map
  - `:restart` - Supervision restart strategy (default: `:transient`)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start(String.t(), module(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(_agent_id, _agent_module, _initial_state \\ %{}, _opts \\ []) do
    # Legacy Jido agent path — Agent.Server was removed.
    # Use Lifecycle.create + Lifecycle.start for all agent creation.
    Logger.warning(
      "Arbor.Agent.start/4 is deprecated. Use Lifecycle.create + Lifecycle.start instead."
    )

    {:error, :deprecated_use_lifecycle}
  end

  @doc """
  Stop a running agent.

  The agent will save a final checkpoint (if storage is configured)
  before terminating.

  ## Returns

  - `:ok` on success
  - `{:error, :not_found}` if agent is not running
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(agent_id) do
    # Agents created via Lifecycle run under per-user BranchSupervisors (the
    # modern path: UserSupervisor → user_sup:<principal> → BranchSupervisor), NOT
    # the legacy `Arbor.Agent.Supervisor` DynamicSupervisor — so `stop_agent_by_id`
    # always `:not_found`ed for them. Route teardown through `Lifecycle.stop/1`,
    # which stops the whole BranchSupervisor tree and unregisters. We check the
    # registry first so a genuinely-absent agent still reports `{:error,
    # :not_found}` (e.g. the gateway's 404), rather than the idempotent `:ok`
    # `Lifecycle.stop/1` returns unconditionally.
    case Registry.whereis(agent_id) do
      {:ok, _pid} -> Lifecycle.stop(agent_id)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Execute an action on a running agent.

  ## Parameters

  - `agent_id` - The agent's ID
  - `action` - Action module or `{action_module, params}` tuple
  - `timeout` - Call timeout in ms (default: 5000)

  ## Returns

  - `{:ok, result}` on success
  - `{:error, :not_found}` if agent is not running
  - `{:error, reason}` on action failure
  """
  @spec run_action(String.t(), module() | {module(), map()}, timeout()) ::
          {:ok, any()} | {:error, any()}
  def run_action(agent_id, action, _timeout \\ 5000) do
    # Route through APIAgent.execute_action if host is running
    case Arbor.Agent.BranchSupervisor.child_pids(agent_id) do
      %{host: pid} when is_pid(pid) ->
        {action_module, params} =
          case action do
            {mod, p} -> {mod, p}
            mod when is_atom(mod) -> {mod, %{}}
          end

        Arbor.Agent.APIAgent.execute_action(pid, action_module, params)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the current state of an agent.

  Returns the agent's metadata from the registry.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.metadata}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get metadata for a running agent.
  """
  @spec get_metadata(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_metadata(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.metadata}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Inspectable summary of an agent — the "2am rule".

  Single Convert function that pulls from all 4 domains (authority, config,
  context, telemetry) and returns one map answering: who is this agent, how
  is it set up, what is it doing right now, and how is it performing?

  Designed to be readable in one screen without scrolling. Returns
  `{:error, :not_found}` if no profile exists for the agent.

  ## Example

      iex> Arbor.Agent.summary("agent_abc123")
      {:ok, %{
        agent_id: "agent_abc123",
        display_name: "Diagnostician",
        status: :running,
        template: :diagnostician,
        model: "anthropic/claude-sonnet-4-5",
        turn_count: 42,
        active_goals_count: 3,
        session_cost: 0.15,
        avg_latency_ms: 1240
      }}
  """
  @spec summary(String.t()) :: {:ok, map()} | {:error, :not_found}
  def summary(agent_id) when is_binary(agent_id) do
    case load_profile(agent_id) do
      {:ok, profile} -> {:ok, build_summary(agent_id, profile)}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Best-effort model id from an agent's registry OR profile metadata.

  Tolerant of both metadata shapes — the live-registry `:model_config` and the
  persisted-profile `:last_model_config` — and of atom- vs string-keyed maps:
  profile metadata round-trips through JSON, which string-keys everything except
  a few known atoms, so `last_model_config` and its inner `id` come back as
  strings. Returns the model id string, or `nil` if none is recorded.
  """
  @spec model_id_from_metadata(map() | nil) :: String.t() | nil
  def model_id_from_metadata(metadata) when is_map(metadata) do
    config =
      Map.get(metadata, :model_config) || Map.get(metadata, "model_config") ||
        Map.get(metadata, :last_model_config) || Map.get(metadata, "last_model_config")

    case config do
      %{} = c -> Map.get(c, :id) || Map.get(c, "id")
      _ -> nil
    end
  end

  def model_id_from_metadata(_), do: nil

  defp build_summary(agent_id, profile) do
    running? = match?({:ok, _}, lookup(agent_id))
    telemetry = safe_call(fn -> telemetry_summary_for(agent_id) end)
    goals = safe_call(fn -> Arbor.Memory.get_active_goals(agent_id) end) || []

    %{
      # Identity (who)
      agent_id: agent_id,
      display_name: profile.display_name || agent_id,
      status: if(running?, do: :running, else: :stopped),

      # Configuration (how it's set up)
      template: profile.template,
      model: model_id_from_metadata(profile.metadata),

      # Current activity (what it's doing now)
      turn_count: telemetry && telemetry.turn_count,
      active_goals_count: length(goals),

      # Telemetry (how it's performing)
      session_cost: telemetry && telemetry.session_cost,
      avg_latency_ms: telemetry && telemetry.llm_p50_ms
    }
  end

  defp telemetry_summary_for(agent_id) do
    case Arbor.Common.AgentTelemetry.Store.get(agent_id) do
      nil ->
        nil

      telemetry ->
        %{
          turn_count: telemetry.turn_count,
          session_cost: telemetry.session_cost,
          llm_p50_ms: percentile(telemetry.llm_latencies, 50)
        }
    end
  end

  defp percentile([], _), do: nil

  defp percentile(values, p) when is_list(values) do
    sorted = Enum.sort(values)
    idx = round(length(sorted) * p / 100) - 1
    Enum.at(sorted, max(idx, 0))
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  Manually trigger a checkpoint save for an agent.
  """
  @spec checkpoint(String.t()) :: :ok | {:error, term()}
  def checkpoint(_agent_id) do
    # Checkpointing is now handled by Session persistence, not Agent.Server
    :ok
  end

  @doc """
  Look up an agent by ID.

  ## Returns

  - `{:ok, entry}` with agent info (pid, module, metadata)
  - `{:error, :not_found}` if not registered
  """
  @spec lookup(String.t()) :: {:ok, Registry.agent_entry()} | {:error, :not_found}
  def lookup(agent_id) do
    Registry.lookup(agent_id)
  end

  @doc """
  Get the PID of a running agent.

  ## Returns

  - `{:ok, pid}` if found and alive
  - `{:error, :not_found}` otherwise
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(agent_id) do
    Registry.whereis(agent_id)
  end

  @doc """
  List all running agents.

  ## Returns

  - `{:ok, [entry]}` list of agent entries
  """
  @spec list() :: {:ok, [Registry.agent_entry()]}
  def list do
    Registry.list()
  end

  @doc """
  Count running agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    Registry.count()
  end

  @doc """
  Check if an agent is running.
  """
  @spec running?(String.t()) :: boolean()
  def running?(agent_id) do
    case Registry.whereis(agent_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  # ===========================================================================
  # Template Management
  # ===========================================================================

  @doc "List all available agent templates."
  @spec list_templates() :: [map()]
  defdelegate list_templates(), to: Arbor.Agent.TemplateStore, as: :list

  @doc "Get a template by name."
  @spec get_template(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_template(name), to: Arbor.Agent.TemplateStore, as: :get

  @doc "Store a template by name."
  @spec put_template(String.t(), map()) :: :ok | {:error, term()}
  defdelegate put_template(name, data), to: Arbor.Agent.TemplateStore, as: :put

  @doc "Delete a template by name."
  @spec delete_template(String.t()) :: :ok | {:error, :builtin_protected}
  defdelegate delete_template(name), to: Arbor.Agent.TemplateStore, as: :delete

  @doc "Create a template from keyword options."
  @spec create_template(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate create_template(name, opts), to: Arbor.Agent.TemplateStore, as: :create_from_opts

  @doc "Reload all templates from disk."
  @spec reload_templates() :: :ok
  defdelegate reload_templates(), to: Arbor.Agent.TemplateStore, as: :reload

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Only an affirmative authorization permits a lifecycle effect. Pending
  # approval stays pending; missing security infrastructure is a denial.
  defp authorize(caller_id, resource, action, opts) do
    if security_available?() do
      case Arbor.Security.authorize(caller_id, resource, action, auth_opts(opts)) do
        {:ok, :authorized} -> :ok
        {:ok, :pending_approval, _proposal_id} = pending -> pending
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :security_unavailable}
    end
  end

  # Browser management has a closed proof grammar. Never forward caller flags
  # such as :identity_verified or convert a rejected session into legacy auth.
  defp authorize_management_session(caller_id, agent_id, resource, action, opts) do
    with true <- valid_management_id?(caller_id, "human_"),
         true <- valid_management_id?(agent_id, "agent_"),
         [{:session_token, token}] <- opts,
         true <- is_binary(token) and byte_size(token) in 1..4096,
         true <- security_available?() do
      case Arbor.Security.authorize(caller_id, resource, action, session_token: token) do
        {:ok, :authorized} -> :ok
        {:ok, :pending_approval, _proposal_id} = pending -> pending
        {:error, reason} -> {:error, reason}
        _ -> {:error, :security_unavailable}
      end
    else
      false -> {:error, :management_authority_required}
      _ -> {:error, :invalid_management_options}
    end
  rescue
    _ -> {:error, :security_unavailable}
  catch
    _, _ -> {:error, :security_unavailable}
  end

  defp valid_management_id?(id, prefix) when is_binary(id) do
    byte_size(id) <= 256 and String.starts_with?(id, prefix) and
      Regex.match?(~r/\A(?:human|agent)_[A-Za-z0-9_-]+\z/, id)
  end

  defp valid_management_id?(_, _), do: false

  # When the caller forwards a `:signed_request` it has ALREADY verified (the
  # gateway's SignedRequestAuth verifies the Ed25519 per-request signature, binds
  # the signer to the principal, and consumes the single-use nonce before calling
  # us), we mark the auth context `identity_verified: true` so AuthDecision skips
  # re-verification. We must NOT re-verify here: `identity_verification` is config-ON
  # in dev/prod, and the nonce is single-use — re-running `Verifier.verify` would
  # trip the replay guard (`:replayed_nonce`). Without the forwarded proof these
  # gates would instead reject as `:missing_signed_request`. The signed_request is
  # still threaded for audit/event context.
  defp auth_opts(opts) do
    case Keyword.get(opts, :signed_request) do
      nil -> []
      sr -> [signed_request: sr, identity_verified: true]
    end
  end

  defp security_available? do
    Arbor.Security.capability_authorization_available?()
  end

  # Extract the action module from an action spec (module or {module, params} tuple)
  defp extract_action_module({action_module, _params}) when is_atom(action_module) do
    action_module
  end

  defp extract_action_module(action_module) when is_atom(action_module) do
    action_module
  end

  # Test-only fixtures, absent from non-test builds (same convention as
  # Arbor.Security.grant_fixture/1). See Arbor.Agent.LifecycleActorFixture.
  if Mix.env() == :test do
    alias Arbor.Agent.LifecycleActorFixture

    @doc false
    @spec open_lifecycle_actor_fixture(keyword()) :: {:ok, map()} | {:error, term()}
    def open_lifecycle_actor_fixture(opts \\ []), do: LifecycleActorFixture.open(opts)

    @doc false
    @spec reopen_lifecycle_actor_fixture(map()) :: {:ok, map()} | {:error, term()}
    def reopen_lifecycle_actor_fixture(fixture), do: LifecycleActorFixture.reopen(fixture)

    @doc false
    @spec close_lifecycle_actor_fixture(map()) :: :ok
    def close_lifecycle_actor_fixture(fixture), do: LifecycleActorFixture.close(fixture)

    @doc false
    @spec destroy_agent_fixture(String.t(), map()) :: :ok | {:error, term()}
    def destroy_agent_fixture(agent_id, fixture),
      do: LifecycleActorFixture.destroy_agent(agent_id, fixture)
  end
end
