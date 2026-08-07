defmodule Arbor.Memory.Config do
  @moduledoc false

  @app :arbor_memory
  @target_keys MapSet.new([:name, :backend, :opts, "name", "backend", "opts"])
  @default_maintenance_archive_target %{
    name: :memory_events,
    backend: Arbor.Persistence.EventLog.ETS,
    opts: []
  }

  # VP-05D2C3I1A — mutation admission (fixed namespace; not operator-relocatable)
  @mutation_admission_namespace :memory_mutation_admission
  @max_backend_opts_count 32
  @max_backend_opts_encoded_bytes 4096
  @default_max_agent_id_bytes 256
  @default_max_active_roots 64
  @default_max_nested_depth 32
  @default_max_drain_waiters 16
  @default_cas_max_retries 8
  @max_cas_max_retries 32
  @default_cas_backoff_base_ms 2
  @max_cas_backoff_base_ms 50
  @default_drain_timeout_ms 5_000
  @max_drain_timeout_ms 60_000

  @type event_log_target :: %{name: atom(), backend: module(), opts: keyword()}

  @type mutation_admission_target :: %{
          namespace: :memory_mutation_admission,
          backend: module(),
          opts: keyword()
        }

  @spec maintenance_archive_target() ::
          {:ok, event_log_target()} | {:error, :invalid_event_log_target}
  def maintenance_archive_target do
    @app
    |> Application.get_env(:maintenance_archive_target, @default_maintenance_archive_target)
    |> normalize_event_log_target()
  end

  # ---------------------------------------------------------------------------
  # Mutation admission (VP-05D2C3I1A)
  # ---------------------------------------------------------------------------

  @doc "Fixed durable namespace for mutation admission records."
  @spec fixed_mutation_admission_namespace() :: :memory_mutation_admission
  def fixed_mutation_admission_namespace, do: @mutation_admission_namespace

  @spec mutation_admission_namespace() ::
          {:ok, :memory_mutation_admission} | {:error, :invalid_config}
  def mutation_admission_namespace do
    case Application.get_env(@app, :mutation_admission_namespace, @mutation_admission_namespace) do
      @mutation_admission_namespace -> {:ok, @mutation_admission_namespace}
      _ -> {:error, :invalid_config}
    end
  end

  @spec validate_mutation_admission_backend(term()) ::
          {:ok, module()} | {:error, :disabled | :invalid_config}
  def validate_mutation_admission_backend(nil), do: {:error, :disabled}
  def validate_mutation_admission_backend(v) when is_atom(v) and not is_nil(v), do: {:ok, v}
  def validate_mutation_admission_backend(_), do: {:error, :invalid_config}

  @spec mutation_admission_backend() :: {:ok, module()} | {:error, :disabled | :invalid_config}
  def mutation_admission_backend do
    @app
    |> Application.get_env(:mutation_admission_backend)
    |> validate_mutation_admission_backend()
  end

  @spec validate_mutation_admission_backend_opts(term()) ::
          {:ok, keyword()} | {:error, :invalid_config}
  def validate_mutation_admission_backend_opts(v) when is_list(v) do
    if Keyword.keyword?(v) and valid_backend_opts_shape?(v),
      do: {:ok, v},
      else: {:error, :invalid_config}
  end

  def validate_mutation_admission_backend_opts(_), do: {:error, :invalid_config}

  @spec mutation_admission_backend_opts() :: {:ok, keyword()} | {:error, :invalid_config}
  def mutation_admission_backend_opts do
    @app
    |> Application.get_env(:mutation_admission_backend_opts, [])
    |> validate_mutation_admission_backend_opts()
  end

  @spec mutation_admission_target() ::
          {:ok, mutation_admission_target()} | {:error, :disabled | :invalid_config}
  def mutation_admission_target do
    with {:ok, namespace} <- mutation_admission_namespace(),
         {:ok, backend} <- mutation_admission_backend(),
         {:ok, opts} <- mutation_admission_backend_opts() do
      {:ok, %{namespace: namespace, backend: backend, opts: opts}}
    end
  end

  @spec mutation_admission_max_agent_id_bytes() :: pos_integer()
  def mutation_admission_max_agent_id_bytes, do: @default_max_agent_id_bytes

  @spec mutation_admission_max_active_roots() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def mutation_admission_max_active_roots do
    case Application.get_env(
           @app,
           :mutation_admission_max_active_roots,
           @default_max_active_roots
         ) do
      n when is_integer(n) and n > 0 and n <= 256 -> {:ok, n}
      _ -> {:error, :invalid_config}
    end
  end

  @spec mutation_admission_max_nested_depth() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def mutation_admission_max_nested_depth do
    case Application.get_env(
           @app,
           :mutation_admission_max_nested_depth,
           @default_max_nested_depth
         ) do
      n when is_integer(n) and n > 0 and n <= 64 -> {:ok, n}
      _ -> {:error, :invalid_config}
    end
  end

  @spec mutation_admission_max_drain_waiters() :: {:ok, pos_integer()} | {:error, :invalid_config}
  def mutation_admission_max_drain_waiters do
    case Application.get_env(
           @app,
           :mutation_admission_max_drain_waiters,
           @default_max_drain_waiters
         ) do
      n when is_integer(n) and n > 0 and n <= 64 -> {:ok, n}
      _ -> {:error, :invalid_config}
    end
  end

  @spec mutation_admission_cas_max_retries() ::
          {:ok, non_neg_integer()} | {:error, :invalid_config}
  def mutation_admission_cas_max_retries do
    case Application.get_env(@app, :mutation_admission_cas_max_retries, @default_cas_max_retries) do
      n when is_integer(n) and n >= 0 and n <= @max_cas_max_retries -> {:ok, n}
      _ -> {:error, :invalid_config}
    end
  end

  @spec mutation_admission_cas_backoff_base_ms() ::
          {:ok, non_neg_integer()} | {:error, :invalid_config}
  def mutation_admission_cas_backoff_base_ms do
    case Application.get_env(
           @app,
           :mutation_admission_cas_backoff_base_ms,
           @default_cas_backoff_base_ms
         ) do
      n when is_integer(n) and n >= 0 and n <= @max_cas_backoff_base_ms -> {:ok, n}
      _ -> {:error, :invalid_config}
    end
  end

  @spec mutation_admission_drain_default_timeout_ms() :: pos_integer()
  def mutation_admission_drain_default_timeout_ms do
    case Application.get_env(
           @app,
           :mutation_admission_drain_default_timeout_ms,
           @default_drain_timeout_ms
         ) do
      n when is_integer(n) and n > 0 and n <= @max_drain_timeout_ms -> n
      _ -> @default_drain_timeout_ms
    end
  end

  @doc "Hard ceiling for drain `:timeout_ms` (finding 2/7)."
  @spec mutation_admission_max_drain_timeout_ms() :: pos_integer()
  def mutation_admission_max_drain_timeout_ms, do: @max_drain_timeout_ms

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

  defp valid_backend_opt?(k, v) when is_atom(k) and not is_nil(k), do: json_clean_value?(v)
  defp valid_backend_opt?(_, _), do: false

  defp json_clean_value?(nil), do: true
  defp json_clean_value?(v) when is_atom(v), do: not is_nil(v)
  defp json_clean_value?(v) when is_binary(v), do: true
  defp json_clean_value?(v) when is_integer(v), do: true
  defp json_clean_value?(v) when is_float(v), do: true
  defp json_clean_value?(v) when is_boolean(v), do: true
  defp json_clean_value?(_), do: false

  defp backend_opts_encoded_size_ok?(opts) do
    case Jason.encode(Map.new(opts)) do
      {:ok, encoded}
      when is_binary(encoded) and byte_size(encoded) <= @max_backend_opts_encoded_bytes ->
        true

      _ ->
        false
    end
  end

  @spec normalize_event_log_target(term()) ::
          {:ok, event_log_target()} | {:error, :invalid_event_log_target}
  def normalize_event_log_target(target) when is_list(target) do
    if closed_keyword?(target) do
      target
      |> Map.new()
      |> normalize_event_log_target()
    else
      {:error, :invalid_event_log_target}
    end
  end

  def normalize_event_log_target(target) when is_map(target) and not is_struct(target) do
    with :ok <- ensure_closed_keys(target),
         {:ok, name} <- fetch_field(target, :name),
         {:ok, backend} <- fetch_field(target, :backend),
         {:ok, opts} <- fetch_opts(target),
         true <- is_atom(name) and not is_nil(name),
         true <- is_atom(backend) and not is_nil(backend),
         true <- closed_keyword?(opts) do
      {:ok, %{name: name, backend: backend, opts: opts}}
    else
      _ -> {:error, :invalid_event_log_target}
    end
  end

  def normalize_event_log_target(_target), do: {:error, :invalid_event_log_target}

  defp ensure_closed_keys(target) do
    if Enum.all?(Map.keys(target), &MapSet.member?(@target_keys, &1)), do: :ok, else: :error
  end

  defp fetch_field(target, atom_key) do
    string_key = Atom.to_string(atom_key)

    case {Map.fetch(target, atom_key), Map.fetch(target, string_key)} do
      {{:ok, _atom_value}, {:ok, _string_value}} -> :error
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
    end
  end

  defp fetch_opts(target) do
    case fetch_field(target, :opts) do
      {:ok, opts} -> {:ok, opts}
      :error -> {:ok, []}
    end
  end

  defp closed_keyword?(list) when is_list(list) do
    with true <- length(list) <= 64,
         true <- Enum.all?(list, &match?({key, _value} when is_atom(key), &1)) do
      keys = Enum.map(list, &elem(&1, 0))
      length(keys) == MapSet.size(MapSet.new(keys))
    else
      _ -> false
    end
  end

  defp closed_keyword?(_list), do: false
end
