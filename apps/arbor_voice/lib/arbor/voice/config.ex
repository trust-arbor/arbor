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
end
