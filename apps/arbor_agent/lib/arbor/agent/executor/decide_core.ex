defmodule Arbor.Agent.Executor.DecideCore do
  @moduledoc """
  Pure decide step for the agent Executor (Body).

  Given an intent and an injected snapshot of already-gathered verdicts, this
  core says what should happen next. It never calls Security, Trust, Memory,
  Comms, or Jido. `authorize_and_execute/4` remains the only path that actually
  runs an action — the shell interprets `{:execute, ...}`.

  ## Decisions

    * `{:execute, action, params, sandbox}` — run the Jido action
    * `{:skip, type}` — mental intent (`:think` / `:wait` / `:reflect` / `:internal`);
      no capability check, no dispatch
    * `{:block, reason}` — deny; shell fails the intent
    * `{:ask, resource, meta}` — kernel returned pending approval; shell parks
      (does **not** fail the intent)
    * `{:reject_sender, reason}` — `source_agent` failed sender authorization

  Heartbeat-tagged `:act` intents are **not** an auth exception. The retired
  trust-tier auto-authorize path lived in `Executor.check_capabilities/2`; this
  core requires a real `auth_verdict` for every `:act`. See
  `.arbor/decisions/2026-08-25-executor-decide-core.md`.
  """

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Security.SandboxLevel

  @mental_types [:think, :wait, :reflect, :internal]

  @type sender_verdict :: :ok | {:error, term()}
  @type reflex_verdict :: :ok | {:blocked, term(), term()} | term()

  @type auth_verdict ::
          {:ok, :authorized}
          | {:ok, :pending_approval, term()}
          | {:error, term()}
          | nil
          | term()

  @type snapshot :: %{
          optional(:agent_id) => String.t() | nil,
          optional(:sandbox_level) => atom() | String.t() | nil,
          optional(:sender_verdict) => sender_verdict(),
          optional(:reflex_verdict) => reflex_verdict(),
          optional(:auth_verdict) => auth_verdict(),
          optional(:canonical_uri) => String.t() | nil
        }

  @type state :: %{
          intent: Intent.t() | nil,
          agent_id: String.t() | nil,
          sandbox_level: SandboxLevel.t(),
          sender_verdict: sender_verdict(),
          reflex_verdict: reflex_verdict(),
          auth_verdict: auth_verdict(),
          canonical_uri: String.t() | nil
        }

  @type ask_meta :: %{approval_id: term()}

  @type decision ::
          {:execute, atom() | String.t() | term(), map(), atom()}
          | {:skip, atom()}
          | {:block, term()}
          | {:ask, String.t(), ask_meta()}
          | {:reject_sender, term()}

  @type shown :: %{required(:decision) => atom(), optional(atom()) => term()}

  # ── Construct ──────────────────────────────────────────────────────────────

  @doc """
  Normalize an intent plus an injected snapshot into the core's state.

  Snapshot keys may be atoms or strings. Missing `sender_verdict` /
  `reflex_verdict` default to `:ok` (the shell already ran those checks).
  Missing `auth_verdict` stays `nil` so `:act` fails closed.
  """
  @spec new(term(), map()) :: state()
  def new(%Intent{} = intent, snapshot) when is_map(snapshot) do
    %{
      intent: intent,
      agent_id: fetch(snapshot, :agent_id),
      sandbox_level: SandboxLevel.coerce(fetch(snapshot, :sandbox_level)),
      sender_verdict: fetch(snapshot, :sender_verdict, :ok),
      reflex_verdict: fetch(snapshot, :reflex_verdict, :ok),
      auth_verdict: fetch(snapshot, :auth_verdict),
      canonical_uri: fetch(snapshot, :canonical_uri)
    }
  end

  def new(_intent, snapshot) when is_map(snapshot) do
    new_invalid(snapshot)
  end

  def new(_intent, _snapshot), do: new_invalid(%{})

  # ── Reduce ─────────────────────────────────────────────────────────────────

  @doc """
  Decide the next Executor effect.

  Accepts either `new/2` state or `(intent, snapshot)` for a one-shot call.
  """
  @spec decide(state()) :: decision()
  @spec decide(term(), map()) :: decision()
  def decide(intent, snapshot) when is_map(snapshot) do
    intent |> new(snapshot) |> decide()
  end

  def decide(%{intent: intent} = state) do
    cond do
      is_nil(intent) or not is_struct(intent, Intent) ->
        {:block, :invalid_intent}

      sender_error?(state.sender_verdict) ->
        {:reject_sender, sender_reason(state.sender_verdict)}

      reflex_blocked?(state.reflex_verdict) ->
        {:block, reflex_reason(state.reflex_verdict)}

      mental?(intent) ->
        {:skip, intent.type}

      intent.type != :act ->
        {:block, :unknown_intent_type}

      is_nil(intent.action) ->
        {:block, :missing_action}

      true ->
        decide_act(intent, state)
    end
  end

  def decide(_other), do: {:block, :invalid_intent}

  # ── Convert ────────────────────────────────────────────────────────────────

  @doc "Format a decision as a plain map for logs/tests."
  @spec show(decision()) :: shown()
  def show({:execute, action, params, sandbox}) do
    %{decision: :execute, action: action, params: params, sandbox: sandbox}
  end

  def show({:skip, reason}), do: %{decision: :skip, reason: reason}
  def show({:block, reason}), do: %{decision: :block, reason: reason}

  def show({:ask, resource, meta}) do
    %{decision: :ask, resource: resource, meta: meta}
  end

  def show({:reject_sender, reason}) do
    %{decision: :reject_sender, reason: reason}
  end

  def show(other), do: %{decision: :invalid, value: other}

  # ── Private ────────────────────────────────────────────────────────────────

  defp decide_act(intent, state) do
    sandbox = SandboxLevel.to_shell(state.sandbox_level)
    params = inject_sandbox(intent.params, sandbox)

    case state.auth_verdict do
      {:ok, :authorized} ->
        {:execute, intent.action, params, sandbox}

      {:ok, :pending_approval, id} when is_binary(id) and id != "" ->
        {:ask, resource_uri(intent, state), %{approval_id: id}}

      {:ok, :pending_approval, _id} ->
        {:block, :missing_approval_id}

      {:error, reason} ->
        {:block, reason}

      nil ->
        {:block, :missing_auth_verdict}

      other ->
        {:block, {:unexpected_auth_verdict, other}}
    end
  end

  defp mental?(%Intent{type: type}) when type in @mental_types, do: true
  defp mental?(_), do: false

  defp sender_error?({:error, _}), do: true
  defp sender_error?(_), do: false

  defp sender_reason({:error, reason}), do: reason
  defp sender_reason(other), do: other

  defp reflex_blocked?({:blocked, _reflex, _reason}), do: true
  defp reflex_blocked?(_), do: false

  defp reflex_reason({:blocked, _reflex, reason}), do: reason
  defp reflex_reason(other), do: other

  defp inject_sandbox(params, sandbox) when is_map(params), do: Map.put(params, :sandbox, sandbox)
  defp inject_sandbox(_params, sandbox), do: %{sandbox: sandbox}

  defp resource_uri(_intent, %{canonical_uri: uri}) when is_binary(uri) and uri != "" do
    uri
  end

  defp resource_uri(%Intent{action: action}, _state) when is_binary(action) and action != "" do
    "arbor://agent/action/#{action}"
  end

  defp resource_uri(%Intent{action: action}, _state)
       when is_atom(action) and not is_nil(action) do
    "arbor://agent/action/#{action}"
  end

  defp resource_uri(_intent, _state), do: "arbor://agent/action/unknown"

  defp new_invalid(snapshot) when is_map(snapshot) do
    %{
      intent: nil,
      agent_id: fetch(snapshot, :agent_id),
      sandbox_level: SandboxLevel.coerce(fetch(snapshot, :sandbox_level)),
      sender_verdict: fetch(snapshot, :sender_verdict, :ok),
      reflex_verdict: fetch(snapshot, :reflex_verdict, :ok),
      auth_verdict: fetch(snapshot, :auth_verdict),
      canonical_uri: fetch(snapshot, :canonical_uri)
    }
  end

  defp fetch(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
