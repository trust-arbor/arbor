defmodule Arbor.Kernel.ConfigCompat do
  @moduledoc """
  Temporary migration-only compatibility for four retired app-env owners.

  Closed legacy owners: `:arbor_contracts`, `:arbor_common`, `:arbor_signals`,
  and `:arbor_monitor`. This is not a general `Application` env wrapper and
  is not permanent public configuration infrastructure. A later K2 packet
  will directize remaining reads to `:arbor_kernel` and delete this seam
  after the app-env inventory reaches zero.

  Legacy keyspaces are not disjoint. Indexed source has the same atom
  `:start_children` independently under `:arbor_common`, `:arbor_signals`,
  and `:arbor_monitor`. Kernel storage therefore uses short owner
  namespaces — not the retired app atom and not a flat key:

      config :arbor_kernel, common: [start_children: false]
      config :arbor_kernel, signals: [start_children: false]
      config :arbor_kernel, monitor: [start_children: false]
      config :arbor_kernel, contracts: [some_key: value]

  Runtime `get_env`/`fetch_env`/`fetch_env!` accept only atom keys and read
  that namespace. `compile_env`/`compile_env!` keep the caller's
  atom-or-nonempty-atom-path on the legacy owner, and map it to
  `[namespace | legacy_path]` on the unconditional `:arbor_kernel` compile
  read.
  """

  @legacy_owners [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]
  @kernel_namespaces %{
    arbor_contracts: :contracts,
    arbor_common: :common,
    arbor_signals: :signals,
    arbor_monitor: :monitor
  }
  @unset {:__arbor_kernel_config_compat_unset__, __MODULE__}
  @no_default :__arbor_kernel_config_compat_no_default__

  @type legacy_app :: :arbor_contracts | :arbor_common | :arbor_signals | :arbor_monitor
  @type kernel_namespace :: :contracts | :common | :signals | :monitor
  @type key_or_path :: atom() | [atom(), ...]

  @doc "Closed legacy owners in documented order."
  @spec legacy_owners() :: [legacy_app()]
  def legacy_owners, do: @legacy_owners

  @doc "Collision-safe `:arbor_kernel` namespace for a closed legacy owner."
  @spec kernel_namespace(legacy_app()) :: kernel_namespace()
  def kernel_namespace(legacy_app) when is_map_key(@kernel_namespaces, legacy_app) do
    Map.fetch!(@kernel_namespaces, legacy_app)
  end

  def kernel_namespace(legacy_app) do
    raise ArgumentError, unknown_owner_message(legacy_app)
  end

  @doc """
  Collision-safe `:arbor_kernel` path for a legacy owner and key_or_path.

  An atom key `k` becomes `[namespace, k]`. A nested path becomes
  `[namespace | path]`. Namespaces are `:contracts`, `:common`, `:signals`,
  and `:monitor` — never the retired app atom.
  """
  @spec kernel_path(legacy_app(), key_or_path()) :: [atom(), ...]
  def kernel_path(legacy_app, key) when legacy_app in @legacy_owners and is_atom(key) do
    [kernel_namespace(legacy_app), key]
  end

  def kernel_path(legacy_app, [head | rest])
      when legacy_app in @legacy_owners and is_atom(head) do
    if Enum.all?(rest, &is_atom/1) do
      [kernel_namespace(legacy_app), head | rest]
    else
      raise ArgumentError, invalid_key_or_path_message([head | rest])
    end
  end

  def kernel_path(legacy_app, key_or_path) when legacy_app in @legacy_owners do
    raise ArgumentError, invalid_key_or_path_message(key_or_path)
  end

  def kernel_path(legacy_app, _key_or_path) do
    raise ArgumentError, unknown_owner_message(legacy_app)
  end

  @doc """
  Read a migrated key, using `default` only when neither side is configured.

  Raises `ArgumentError` on an unknown owner, a non-atom key, or a conflict.
  """
  @spec get_env(legacy_app(), atom(), term()) :: term()
  def get_env(legacy_app, key, default \\ nil) do
    case fetch_env(legacy_app, key) do
      {:ok, value} -> value
      :error -> default
      {:error, {:config_conflict, info}} -> raise_conflict!(info)
    end
  end

  @doc """
  Fetch a migrated key without applying a caller default.

  Returns `{:ok, value}`, `:error` when neither side is set, or
  `{:error, {:config_conflict, info}}` when both sides are set and unequal.
  Conflicts compare only the matching owner/key pair.
  """
  @spec fetch_env(legacy_app(), atom()) ::
          {:ok, term()} | :error | {:error, {:config_conflict, map()}}
  def fetch_env(legacy_app, key) when legacy_app in @legacy_owners and is_atom(key) do
    resolve(
      fetch_kernel(legacy_app, key),
      fetch_legacy(legacy_app, key),
      legacy_app,
      key
    )
  end

  def fetch_env(legacy_app, key) when is_atom(key) do
    raise ArgumentError, unknown_owner_message(legacy_app)
  end

  def fetch_env(_legacy_app, key) do
    raise ArgumentError, "ConfigCompat runtime keys must be atoms, got: #{inspect(key)}"
  end

  @doc "Like `fetch_env/2` but raises on missing or conflicting values."
  @spec fetch_env!(legacy_app(), atom()) :: term()
  def fetch_env!(legacy_app, key) do
    case fetch_env(legacy_app, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "could not fetch #{inspect(key)} for #{inspect(legacy_app)} from :arbor_kernel or the legacy owner"

      {:error, {:config_conflict, info}} ->
        raise_conflict!(info)
    end
  end

  @doc """
  Compile-time dual read. Always records both `:arbor_kernel` and the
  legacy owner, then applies the same precedence table as `get_env/3`.

  The legacy `key_or_path` (atom or non-empty atom path) is forwarded
  unchanged to the owner read. The kernel read uses `kernel_path/2` so
  owner-scoped keys such as `:start_children` stay independent.
  """
  defmacro compile_env(legacy_app, key_or_path, default \\ nil) do
    compile_env_quoted(legacy_app, key_or_path, default, __CALLER__)
  end

  @doc "Compile-time dual read that raises when neither side is configured."
  defmacro compile_env!(legacy_app, key_or_path) do
    compile_env_quoted(legacy_app, key_or_path, @no_default, __CALLER__)
  end

  @doc false
  @spec assert_owner_namespace!(legacy_app()) :: :ok
  def assert_owner_namespace!(legacy_app) do
    validate_legacy_owner!(legacy_app)

    case Application.fetch_env(:arbor_kernel, kernel_namespace(legacy_app)) do
      :error ->
        :ok

      {:ok, config} ->
        case owner_namespace_container(config) do
          :ok ->
            :ok

          {:error, reason} ->
            raise ArgumentError, malformed_namespace_message(legacy_app, reason)
        end
    end
  end

  @doc false
  @spec resolve_compile(term(), term(), term(), legacy_app(), key_or_path()) :: term()
  def resolve_compile(kernel, legacy, default, legacy_app, key_or_path) do
    case resolve(normalize_compile(kernel), normalize_compile(legacy), legacy_app, key_or_path) do
      {:ok, value} ->
        value

      :error when default == @no_default ->
        raise ArgumentError,
              "could not fetch #{inspect(key_or_path)} for #{inspect(legacy_app)} from :arbor_kernel or the legacy owner"

      :error ->
        default

      {:error, {:config_conflict, info}} ->
        raise_conflict!(info)
    end
  end

  defp compile_env_quoted(legacy_app, key_or_path, default, caller) do
    owner = Macro.expand(legacy_app, caller)
    key_or_path = Macro.expand(key_or_path, caller)
    validate_legacy_owner!(owner)
    validate_key_or_path!(key_or_path)
    kernel_path = quoted_kernel_path(owner, key_or_path)

    quote do
      Arbor.Kernel.ConfigCompat.resolve_compile(
        (
          Arbor.Kernel.ConfigCompat.assert_owner_namespace!(unquote(owner))
          Application.compile_env(:arbor_kernel, unquote(kernel_path), unquote(@unset))
        ),
        Application.compile_env(unquote(owner), unquote(key_or_path), unquote(@unset)),
        unquote(default),
        unquote(owner),
        unquote(key_or_path)
      )
    end
  end

  defp quoted_kernel_path(owner, key) when is_atom(owner) and is_atom(key) do
    [kernel_namespace(owner), key]
  end

  defp quoted_kernel_path(owner, [head | rest] = path) when is_atom(owner) and is_atom(head) do
    if Enum.all?(rest, &is_atom/1) do
      [kernel_namespace(owner), head | rest]
    else
      raise ArgumentError, invalid_key_or_path_message(path)
    end
  end

  defp quoted_kernel_path(owner, key_or_path) when is_atom(owner) do
    quote do
      Arbor.Kernel.ConfigCompat.kernel_path(unquote(owner), unquote(key_or_path))
    end
  end

  defp validate_legacy_owner!(owner) when owner in @legacy_owners, do: :ok

  defp validate_legacy_owner!(owner) do
    raise ArgumentError, unknown_owner_message(owner)
  end

  defp validate_key_or_path!(key) when is_atom(key), do: :ok

  defp validate_key_or_path!([head | rest]) when is_atom(head) do
    if Enum.all?(rest, &is_atom/1) do
      :ok
    else
      raise ArgumentError, invalid_key_or_path_message([head | rest])
    end
  end

  defp validate_key_or_path!(path) when is_list(path) do
    raise ArgumentError, invalid_key_or_path_message(path)
  end

  # Preserve quoted expressions for the caller's compile-time expansion. A
  # literal tuple is represented by the `:{}` form and remains invalid.
  defp validate_key_or_path!({form, meta, args})
       when form != :{} and is_list(meta) and (is_atom(form) or is_tuple(form)) and
              (is_list(args) or is_atom(args)),
       do: :ok

  defp validate_key_or_path!(other)
       when is_binary(other) or is_number(other) or is_boolean(other) or is_nil(other) or
              is_map(other) or is_tuple(other) or is_pid(other) or is_port(other) or
              is_reference(other) or is_function(other) do
    raise ArgumentError, invalid_key_or_path_message(other)
  end

  # Non-literal quoted values are validated later via kernel_path/2.
  defp validate_key_or_path!(_key_or_path), do: :ok

  defp fetch_kernel(legacy_app, key) do
    case Application.fetch_env(:arbor_kernel, kernel_namespace(legacy_app)) do
      {:ok, config} -> fetch_owner_key(config, key, legacy_app)
      :error -> :error
    end
  end

  defp fetch_owner_key(config, key, legacy_app) do
    case owner_namespace_container(config) do
      :ok ->
        fetch_container_key(config, key)

      {:error, reason} ->
        raise ArgumentError, malformed_namespace_message(legacy_app, reason)
    end
  end

  defp fetch_container_key(config, key) when is_list(config) do
    if Keyword.has_key?(config, key) do
      {:ok, Keyword.fetch!(config, key)}
    else
      :error
    end
  end

  defp fetch_container_key(config, key) when is_map(config), do: Map.fetch(config, key)

  defp owner_namespace_container(config) when is_list(config) do
    if Keyword.keyword?(config), do: :ok, else: {:error, :not_keyword_or_map}
  end

  defp owner_namespace_container(%{__struct__: _}), do: {:error, :not_keyword_or_map}
  defp owner_namespace_container(config) when is_map(config), do: :ok
  defp owner_namespace_container(nil), do: {:error, :nil_namespace}
  defp owner_namespace_container(_), do: {:error, :not_keyword_or_map}

  defp fetch_legacy(:arbor_contracts, key), do: Application.fetch_env(:arbor_contracts, key)
  defp fetch_legacy(:arbor_common, key), do: Application.fetch_env(:arbor_common, key)
  defp fetch_legacy(:arbor_signals, key), do: Application.fetch_env(:arbor_signals, key)
  defp fetch_legacy(:arbor_monitor, key), do: Application.fetch_env(:arbor_monitor, key)

  defp resolve({:ok, value}, {:ok, value}, _app, _key), do: {:ok, value}

  defp resolve({:ok, kernel}, {:ok, legacy}, app, key) do
    {:error, {:config_conflict, %{legacy_app: app, key: key, kernel: kernel, legacy: legacy}}}
  end

  defp resolve({:ok, value}, :error, _app, _key), do: {:ok, value}
  defp resolve(:error, {:ok, value}, _app, _key), do: {:ok, value}
  defp resolve(:error, :error, _app, _key), do: :error

  defp normalize_compile(@unset), do: :error
  defp normalize_compile(value), do: {:ok, value}

  defp raise_conflict!(info) do
    raise ArgumentError, """
    Arbor.Kernel.ConfigCompat conflict for #{inspect(info.legacy_app)} #{inspect(info.key)}: \
    kernel=#{inspect(info.kernel)} legacy=#{inspect(info.legacy)}. \
    Temporary migration policy rejects unequal dual values.
    """
  end

  defp unknown_owner_message(owner) do
    "ConfigCompat accepts only #{inspect(@legacy_owners)}, got: #{inspect(owner)}"
  end

  defp invalid_key_or_path_message(path) do
    "compile_env key_or_path must be an atom or a non-empty atom path, got: #{inspect(path)}"
  end

  defp malformed_namespace_message(owner, reason) do
    "ConfigCompat malformed :arbor_kernel namespace for #{inspect(owner)} (#{inspect(reason)})"
  end
end
