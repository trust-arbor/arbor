defmodule Arbor.Trust.PolicyHost do
  @moduledoc """
  VM-lifetime Trust policy-resolution host.

  Owns the immutable startup snapshot for security ceilings, permissive-baseline
  posture, egress defaults, and capability-profile projection. Public Trust
  policy resolution reads this snapshot only after a live ready handshake.
  """

  use GenServer

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.Config

  @table :arbor_trust_policy_host_claim
  @key :claimed
  @heir_data :arbor_trust_policy_host_claim
  @ready_timeout 5_000
  @modes [:block, :ask, :allow, :auto]
  @start_profiles [:full, :activation_only]
  @required_keys [
    :start_profile,
    :security_ceilings,
    :allow_permissive_baseline,
    :default_egress_modes,
    :capability_profiles,
    :action_profiles_admitted
  ]
  @table_protection if(Mix.env() == :test, do: :public, else: :protected)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, init_args(opts), name: __MODULE__)
  end

  @spec snapshot() :: {:ok, map()} | {:error, :unavailable}
  def snapshot do
    case await_ready() do
      :ok ->
        case fetch_slot() do
          {:ok, snapshot} -> {:ok, snapshot}
          _ -> {:error, :unavailable}
        end

      :error ->
        {:error, :unavailable}
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec start_link_with_snapshot(map()) :: GenServer.on_start()
    def start_link_with_snapshot(snapshot) when is_map(snapshot) do
      GenServer.start_link(__MODULE__, [snapshot: snapshot], name: __MODULE__)
    end

    @doc false
    @spec release_claim() :: :ok
    def release_claim do
      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          try do
            GenServer.stop(pid, :normal)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end

      case :ets.whereis(@table) do
        :undefined ->
          :ok

        tid ->
          try do
            :ets.delete_all_objects(tid)
          rescue
            ArgumentError -> :ok
          end
      end

      :ok
    end

    defp init_args(opts) when is_list(opts) do
      Keyword.take(opts, [:start_profile, :snapshot])
    end
  else
    defp init_args(opts) when is_list(opts) do
      Keyword.take(opts, [:start_profile])
    end
  end

  @impl true
  def init(opts) do
    case bind_or_restore(opts) do
      {:ok, _snapshot} ->
        {:ok, %{}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, state) do
    {:reply, :ok, state}
  end

  defp bind_or_restore(opts) do
    with {:ok, requested} <- requested_start_profile(opts) do
      case fetch_slot() do
        {:ok, snapshot} ->
          with :ok <- match_start_profile(snapshot.start_profile, requested) do
            {:ok, snapshot}
          end

        :absent ->
          first_bind(opts, requested)

        :corrupt ->
          {:error, {:policy_host_claim_failed, :corrupt_slot}}

        {:error, {:policy_host_claim_table_foreign_owner, _owner}} = error ->
          error

        {:error, :policy_host_claim_table_unavailable} = error ->
          error
      end
    end
  end

  defp first_bind(opts, requested) do
    with {:ok, snapshot} <- snapshot_from_opts(opts, requested),
         {:ok, admitted} <- admit_snapshot(snapshot),
         :ok <- match_start_profile(admitted.start_profile, requested) do
      commit_first(admitted)
    end
  end

  defp snapshot_from_opts(opts, requested) do
    case injected_snapshot(opts) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      :none ->
        Config.startup_policy_snapshot(requested)
    end
  end

  defp requested_start_profile(opts) when is_list(opts) do
    case Keyword.fetch(opts, :start_profile) do
      {:ok, profile} when profile in @start_profiles -> {:ok, profile}
      {:ok, other} -> {:error, {:invalid_start_profile, other}}
      :error -> Arbor.Trust.Application.closed_start_profile()
    end
  end

  defp match_start_profile(frozen, requested) when frozen == requested, do: :ok

  defp match_start_profile(frozen, requested) do
    {:error, {:policy_host_profile_mismatch, frozen, requested}}
  end

  if Mix.env() == :test do
    defp injected_snapshot(opts) when is_list(opts) do
      case Keyword.get(opts, :snapshot) do
        snapshot when is_map(snapshot) -> {:ok, snapshot}
        _ -> :none
      end
    end

    defp injected_snapshot(_opts), do: :none
  else
    defp injected_snapshot(_opts), do: :none
  end

  defp commit_first(snapshot) do
    case fetch_slot() do
      {:ok, ^snapshot} ->
        {:ok, snapshot}

      {:ok, _other} ->
        {:error, {:policy_host_claim_failed, :corrupt_slot}}

      :corrupt ->
        {:error, {:policy_host_claim_failed, :corrupt_slot}}

      {:error, _} = error ->
        error

      :absent ->
        create_and_insert(snapshot)
    end
  end

  defp create_and_insert(snapshot) do
    with {:ok, table} <- create_claim_table() do
      case :ets.insert_new(table, {@key, snapshot}) do
        true ->
          case fetch_slot() do
            {:ok, ^snapshot} -> {:ok, snapshot}
            _ -> {:error, {:policy_host_claim_failed, :corrupt_slot}}
          end

        false ->
          {:error, {:policy_host_claim_failed, :corrupt_slot}}
      end
    end
  rescue
    ArgumentError -> {:error, {:policy_host_claim_failed, :corrupt_slot}}
  end

  defp create_claim_table do
    table_opts =
      [:named_table, :set, @table_protection, read_concurrency: true] ++ heir_opts()

    {:ok, :ets.new(@table, table_opts)}
  rescue
    ArgumentError -> accept_existing_table()
  end

  if Mix.env() == :test do
    defp heir_opts do
      _ = @heir_data
      []
    end
  else
    defp heir_opts do
      case init_pid() do
        {:ok, init_pid} -> [{:heir, init_pid, @heir_data}]
        :error -> []
      end
    end
  end

  defp accept_existing_table do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :policy_host_claim_table_unavailable}

      table ->
        case table_owner(table) do
          {:ok, _owner} -> {:ok, table}
          {:error, _} = error -> error
        end
    end
  end

  defp fetch_slot do
    case :ets.whereis(@table) do
      :undefined ->
        :absent

      table ->
        read_validated(table)
    end
  rescue
    ArgumentError -> :corrupt
  end

  defp read_validated(table) do
    case table_owner(table) do
      {:error, _} = error ->
        error

      {:ok, _owner} ->
        case validate_table(table) do
          :ok ->
            case :ets.lookup(table, @key) do
              [{@key, snapshot}] ->
                case admit_snapshot(snapshot) do
                  {:ok, admitted} -> {:ok, admitted}
                  {:error, _} -> :corrupt
                end

              [] ->
                :absent

              _ ->
                :corrupt
            end

          :empty ->
            :absent

          :error ->
            :corrupt
        end
    end
  rescue
    ArgumentError -> :corrupt
  end

  defp table_owner(table) do
    case :ets.info(table, :owner) do
      owner when owner == self() ->
        {:ok, owner}

      owner ->
        binding = Process.whereis(__MODULE__)

        cond do
          is_pid(binding) and owner == binding ->
            {:ok, owner}

          legitimate_heir_owner?(owner) ->
            {:ok, owner}

          is_pid(owner) ->
            {:error, {:policy_host_claim_table_foreign_owner, owner}}

          true ->
            {:error, :policy_host_claim_table_unavailable}
        end
    end
  end

  if Mix.env() == :test do
    defp legitimate_heir_owner?(_owner), do: false
  else
    defp legitimate_heir_owner?(owner) do
      init = Process.whereis(:init)
      is_pid(init) and owner == init
    end
  end

  defp validate_table(table) do
    with {:ok, init_pid} <- init_pid_or_none(),
         true <- :ets.info(table, :name) == @table,
         true <- :ets.info(table, :type) == :set,
         true <- :ets.info(table, :protection) == @table_protection,
         true <- valid_heir?(table, init_pid) do
      case :ets.info(table, :size) do
        0 -> :empty
        1 -> :ok
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  if Mix.env() == :test do
    defp valid_heir?(_table, _init_pid), do: true

    defp init_pid_or_none, do: {:ok, nil}
  else
    defp valid_heir?(table, init_pid) do
      :ets.info(table, :heir) == init_pid
    end

    defp init_pid_or_none, do: init_pid()
  end

  defp init_pid do
    case Process.whereis(:init) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp admit_snapshot(snapshot) when is_map(snapshot) do
    with :ok <- require_keys(snapshot),
         :ok <- admit_start_profile(snapshot.start_profile),
         :ok <- admit_boolean(snapshot.allow_permissive_baseline),
         :ok <- admit_boolean(snapshot.action_profiles_admitted),
         :ok <- admit_mode_map(snapshot.security_ceilings, :binary),
         :ok <- admit_mode_map(snapshot.default_egress_modes, :atom),
         :ok <- admit_profiles(snapshot.capability_profiles) do
      {:ok,
       %{
         start_profile: snapshot.start_profile,
         security_ceilings: snapshot.security_ceilings,
         allow_permissive_baseline: snapshot.allow_permissive_baseline,
         default_egress_modes: snapshot.default_egress_modes,
         capability_profiles: snapshot.capability_profiles,
         action_profiles_admitted: snapshot.action_profiles_admitted
       }}
    else
      _ -> {:error, :malformed_policy_snapshot}
    end
  end

  defp admit_snapshot(_snapshot), do: {:error, :malformed_policy_snapshot}

  defp require_keys(snapshot) do
    if Enum.all?(@required_keys, &Map.has_key?(snapshot, &1)), do: :ok, else: :error
  end

  defp admit_start_profile(profile) when profile in @start_profiles, do: :ok
  defp admit_start_profile(_profile), do: :error

  defp admit_boolean(value) when is_boolean(value), do: :ok
  defp admit_boolean(_value), do: :error

  defp admit_mode_map(map, key_kind) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      if valid_mode_key?(key, key_kind) and value in @modes do
        {:cont, :ok}
      else
        {:halt, :error}
      end
    end)
  end

  defp admit_mode_map(_map, _key_kind), do: :error

  defp valid_mode_key?(key, :binary), do: is_binary(key) and byte_size(key) > 0
  defp valid_mode_key?(key, :atom), do: is_atom(key) and key != nil

  defp admit_profiles(profiles) when is_list(profiles) do
    if Enum.all?(profiles, &match?(%CapabilityProfile{}, &1)), do: :ok, else: :error
  end

  defp admit_profiles(_profiles), do: :error

  defp await_ready do
    try do
      case GenServer.call(__MODULE__, :await_ready, @ready_timeout) do
        :ok -> :ok
        _ -> :error
      end
    catch
      :exit, _ -> :error
    end
  end
end
