defmodule Arbor.Agent.Orchestration.TaskControlLease do
  @moduledoc false
  # Pure value module for the closed six-member task-control lease and
  # capability-ID-free recovery markers. No Security I/O, process messages, or
  # side effects. Orchestration owns grant/revoke shells; TaskStore owns
  # reservation, recovery workers, and lifecycle phase application.
  #
  # Closed lease shape (map_size == 3, exact outer keys only):
  #   %{"schema_version" => pos_integer(),
  #     "task_id" => String.t(),
  #     "capabilities" => %{
  #       "task_read" => id, "approval_read" => id, "task_steer" => id,
  #       "task_cancel" => id, "task_adopt" => id, "approval_answer" => id
  #     }}
  #
  # Closed recovery marker v1 (map_size == 3, no capability ids):
  #   %{"schema_version" => 1, "task_id" => task_id, "created_at" => iso8601}
  #
  # Closed recovery marker v2 (map_size == 8, no capability ids):
  #   schema_version=2, task_id, created_at, agent_id, executor_kind, run_id,
  #   control_principal_id, cleanup (closed caller_id/principal_id[/trace_id])

  @schema_version 1
  @marker_schema_version 1
  @marker_schema_version_v2 2
  @max_task_id_bytes 256
  @task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @active_ttl_seconds 86_400
  @long_ttl_seconds 30 * 86_400
  @token_bytes 32

  @kinds [
    :task_read,
    :approval_read,
    :task_steer,
    :task_cancel,
    :task_adopt,
    :approval_answer
  ]

  # Least-risk-first; approval_answer always last.
  @grant_order [
    :task_read,
    :approval_read,
    :task_steer,
    :task_cancel,
    :task_adopt,
    :approval_answer
  ]

  @kind_strings Enum.map(@kinds, &Atom.to_string/1)
  @lease_outer_keys MapSet.new(["schema_version", "task_id", "capabilities"])
  @marker_outer_keys MapSet.new(["schema_version", "task_id", "created_at"])
  @marker_v2_outer_keys MapSet.new([
                          "schema_version",
                          "task_id",
                          "created_at",
                          "agent_id",
                          "executor_kind",
                          "run_id",
                          "control_principal_id",
                          "cleanup"
                        ])
  @cleanup_required_keys MapSet.new(["caller_id", "principal_id"])
  @cleanup_optional_keys MapSet.new(["trace_id"])
  @max_executor_kind_bytes 64
  @max_principal_bytes 256
  @executor_kind_pattern ~r/\A[A-Za-z][A-Za-z0-9_]*\z/

  @type kind ::
          :task_read
          | :approval_read
          | :task_steer
          | :task_cancel
          | :task_adopt
          | :approval_answer

  @type kind_string :: String.t()

  @type phase ::
          :terminal_revoke_set_keep_adopt
          | :terminal_revoke_set
          | :after_adoption
          | :all

  # Elixir typespecs cannot express literal binary map keys (Elixir 1.19
  # rejects them). These types use String.t() keys intentionally. Exact key
  # closure (six capability keys / three outer lease keys / three marker keys,
  # map_size checks) is enforced at runtime by normalize_for_task/2,
  # marker_normalize/1, and tests — not by the typespec.
  @type capabilities :: %{
          String.t() => String.t()
        }

  @type lease :: %{
          String.t() =>
            pos_integer()
            | String.t()
            | capabilities()
        }

  @type marker :: %{
          String.t() => pos_integer() | String.t()
        }

  # Runtime-closed key sets (typespec cannot name literal binary keys):
  # capabilities: "task_read"|"approval_read"|"task_steer"|"task_cancel"|
  #               "task_adopt"|"approval_answer" (map_size==6)
  # lease: "schema_version"|"task_id"|"capabilities" (map_size==3)
  # marker v1: "schema_version"|"task_id"|"created_at" (map_size==3)
  # marker v2: v1 keys plus agent_id, executor_kind, run_id,
  #            control_principal_id, cleanup (map_size==8)

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec kind_strings() :: [String.t()]
  def kind_strings, do: @kind_strings

  @spec grant_order() :: [kind()]
  def grant_order, do: @grant_order

  @spec ttl_class(kind()) :: :active | :long
  def ttl_class(:task_read), do: :long
  def ttl_class(:task_adopt), do: :long
  def ttl_class(kind) when kind in @kinds, do: :active

  @spec ttl_seconds(kind()) :: pos_integer()
  def ttl_seconds(kind) do
    case ttl_class(kind) do
      :long -> @long_ttl_seconds
      :active -> @active_ttl_seconds
    end
  end

  @spec valid_task_id?(term()) :: boolean()
  def valid_task_id?(id)
      when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_task_id_bytes do
    String.valid?(id) and Regex.match?(@task_id_pattern, id)
  end

  def valid_task_id?(_), do: false

  @spec uri(kind(), String.t()) :: {:ok, String.t()} | {:error, :invalid_task_id | :invalid_kind}
  def uri(kind, task_id) when kind in @kinds do
    if valid_task_id?(task_id) do
      {:ok, do_uri(kind, task_id)}
    else
      {:error, :invalid_task_id}
    end
  end

  def uri(_kind, _task_id), do: {:error, :invalid_kind}

  @spec grant_spec(kind(), String.t(), String.t(), DateTime.t()) ::
          {:ok, keyword()} | {:error, term()}
  def grant_spec(kind, principal, task_id, %DateTime{} = now)
      when kind in @kinds and is_binary(principal) and principal != "" do
    with {:ok, resource} <- uri(kind, task_id) do
      {:ok,
       [
         principal: principal,
         resource: resource,
         task_id: task_id,
         delegation_depth: 0,
         constraints: %{},
         expires_at: DateTime.add(now, ttl_seconds(kind), :second),
         metadata: %{
           source: :orchestration_task_dispatch,
           task_id: task_id,
           kind: Atom.to_string(kind)
         }
       ]}
    end
  end

  def grant_spec(_kind, _principal, _task_id, _now), do: {:error, :invalid_grant_spec}

  @spec new(String.t(), %{kind() => String.t()} | %{String.t() => String.t()}) ::
          {:ok, lease()} | {:error, term()}
  def new(task_id, kind_to_id) when is_map(kind_to_id) do
    if not valid_task_id?(task_id) do
      {:error, :invalid_task_id}
    else
      with {:ok, capabilities} <- normalize_capability_map(kind_to_id) do
        {:ok,
         %{
           "schema_version" => @schema_version,
           "task_id" => task_id,
           "capabilities" => capabilities
         }}
      end
    end
  end

  def new(_task_id, _kind_to_id), do: {:error, :invalid_lease}

  @spec normalize(term()) :: {:ok, lease()} | {:error, term()}
  def normalize(lease), do: normalize_for_task(lease, :any)

  @doc """
  Normalize a lease and optionally require its embedded task_id to equal
  `expected_task_id` (binary) or accept any valid id (`:any`).

  Enforces the closed three-key outer shape and six-key capabilities map.
  """
  @spec normalize_for_task(term(), String.t() | :any) :: {:ok, lease()} | {:error, term()}
  def normalize_for_task(
        %{
          "schema_version" => @schema_version,
          "task_id" => task_id,
          "capabilities" => capabilities
        } = lease,
        expected_task_id
      )
      when is_binary(task_id) and is_map(capabilities) and map_size(lease) == 3 do
    cond do
      not closed_lease_outer_keys?(lease) ->
        {:error, :invalid_lease}

      not valid_task_id?(task_id) ->
        {:error, :invalid_task_id}

      is_binary(expected_task_id) and task_id != expected_task_id ->
        {:error, :task_control_lease_task_id_mismatch}

      true ->
        case normalize_capability_map(capabilities) do
          {:ok, caps} ->
            {:ok,
             %{
               "schema_version" => @schema_version,
               "task_id" => task_id,
               "capabilities" => caps
             }}

          {:error, _} = error ->
            error
        end
    end
  end

  def normalize_for_task(_lease, _expected_task_id), do: {:error, :invalid_lease}

  @spec lifecycle_kinds(phase()) :: [kind()]
  def lifecycle_kinds(:terminal_revoke_set_keep_adopt) do
    [:approval_read, :approval_answer, :task_steer, :task_cancel]
  end

  def lifecycle_kinds(:terminal_revoke_set) do
    [:approval_read, :approval_answer, :task_steer, :task_cancel, :task_adopt]
  end

  def lifecycle_kinds(:after_adoption), do: [:task_adopt]
  def lifecycle_kinds(:all), do: @kinds
  def lifecycle_kinds(_), do: []

  @spec kinds_and_ids_for_phase(lease(), phase()) :: [{kind(), String.t()}]
  def kinds_and_ids_for_phase(%{"capabilities" => caps}, phase) when is_map(caps) do
    phase
    |> lifecycle_kinds()
    |> Enum.flat_map(fn kind ->
      case Map.get(caps, Atom.to_string(kind)) do
        id when is_binary(id) and id != "" -> [{kind, id}]
        _ -> []
      end
    end)
  end

  def kinds_and_ids_for_phase(_, _), do: []

  @spec drop_kinds(lease(), [kind()]) :: lease()
  def drop_kinds(%{"capabilities" => caps} = lease, kinds) when is_list(kinds) and is_map(caps) do
    next =
      Enum.reduce(kinds, caps, fn kind, acc ->
        Map.delete(acc, Atom.to_string(kind))
      end)

    %{lease | "capabilities" => next}
  end

  def drop_kinds(lease, _kinds), do: lease

  @spec empty?(lease()) :: boolean()
  def empty?(%{"capabilities" => caps}) when is_map(caps), do: map_size(caps) == 0
  def empty?(_), do: true

  # ---------------------------------------------------------------------------
  # Recovery marker (capability-ID-free)
  # ---------------------------------------------------------------------------

  @spec marker_new(String.t(), DateTime.t()) :: {:ok, marker()} | {:error, term()}
  def marker_new(task_id, %DateTime{} = now) do
    if valid_task_id?(task_id) do
      {:ok,
       %{
         "schema_version" => @marker_schema_version,
         "task_id" => task_id,
         "created_at" => DateTime.to_iso8601(now)
       }}
    else
      {:error, :invalid_task_id}
    end
  end

  def marker_new(_task_id, _now), do: {:error, :invalid_marker}

  @spec marker_new(String.t(), DateTime.t(), map()) :: {:ok, marker()} | {:error, term()}
  def marker_new(task_id, %DateTime{} = now, attrs) when is_map(attrs) do
    with {:ok, agent_id} <- required_principal(attrs, :agent_id),
         {:ok, executor_kind} <- required_executor_kind(attrs),
         {:ok, run_id} <- required_run_id(attrs, task_id),
         {:ok, control_principal_id} <- required_principal(attrs, :control_principal_id),
         {:ok, cleanup} <- normalize_cleanup(attrs, agent_id, control_principal_id) do
      if valid_task_id?(task_id) do
        {:ok,
         %{
           "schema_version" => @marker_schema_version_v2,
           "task_id" => task_id,
           "created_at" => DateTime.to_iso8601(now),
           "agent_id" => agent_id,
           "executor_kind" => executor_kind,
           "run_id" => run_id,
           "control_principal_id" => control_principal_id,
           "cleanup" => cleanup
         }}
      else
        {:error, :invalid_task_id}
      end
    end
  end

  def marker_new(_task_id, _now, _attrs), do: {:error, :invalid_marker}

  @spec marker_normalize(term()) :: {:ok, marker()} | {:error, term()}
  def marker_normalize(
        %{
          "schema_version" => @marker_schema_version,
          "task_id" => task_id,
          "created_at" => created_at
        } = marker
      )
      when is_binary(task_id) and is_binary(created_at) and map_size(marker) == 3 do
    cond do
      not closed_marker_outer_keys?(marker) ->
        {:error, :invalid_marker}

      not valid_task_id?(task_id) ->
        {:error, :invalid_task_id}

      not String.valid?(created_at) or byte_size(created_at) > 64 ->
        {:error, :invalid_marker}

      true ->
        {:ok,
         %{
           "schema_version" => @marker_schema_version,
           "task_id" => task_id,
           "created_at" => created_at
         }}
    end
  end

  def marker_normalize(
        %{
          "schema_version" => @marker_schema_version_v2,
          "task_id" => task_id,
          "created_at" => created_at,
          "agent_id" => agent_id,
          "executor_kind" => executor_kind,
          "run_id" => run_id,
          "control_principal_id" => control_principal_id,
          "cleanup" => cleanup
        } = marker
      )
      when is_binary(task_id) and is_binary(created_at) and is_binary(agent_id) and
             is_binary(executor_kind) and is_binary(run_id) and is_binary(control_principal_id) and
             is_map(cleanup) and map_size(marker) == 8 do
    cond do
      not closed_marker_v2_outer_keys?(marker) ->
        {:error, :invalid_marker}

      not valid_task_id?(task_id) ->
        {:error, :invalid_task_id}

      not valid_principal_id?(agent_id) ->
        {:error, :invalid_marker}

      not valid_principal_id?(control_principal_id) ->
        {:error, :invalid_marker}

      not valid_executor_kind?(executor_kind) ->
        {:error, :invalid_marker}

      run_id != task_id or not valid_task_id?(run_id) ->
        {:error, :invalid_marker}

      not String.valid?(created_at) or byte_size(created_at) > 64 ->
        {:error, :invalid_marker}

      true ->
        case normalize_cleanup_map(cleanup, agent_id, control_principal_id) do
          {:ok, closed_cleanup} ->
            {:ok,
             %{
               "schema_version" => @marker_schema_version_v2,
               "task_id" => task_id,
               "created_at" => created_at,
               "agent_id" => agent_id,
               "executor_kind" => executor_kind,
               "run_id" => run_id,
               "control_principal_id" => control_principal_id,
               "cleanup" => closed_cleanup
             }}

          {:error, _} = error ->
            error
        end
    end
  end

  def marker_normalize(_), do: {:error, :invalid_marker}

  @spec recoverable_v2?(term()) :: boolean()
  def recoverable_v2?(%{"schema_version" => @marker_schema_version_v2} = marker)
      when is_map(marker) and map_size(marker) == 8,
      do: match?({:ok, _}, marker_normalize(marker))

  def recoverable_v2?(_), do: false

  @spec from_listed_capabilities(String.t(), list()) :: {:ok, lease() | nil} | {:error, term()}
  def from_listed_capabilities(task_id, caps) when is_binary(task_id) and is_list(caps) do
    if not valid_task_id?(task_id) do
      {:error, :invalid_task_id}
    else
      reduced =
        Enum.reduce_while(caps, {:ok, %{}}, fn cap, {:ok, acc} ->
          case listed_capability_kind_and_id(cap, task_id) do
            {:ok, kind, id} ->
              case Map.get(acc, kind) do
                nil ->
                  {:cont, {:ok, Map.put(acc, kind, id)}}

                ^id ->
                  {:cont, {:ok, acc}}

                _other ->
                  {:halt, {:error, :duplicate_capability_conflict}}
              end

            :error ->
              {:cont, {:ok, acc}}
          end
        end)

      case reduced do
        {:error, _} = error ->
          error

        {:ok, kind_to_id} when kind_to_id == %{} ->
          {:ok, nil}

        {:ok, kind_to_id} ->
          capabilities =
            Map.new(kind_to_id, fn {kind, id} -> {Atom.to_string(kind), id} end)

          {:ok,
           %{
             "schema_version" => @schema_version,
             "task_id" => task_id,
             "capabilities" => capabilities
           }}
      end
    end
  end

  def from_listed_capabilities(_task_id, _caps), do: {:error, :invalid_lease}

  @spec marker_key(String.t()) :: String.t()
  def marker_key(task_id) when is_binary(task_id), do: task_id

  @spec retain_marker?(boolean(), non_neg_integer(), boolean()) :: boolean()
  def retain_marker?(active_lease_present?, pending_member_count, recovery_pending?)
      when is_boolean(active_lease_present?) and is_integer(pending_member_count) and
             pending_member_count >= 0 and is_boolean(recovery_pending?) do
    active_lease_present? or pending_member_count > 0 or recovery_pending?
  end

  def retain_marker?(_, _, _), do: true

  # ---------------------------------------------------------------------------
  # Reservation token helpers (pure)
  # ---------------------------------------------------------------------------

  @spec generate_reservation_token() :: String.t()
  def generate_reservation_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec token_hash(String.t()) :: binary()
  def token_hash(token) when is_binary(token) and token != "" do
    :crypto.hash(:sha256, token)
  end

  @spec token_match?(binary(), String.t()) :: boolean()
  def token_match?(stored_hash, token)
      when is_binary(stored_hash) and is_binary(token) and token != "" do
    expected = token_hash(token)

    byte_size(stored_hash) == byte_size(expected) and
      :crypto.hash_equals(stored_hash, expected)
  end

  def token_match?(_, _), do: false

  @spec valid_reservation_token?(term()) :: boolean()
  def valid_reservation_token?(token)
      when is_binary(token) and byte_size(token) >= 16 and byte_size(token) <= 128 do
    String.valid?(token) and not String.match?(token, ~r/[\x00-\x1F\x7F]/)
  end

  def valid_reservation_token?(_), do: false

  # ---------------------------------------------------------------------------
  # Capacity (pure decision)
  # ---------------------------------------------------------------------------

  @spec admit_reservation?(non_neg_integer(), pos_integer()) ::
          :ok | {:error, :recovery_capacity_exhausted}
  def admit_reservation?(obligation_count, max_obligations)
      when is_integer(obligation_count) and obligation_count >= 0 and
             is_integer(max_obligations) and max_obligations > 0 do
    if obligation_count >= max_obligations do
      {:error, :recovery_capacity_exhausted}
    else
      :ok
    end
  end

  def admit_reservation?(_, _), do: {:error, :recovery_capacity_exhausted}

  defp do_uri(:task_read, task_id), do: "arbor://agent/task/read/#{task_id}"
  defp do_uri(:approval_read, task_id), do: "arbor://approval/read/task/#{task_id}"
  defp do_uri(:task_steer, task_id), do: "arbor://agent/task/steer/#{task_id}"
  defp do_uri(:task_cancel, task_id), do: "arbor://agent/task/cancel/#{task_id}"
  defp do_uri(:task_adopt, task_id), do: "arbor://agent/task/adopt/#{task_id}"
  defp do_uri(:approval_answer, task_id), do: "arbor://approval/answer/task/#{task_id}"

  @max_capability_id_bytes 256

  defp closed_lease_outer_keys?(lease) when is_map(lease) do
    MapSet.equal?(MapSet.new(Map.keys(lease)), @lease_outer_keys)
  end

  defp closed_lease_outer_keys?(_), do: false

  defp closed_marker_outer_keys?(marker) when is_map(marker) do
    MapSet.equal?(MapSet.new(Map.keys(marker)), @marker_outer_keys)
  end

  defp closed_marker_outer_keys?(_), do: false

  defp closed_marker_v2_outer_keys?(marker) when is_map(marker) do
    MapSet.equal?(MapSet.new(Map.keys(marker)), @marker_v2_outer_keys)
  end

  defp closed_marker_v2_outer_keys?(_), do: false

  defp valid_principal_id?(id) when is_binary(id) do
    byte_size(id) > 0 and byte_size(id) <= @max_principal_bytes and valid_task_id?(id)
  end

  defp valid_principal_id?(_), do: false

  defp valid_executor_kind?(kind)
       when is_binary(kind) and byte_size(kind) > 0 and
              byte_size(kind) <= @max_executor_kind_bytes do
    String.valid?(kind) and Regex.match?(@executor_kind_pattern, kind)
  end

  defp valid_executor_kind?(_), do: false

  defp required_principal(attrs, key) do
    value = attr_get(attrs, key)

    if valid_principal_id?(value), do: {:ok, value}, else: {:error, :invalid_marker}
  end

  defp required_executor_kind(attrs) do
    value = attr_get(attrs, :executor_kind)

    if valid_executor_kind?(value), do: {:ok, value}, else: {:error, :invalid_marker}
  end

  defp required_run_id(attrs, task_id) do
    value = attr_get(attrs, :run_id) || task_id

    if is_binary(value) and value == task_id and valid_task_id?(value) do
      {:ok, value}
    else
      {:error, :invalid_marker}
    end
  end

  defp normalize_cleanup(attrs, agent_id, control_principal_id) do
    cleanup = attr_get(attrs, :cleanup)

    cond do
      is_map(cleanup) ->
        normalize_cleanup_map(cleanup, agent_id, control_principal_id)

      is_nil(cleanup) ->
        {:ok,
         %{
           "caller_id" => control_principal_id,
           "principal_id" => agent_id
         }}

      true ->
        {:error, :invalid_marker}
    end
  end

  defp normalize_cleanup_map(cleanup, agent_id, control_principal_id) when is_map(cleanup) do
    caller_id = attr_get(cleanup, :caller_id)
    principal_id = attr_get(cleanup, :principal_id)
    trace_id = attr_get(cleanup, :trace_id)
    keys = MapSet.new(Enum.map(Map.keys(cleanup), &stringify_cleanup_key/1))

    cond do
      not MapSet.subset?(keys, MapSet.union(@cleanup_required_keys, @cleanup_optional_keys)) ->
        {:error, :invalid_marker}

      not MapSet.subset?(@cleanup_required_keys, keys) ->
        {:error, :invalid_marker}

      map_size(cleanup) not in [2, 3] ->
        {:error, :invalid_marker}

      caller_id != control_principal_id or not valid_principal_id?(caller_id) ->
        {:error, :invalid_marker}

      principal_id != agent_id or not valid_principal_id?(principal_id) ->
        {:error, :invalid_marker}

      is_binary(trace_id) and
          (not String.valid?(trace_id) or trace_id == "" or byte_size(trace_id) > 256) ->
        {:error, :invalid_marker}

      is_binary(trace_id) ->
        {:ok,
         %{
           "caller_id" => caller_id,
           "principal_id" => principal_id,
           "trace_id" => trace_id
         }}

      is_nil(trace_id) and map_size(cleanup) == 2 ->
        {:ok, %{"caller_id" => caller_id, "principal_id" => principal_id}}

      true ->
        {:error, :invalid_marker}
    end
  end

  defp normalize_cleanup_map(_cleanup, _agent_id, _control_principal_id),
    do: {:error, :invalid_marker}

  defp attr_get(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp stringify_cleanup_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_cleanup_key(key) when is_binary(key), do: key
  defp stringify_cleanup_key(_), do: ""

  defp listed_capability_kind_and_id(cap, task_id) when is_map(cap) do
    id = listed_cap_id(cap)
    resource = listed_cap_resource(cap)
    cap_task_id = listed_cap_task_id(cap)

    cond do
      not is_binary(id) or id == "" ->
        :error

      is_binary(cap_task_id) and cap_task_id != task_id ->
        :error

      true ->
        Enum.find_value(@kinds, :error, fn kind ->
          case uri(kind, task_id) do
            {:ok, ^resource} -> {:ok, kind, id}
            _ -> nil
          end
        end) || :error
    end
  end

  defp listed_capability_kind_and_id(_cap, _task_id), do: :error

  defp listed_cap_id(%{id: id}) when is_binary(id), do: id
  defp listed_cap_id(%{"id" => id}) when is_binary(id), do: id
  defp listed_cap_id(_), do: nil

  defp listed_cap_resource(%{resource_uri: uri}) when is_binary(uri), do: uri
  defp listed_cap_resource(%{resource: uri}) when is_binary(uri), do: uri
  defp listed_cap_resource(%{"resource_uri" => uri}) when is_binary(uri), do: uri
  defp listed_cap_resource(_), do: nil

  defp listed_cap_task_id(%{task_id: id}) when is_binary(id), do: id
  defp listed_cap_task_id(%{"task_id" => id}) when is_binary(id), do: id
  defp listed_cap_task_id(_), do: nil

  defp normalize_capability_map(map) when is_map(map) do
    # Reject unknown keys first, including non-atom/non-binary key types.
    # A PID/integer/ref key must not be silently ignored via empty-string coercion.
    case validate_capability_map_keys(map) do
      :ok ->
        reduced =
          Enum.reduce_while(@kinds, %{}, fn kind, acc ->
            key_atom = kind
            key_string = Atom.to_string(kind)
            atom_present? = Map.has_key?(map, key_atom)
            string_present? = Map.has_key?(map, key_string)

            cond do
              atom_present? and string_present? ->
                # Atom+string alias pair is ambiguous even when values match.
                {:halt, {:error, :duplicate_kind_key_alias}}

              atom_present? ->
                put_capability_id(acc, key_string, Map.get(map, key_atom), kind)

              string_present? ->
                put_capability_id(acc, key_string, Map.get(map, key_string), kind)

              true ->
                {:halt, {:error, {:missing_capability, kind}}}
            end
          end)

        case reduced do
          {:error, _} = error ->
            error

          caps when is_map(caps) and map_size(caps) == 6 ->
            ids = Map.values(caps)

            if length(Enum.uniq(ids)) != 6 do
              {:error, :duplicate_capability_ids}
            else
              {:ok, caps}
            end

          _ ->
            {:error, :invalid_lease}
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_capability_map_keys(map) when is_map(map) do
    Enum.reduce_while(Map.keys(map), :ok, fn key, :ok ->
      case key do
        k when is_atom(k) ->
          if Atom.to_string(k) in @kind_strings do
            {:cont, :ok}
          else
            {:halt, {:error, :invalid_lease_kinds}}
          end

        k when is_binary(k) ->
          if k in @kind_strings do
            {:cont, :ok}
          else
            {:halt, {:error, :invalid_lease_kinds}}
          end

        _other ->
          # Non-atom/non-binary keys are unknown lease-map keys.
          {:halt, {:error, :invalid_lease_kinds}}
      end
    end)
  end

  defp put_capability_id(acc, key_string, id, kind) do
    if valid_capability_id?(id) do
      {:cont, Map.put(acc, key_string, id)}
    else
      {:halt, {:error, {:invalid_capability_id, kind}}}
    end
  end

  defp valid_capability_id?(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_capability_id_bytes do
    String.valid?(id) and not String.match?(id, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_capability_id?(_), do: false
end
