defmodule Arbor.Voice.Config do
  @moduledoc """
  Configuration seam for arbor_voice (CONTRACT_RULES §8). One function per
  setting, reading Application.get_env(:arbor_voice, key, default) with a
  default matching current behaviour.

  The `budget_*` accessors (VP-04B) are each split into a pure `validate_*/1`
  (or `/2`) function — no `Application.get_env` read, so it is directly
  testable with literal terms — plus a thin shell wrapper of the same name
  minus `validate_` that reads the configured (or default) value and pipes it
  through the validator. Absent config uses the literal default; a *present*
  but malformed value fails closed rather than silently substituting the
  default.
  """

  @doc """
  The Arbor.Voice.RealtimeBackend implementation Arbor.Voice.Session
  (VP-04) opens. Swappable via `config :arbor_voice, backend: MyBackend`.
  Defaults to `Arbor.Voice.Backend.XaiRealtime` (VP-03) — nothing calls this
  default until `Arbor.Voice.Session` (VP-04) exists.
  """
  @spec backend_module() :: module()
  def backend_module,
    do: Application.get_env(:arbor_voice, :backend, Arbor.Voice.Backend.XaiRealtime)

  @doc """
  Identifier used to resolve the :user-scoped engagement voice shares with
  the dashboard (VOICE-2). nil until an operator configures it (VP-04
  defines how the value is chosen/defaulted).
  """
  @spec user_id() :: String.t() | nil
  def user_id, do: Application.get_env(:arbor_voice, :user_id)

  # ---------------------------------------------------------------------------
  # Durable daily voice budget ledger (VP-04B, prerequisite for VOICE-24)
  # ---------------------------------------------------------------------------

  @default_daily_budget_ms 3_600_000
  @max_daily_budget_ms 86_400_000
  @default_budget_reservation_grace_ms 60_000
  @max_budget_reservation_grace_ms 3_600_000
  @default_budget_cas_max_retries 5
  @max_budget_cas_max_retries 20
  @budget_namespace :voice_daily_budgets
  @max_backend_opts_count 32
  @max_backend_opts_encoded_bytes 4096
  # Speech-output acceptance timeout (VP-04E2R1): source-owned hard ceiling.
  @default_speech_output_timeout_ms 100
  @max_speech_output_timeout_ms 250
  # Tool-router timeout (VP-04E3): source-owned hard ceiling.
  @default_tool_router_timeout_ms 5_000
  @max_tool_router_timeout_ms 30_000
  # Progress cue threshold (VP-05B / VOICE-11): source-owned hard ceiling.
  @default_progress_threshold_ms 2_000
  @max_progress_threshold_ms 30_000

  @doc "The fixed durable-budget-ledger namespace. Not operator-configurable."
  @spec fixed_budget_namespace() :: :voice_daily_budgets
  def fixed_budget_namespace, do: @budget_namespace

  @doc "Literal default daily voice budget, in milliseconds (60 minutes)."
  @spec default_daily_budget_ms() :: pos_integer()
  def default_daily_budget_ms, do: @default_daily_budget_ms

  @doc "Pure validation: a positive-integer daily budget in milliseconds."
  @spec validate_daily_budget_ms(term()) :: {:ok, pos_integer()} | {:error, :invalid_config}
  def validate_daily_budget_ms(v)
      when is_integer(v) and v > 0 and v <= @max_daily_budget_ms,
      do: {:ok, v}

  def validate_daily_budget_ms(_v), do: {:error, :invalid_config}

  @doc "Validated daily voice budget in milliseconds. Fails closed on a malformed configured value."
  @spec daily_budget_ms() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def daily_budget_ms do
    :arbor_voice
    |> Application.get_env(:daily_budget_ms, @default_daily_budget_ms)
    |> validate_daily_budget_ms()
  end

  @doc "Pure validation: a positive-integer per-session budget no larger than `daily_ms` and the global ceiling."
  @spec validate_session_budget_ms(term(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :invalid_config}
  def validate_session_budget_ms(v, daily_ms)
      when is_integer(v) and is_integer(daily_ms) and v > 0 and v <= daily_ms and
             v <= @max_daily_budget_ms,
      do: {:ok, v}

  def validate_session_budget_ms(_v, _daily_ms), do: {:error, :invalid_config}

  @doc "Validated per-session voice budget in milliseconds; defaults to the daily budget."
  @spec session_budget_ms() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def session_budget_ms do
    with {:ok, daily_ms} <- daily_budget_ms() do
      :arbor_voice
      |> Application.get_env(:session_budget_ms, daily_ms)
      |> validate_session_budget_ms(daily_ms)
    end
  end

  @doc "Pure validation: an atom backend module, or `{:error, :disabled}` for `nil`."
  @spec validate_budget_backend(term()) :: {:ok, module()} | {:error, :disabled | :invalid_config}
  def validate_budget_backend(nil), do: {:error, :disabled}
  def validate_budget_backend(v) when is_atom(v), do: {:ok, v}
  def validate_budget_backend(_v), do: {:error, :invalid_config}

  @doc "Configured budget ledger persistence backend module. `{:error, :disabled}` when unset."
  @spec budget_backend() :: {:ok, module()} | {:error, :disabled | :invalid_config}
  def budget_backend do
    :arbor_voice
    |> Application.get_env(:budget_backend)
    |> validate_budget_backend()
  end

  @doc "Pure validation: must equal the fixed production namespace, exactly."
  @spec validate_budget_namespace(term()) ::
          {:ok, :voice_daily_budgets} | {:error, :invalid_config}
  def validate_budget_namespace(v) when v == @budget_namespace, do: {:ok, @budget_namespace}
  def validate_budget_namespace(_v), do: {:error, :invalid_config}

  @doc """
  Validated budget ledger namespace. Always `:voice_daily_budgets` — an
  operator configuring any other value fails closed rather than being
  silently honored or silently ignored.
  """
  @spec budget_namespace() :: {:ok, :voice_daily_budgets} | {:error, :invalid_config}
  def budget_namespace do
    :arbor_voice
    |> Application.get_env(:budget_namespace, @budget_namespace)
    |> validate_budget_namespace()
  end

  @doc "Pure validation: a keyword list of backend opts without a `:name` key, with bounded count and JSON-clean values."
  @spec validate_budget_backend_opts(term()) :: {:ok, keyword()} | {:error, :invalid_config}
  def validate_budget_backend_opts(v) when is_list(v) do
    if Keyword.keyword?(v) and valid_backend_opts_shape?(v) do
      {:ok, v}
    else
      {:error, :invalid_config}
    end
  end

  def validate_budget_backend_opts(_v), do: {:error, :invalid_config}

  defp valid_backend_opts_shape?(opts) do
    keys = Keyword.keys(opts)

    cond do
      :name in keys -> false
      length(keys) != length(Enum.uniq(keys)) -> false
      length(opts) > @max_backend_opts_count -> false
      not Enum.all?(opts, fn {k, v} -> valid_backend_opt?(k, v) end) -> false
      true -> backend_opts_encoded_size_ok?(opts)
    end
  end

  defp valid_backend_opt?(k, v) when is_atom(k) and not is_nil(k) do
    json_clean_value?(v)
  end

  defp valid_backend_opt?(_k, _v), do: false

  defp json_clean_value?(nil), do: true
  defp json_clean_value?(v) when is_atom(v), do: not is_nil(v)
  defp json_clean_value?(v) when is_binary(v), do: true
  defp json_clean_value?(v) when is_integer(v), do: true
  defp json_clean_value?(v) when is_float(v), do: true
  defp json_clean_value?(v) when is_boolean(v), do: true
  defp json_clean_value?(_v), do: false

  defp backend_opts_encoded_size_ok?(opts) do
    case Jason.encode(Map.new(opts)) do
      {:ok, encoded}
      when is_binary(encoded) and byte_size(encoded) <= @max_backend_opts_encoded_bytes ->
        true

      _ ->
        false
    end
  end

  @doc "Validated backend opts passed through to `Arbor.Persistence` calls."
  @spec budget_backend_opts() :: {:ok, keyword()} | {:error, :invalid_config}
  def budget_backend_opts do
    :arbor_voice
    |> Application.get_env(:budget_backend_opts, [])
    |> validate_budget_backend_opts()
  end

  @doc "Pure validation: a non-negative-integer reservation expiry grace, in milliseconds."
  @spec validate_budget_reservation_grace_ms(term()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_config}
  def validate_budget_reservation_grace_ms(v)
      when is_integer(v) and v >= 0 and v <= @max_budget_reservation_grace_ms,
      do: {:ok, v}

  def validate_budget_reservation_grace_ms(_v), do: {:error, :invalid_config}

  @doc "Validated reservation expiry grace period, in milliseconds."
  @spec budget_reservation_grace_ms() :: {:ok, non_neg_integer()} | {:error, :invalid_config}
  def budget_reservation_grace_ms do
    :arbor_voice
    |> Application.get_env(:budget_reservation_grace_ms, @default_budget_reservation_grace_ms)
    |> validate_budget_reservation_grace_ms()
  end

  @doc "Pure validation: a bounded CAS conflict retry count (0..20)."
  @spec validate_budget_cas_max_retries(term()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_config}
  def validate_budget_cas_max_retries(v)
      when is_integer(v) and v >= 0 and v <= @max_budget_cas_max_retries,
      do: {:ok, v}

  def validate_budget_cas_max_retries(_v), do: {:error, :invalid_config}

  @doc "Validated bounded CAS conflict retry count."
  @spec budget_cas_max_retries() :: {:ok, non_neg_integer()} | {:error, :invalid_config}
  def budget_cas_max_retries do
    :arbor_voice
    |> Application.get_env(:budget_cas_max_retries, @default_budget_cas_max_retries)
    |> validate_budget_cas_max_retries()
  end

  # ---------------------------------------------------------------------------
  # Speech-output acceptance timeout (VP-04E2R1)
  # ---------------------------------------------------------------------------

  @doc "Literal default speech-output acceptance timeout, in milliseconds (100)."
  @spec default_speech_output_timeout_ms() :: pos_integer()
  def default_speech_output_timeout_ms, do: @default_speech_output_timeout_ms

  @doc "Hard ceiling for speech-output acceptance timeout, in milliseconds (250)."
  @spec max_speech_output_timeout_ms() :: pos_integer()
  def max_speech_output_timeout_ms, do: @max_speech_output_timeout_ms

  @doc """
  Pure validation: a positive-integer speech-output acceptance timeout at most
  250 ms. This is a source-owned hard ceiling on the enqueue/acceptance seam,
  not an advisory adapter contract.
  """
  @spec validate_speech_output_timeout_ms(term()) ::
          {:ok, pos_integer()} | {:error, :invalid_config}
  def validate_speech_output_timeout_ms(v)
      when is_integer(v) and v > 0 and v <= @max_speech_output_timeout_ms,
      do: {:ok, v}

  def validate_speech_output_timeout_ms(_v), do: {:error, :invalid_config}

  @doc """
  Validated speech-output acceptance timeout in milliseconds.

  Defaults to 100 ms. A present but malformed Application config value fails
  closed as `{:error, :invalid_config}` rather than silently substituting the
  default.
  """
  @spec speech_output_timeout_ms() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def speech_output_timeout_ms do
    :arbor_voice
    |> Application.get_env(:speech_output_timeout_ms, @default_speech_output_timeout_ms)
    |> validate_speech_output_timeout_ms()
  end

  # ---------------------------------------------------------------------------
  # Tool-router timeout (VP-04E3)
  # ---------------------------------------------------------------------------

  @doc "Literal default tool-router timeout, in milliseconds (5000)."
  @spec default_tool_router_timeout_ms() :: pos_integer()
  def default_tool_router_timeout_ms, do: @default_tool_router_timeout_ms

  @doc "Hard ceiling for tool-router timeout, in milliseconds (30000)."
  @spec max_tool_router_timeout_ms() :: pos_integer()
  def max_tool_router_timeout_ms, do: @max_tool_router_timeout_ms

  @doc """
  Pure validation: a positive-integer tool-router timeout at most 30_000 ms.
  Source-owned hard ceiling; not bypassable via Application env.
  """
  @spec validate_tool_router_timeout_ms(term()) ::
          {:ok, pos_integer()} | {:error, :invalid_config}
  def validate_tool_router_timeout_ms(v)
      when is_integer(v) and v > 0 and v <= @max_tool_router_timeout_ms,
      do: {:ok, v}

  def validate_tool_router_timeout_ms(_v), do: {:error, :invalid_config}

  @doc """
  Validated tool-router timeout in milliseconds.

  Defaults to 5000 ms. A present but malformed Application config value fails
  closed as `{:error, :invalid_config}`.
  """
  @spec tool_router_timeout_ms() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def tool_router_timeout_ms do
    :arbor_voice
    |> Application.get_env(:tool_router_timeout_ms, @default_tool_router_timeout_ms)
    |> validate_tool_router_timeout_ms()
  end

  # ---------------------------------------------------------------------------
  # Progress cue threshold (VP-05B / VOICE-11)
  # ---------------------------------------------------------------------------

  @doc "Literal default progress threshold, in milliseconds (2000)."
  @spec default_progress_threshold_ms() :: pos_integer()
  def default_progress_threshold_ms, do: @default_progress_threshold_ms

  @doc "Hard ceiling for progress threshold, in milliseconds (30000)."
  @spec max_progress_threshold_ms() :: pos_integer()
  def max_progress_threshold_ms, do: @max_progress_threshold_ms

  @doc """
  Pure validation: positive-integer progress threshold at most 30_000 ms and
  not exceeding the effective tool-router timeout.
  """
  @spec validate_progress_threshold_ms(term(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :invalid_config}
  def validate_progress_threshold_ms(v, tool_timeout_ms)
      when is_integer(v) and is_integer(tool_timeout_ms) and v > 0 and
             v <= @max_progress_threshold_ms and v <= tool_timeout_ms,
      do: {:ok, v}

  def validate_progress_threshold_ms(_v, _tool_timeout_ms), do: {:error, :invalid_config}

  @doc """
  Validated progress threshold in milliseconds.

  Defaults to 2000 ms. Requires a validated tool-router timeout so the
  threshold cannot exceed the effective tool timeout. Malformed Application
  config fails closed as `{:error, :invalid_config}`.
  """
  @spec progress_threshold_ms() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def progress_threshold_ms do
    with {:ok, tool_ms} <- tool_router_timeout_ms() do
      :arbor_voice
      |> Application.get_env(:progress_threshold_ms, @default_progress_threshold_ms)
      |> validate_progress_threshold_ms(tool_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # Agent facade collaborator (VP-05B / VOICE-9)
  # ---------------------------------------------------------------------------

  @doc """
  Pure validation: an atom module exporting `send_message/4` (consult path).
  Catch-safe so compiled-but-not-yet-loaded modules are accepted.
  Does not require `dispatch_task/4` — that is validated only when the session
  catalog exposes `dispatch_coding_task` (VP-05C).
  """
  @spec validate_agent_module(term()) :: {:ok, module()} | {:error, :invalid_config}
  def validate_agent_module(mod) when is_atom(mod) and not is_nil(mod) do
    try do
      exports = mod.module_info(:exports)

      if {:send_message, 4} in exports do
        {:ok, mod}
      else
        {:error, :invalid_config}
      end
    rescue
      _ -> {:error, :invalid_config}
    catch
      _kind, _reason -> {:error, :invalid_config}
    end
  end

  def validate_agent_module(_), do: {:error, :invalid_config}

  @doc """
  Pure validation: agent module exporting both `send_message/4` and
  `dispatch_task/4` for catalogs that include `dispatch_coding_task`.
  """
  @spec validate_agent_module_with_dispatch(term()) ::
          {:ok, module()} | {:error, :invalid_config}
  def validate_agent_module_with_dispatch(mod) when is_atom(mod) and not is_nil(mod) do
    try do
      exports = mod.module_info(:exports)

      if {:send_message, 4} in exports and {:dispatch_task, 4} in exports do
        {:ok, mod}
      else
        {:error, :invalid_config}
      end
    rescue
      _ -> {:error, :invalid_config}
    catch
      _kind, _reason -> {:error, :invalid_config}
    end
  end

  def validate_agent_module_with_dispatch(_), do: {:error, :invalid_config}

  @doc """
  Cross-library Agent facade module for consult_agent (and dispatch when the
  catalog requires it).

  Defaults to `Arbor.Agent`. Not a public per-session option — tests may
  replace via Application env (`:agent_module`) in isolated non-async tests
  and must restore. Malformed Application config fails closed as
  `{:error, :invalid_config}`.
  """
  @spec agent_module() :: {:ok, module()} | {:error, :invalid_config}
  def agent_module do
    :arbor_voice
    |> Application.get_env(:agent_module, Arbor.Agent)
    |> validate_agent_module()
  end

  @doc """
  Agent facade when the effective catalog exposes `dispatch_coding_task`.
  Requires both `send_message/4` and `dispatch_task/4`.
  """
  @spec agent_module_with_dispatch() :: {:ok, module()} | {:error, :invalid_config}
  def agent_module_with_dispatch do
    :arbor_voice
    |> Application.get_env(:agent_module, Arbor.Agent)
    |> validate_agent_module_with_dispatch()
  end

  # ---------------------------------------------------------------------------
  # Orchestrator facade collaborator (VP-05C / VOICE-10 partial)
  # ---------------------------------------------------------------------------

  @doc """
  Pure validation: an atom module exporting `coding_repo_roots/0`. Catch-safe.
  """
  @spec validate_orchestrator_module(term()) :: {:ok, module()} | {:error, :invalid_config}
  def validate_orchestrator_module(mod) when is_atom(mod) and not is_nil(mod) do
    try do
      exports = mod.module_info(:exports)

      if {:coding_repo_roots, 0} in exports do
        {:ok, mod}
      else
        {:error, :invalid_config}
      end
    rescue
      _ -> {:error, :invalid_config}
    catch
      _kind, _reason -> {:error, :invalid_config}
    end
  end

  def validate_orchestrator_module(_), do: {:error, :invalid_config}

  @doc """
  Cross-library Orchestrator facade for coding repo root resolution.

  Defaults to `Arbor.Orchestrator`. Not a public per-session option — tests may
  replace via Application env (`:orchestrator_module`) in isolated non-async
  tests and must restore. Malformed Application config fails closed as
  `{:error, :invalid_config}`.
  """
  @spec orchestrator_module() :: {:ok, module()} | {:error, :invalid_config}
  def orchestrator_module do
    :arbor_voice
    |> Application.get_env(:orchestrator_module, Arbor.Orchestrator)
    |> validate_orchestrator_module()
  end

  # ---------------------------------------------------------------------------
  # Realtime egress collaborators (VP-05D2A2P3)
  # ---------------------------------------------------------------------------

  @security_exports [
    authorize: 4,
    authorize_and_issue_delivery_receipt: 4,
    consume_delivery_receipt: 3,
    grant_capability_id: 1,
    issue_disclosure_capability_id: 1,
    revoke: 1,
    uri_registered?: 1,
    validate_disclosure_capability: 3
  ]
  @trust_exports [authorize_egress: 3]
  @ai_exports [egress_tier_for: 2]

  @doc "Source-owned Security facade collaborator for realtime egress authority."
  @spec security_module() :: {:ok, module()} | {:error, :invalid_config}
  def security_module do
    :arbor_voice
    |> Application.get_env(:security_module, Arbor.Security)
    |> validate_facade_module(@security_exports)
  end

  @doc "Source-owned Trust facade collaborator for realtime egress policy."
  @spec trust_module() :: {:ok, module()} | {:error, :invalid_config}
  def trust_module do
    :arbor_voice
    |> Application.get_env(:trust_module, Arbor.Trust)
    |> validate_facade_module(@trust_exports)
  end

  @doc "Source-owned AI facade collaborator for realtime route classification."
  @spec ai_module() :: {:ok, module()} | {:error, :invalid_config}
  def ai_module do
    :arbor_voice
    |> Application.get_env(:ai_module, Arbor.AI)
    |> validate_facade_module(@ai_exports)
  end

  defp validate_facade_module(mod, required_exports)
       when is_atom(mod) and not is_nil(mod) and is_list(required_exports) do
    try do
      exports = mod.module_info(:exports)

      if Enum.all?(required_exports, &(&1 in exports)) do
        {:ok, mod}
      else
        {:error, :invalid_config}
      end
    rescue
      _ -> {:error, :invalid_config}
    catch
      _kind, _reason -> {:error, :invalid_config}
    end
  end

  defp validate_facade_module(_mod, _required_exports), do: {:error, :invalid_config}
end
