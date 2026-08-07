defmodule Arbor.Persistence.RelationshipStore do
  @moduledoc false

  # Internal durable store for tenant-scoped relationship rows.
  # Public callers must use Arbor.Persistence facade operations only.

  import Ecto.Query

  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Relationship, as: Schema

  require Logger

  @put_keys MapSet.new([
              :id,
              :name,
              :preferred_name,
              :background,
              :values,
              :connections,
              :key_moments,
              :relationship_dynamic,
              :personal_details,
              :current_focus,
              :uncertainties,
              :first_encountered,
              :last_interaction,
              :salience,
              :access_count
            ])

  # Update may rename (`:name`) but never transfer identity/tenant.
  @update_keys MapSet.delete(@put_keys, :id)
  @required_put_keys MapSet.new([:id, :name])
  @forbidden_update_keys MapSet.new([:id, :agent_id])

  @list_option_keys [:sort_by, :sort_dir, :limit]
  @sort_fields [:salience, :last_interaction, :name, :access_count]
  @sort_dirs [:asc, :desc]

  @default_list_limit 100
  @max_list_limit 1_000
  @max_id_bytes 256
  @max_optional_string_bytes 1_024
  @max_list_elems 100
  @max_list_elem_bytes 1_024
  @max_moments 100
  @max_moment_summary_bytes 2_048
  @max_markers 32
  @max_marker_bytes 64
  @max_row_bytes 65_536
  @max_page_bytes 1_048_576

  @moment_keys MapSet.new([:summary, :timestamp, :emotional_markers, :salience])

  @plain_record_defaults %{
    preferred_name: nil,
    background: [],
    values: [],
    connections: [],
    key_moments: [],
    relationship_dynamic: nil,
    personal_details: [],
    current_focus: [],
    uncertainties: [],
    first_encountered: nil,
    last_interaction: nil,
    salience: 0.5,
    access_count: 0
  }

  # Upserts preserve an existing row id on a name conflict. Budget the worst
  # JSON expansion of any valid retained id before writing.
  @max_encoded_id_budget String.duplicate(<<0>>, @max_id_bytes)

  @verify_hook_key {__MODULE__, :post_delete_remaining_override}

  @type relationship_error ::
          :invalid_request
          | :invalid_options
          | :not_found
          | :validation_failed
          | :backend_failure
          | :indeterminate

  # ---------------------------------------------------------------------------
  # Public (internal) API
  # ---------------------------------------------------------------------------

  @spec put(String.t(), map()) :: {:ok, map()} | {:error, relationship_error()}
  def put(agent_id, attrs) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, normalized} <- validate_put_map(attrs),
         :ok <- validate_put_record_bytes(normalized) do
      dispatch(fn -> do_put(agent_id, normalized) end)
    end
  end

  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, relationship_error()}
  def fetch(agent_id, relationship_id) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_id(relationship_id) do
      dispatch(fn -> do_fetch(agent_id, relationship_id) end)
    end
  end

  @spec fetch_by_name(String.t(), String.t()) :: {:ok, map()} | {:error, relationship_error()}
  def fetch_by_name(agent_id, name) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_name(name) do
      dispatch(fn -> do_fetch_by_name(agent_id, name) end)
    end
  end

  @spec list(String.t(), keyword()) :: {:ok, [map()]} | {:error, relationship_error()}
  def list(agent_id, opts \\ []) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, list_opts} <- normalize_list_opts(opts) do
      dispatch(fn -> do_list(agent_id, list_opts) end)
    end
  end

  @spec update(String.t(), String.t(), map()) :: {:ok, map()} | {:error, relationship_error()}
  def update(agent_id, relationship_id, changes) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_id(relationship_id),
         {:ok, normalized} <- validate_update_map(changes) do
      dispatch(fn -> do_update(agent_id, relationship_id, normalized) end)
    end
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, relationship_error()}
  def delete(agent_id, relationship_id) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_id(relationship_id) do
      dispatch(fn -> do_delete(agent_id, relationship_id) end)
    end
  end

  @spec touch(String.t(), String.t()) :: {:ok, map()} | {:error, relationship_error()}
  def touch(agent_id, relationship_id) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_id(relationship_id) do
      dispatch(fn -> do_touch(agent_id, relationship_id) end)
    end
  end

  @spec count(String.t()) :: {:ok, non_neg_integer()} | {:error, relationship_error()}
  def count(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      dispatch(fn -> do_count(agent_id) end)
    end
  end

  @spec fetch_primary(String.t()) :: {:ok, map()} | {:error, relationship_error()}
  def fetch_primary(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      dispatch(fn -> do_fetch_primary(agent_id) end)
    end
  end

  @spec delete_all(String.t()) :: :ok | {:error, relationship_error()}
  def delete_all(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      dispatch(fn -> do_delete_all(agent_id) end)
    end
  end

  @spec absent?(String.t()) :: {:ok, true} | {:ok, false} | {:error, relationship_error()}
  def absent?(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      dispatch(fn -> do_absent?(agent_id) end)
    end
  end

  # Test-only process-local seam for delete-all verify failure.
  if Mix.env() == :test do
    @doc false
    def __set_post_delete_remaining_override__(n) when is_integer(n) and n >= 0 do
      Process.put(@verify_hook_key, n)
      :ok
    end

    @doc false
    def __clear_post_delete_remaining_override__ do
      Process.delete(@verify_hook_key)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # DB operations
  # ---------------------------------------------------------------------------

  defp do_put(agent_id, normalized) do
    attrs = Schema.attrs_from_map(normalized, agent_id)
    changeset = Schema.changeset(%Schema{}, attrs)

    case Repo.insert(changeset,
           on_conflict: {:replace_all_except, [:id, :agent_id, :inserted_at]},
           conflict_target: [:agent_id, :name],
           returning: true
         ) do
      {:ok, schema} ->
        with {:ok, plain} <- encode_row(schema), do: {:ok, plain}

      {:error, %Ecto.Changeset{}} ->
        {:error, :validation_failed}

      {:error, _reason} ->
        {:error, :backend_failure}
    end
  end

  defp do_fetch(agent_id, relationship_id) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> encode_row(schema)
    end
  end

  defp do_fetch_by_name(agent_id, name) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id and r.name == ^name
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> encode_row(schema)
    end
  end

  defp do_list(agent_id, %{sort_by: sort_by, sort_dir: sort_dir, limit: limit}) do
    query =
      from(r in Schema, where: r.agent_id == ^agent_id)
      |> apply_sort(sort_by, sort_dir)
      |> limit(^limit)

    rows = Repo.all(query)

    with {:ok, plains} <- encode_rows(rows) do
      {:ok, plains}
    end
  end

  defp do_update(agent_id, relationship_id, changes) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      schema ->
        projected = Map.merge(Schema.to_plain_map(schema), changes)

        with :ok <- validate_record_bytes(projected) do
          update_attrs = prepare_update_attrs(changes)
          changeset = Schema.changeset(schema, update_attrs)

          case Repo.update(changeset) do
            {:ok, updated} -> encode_row(updated)
            {:error, %Ecto.Changeset{}} -> {:error, :validation_failed}
            {:error, _} -> {:error, :backend_failure}
          end
        end
    end
  end

  defp prepare_update_attrs(changes) do
    changes
    |> Map.new(fn
      {:key_moments, moments} when is_list(moments) ->
        {:key_moments, Enum.map(moments, &serialize_moment_for_update/1)}

      other ->
        other
    end)
  end

  defp serialize_moment_for_update(moment) when is_map(moment) do
    markers = Map.get(moment, :emotional_markers) || []

    %{
      "summary" => Map.get(moment, :summary),
      "timestamp" => serialize_ts(Map.get(moment, :timestamp)),
      "emotional_markers" => Enum.map(markers, &to_string/1),
      "salience" => Map.get(moment, :salience) || 0.5
    }
  end

  defp serialize_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_ts(str) when is_binary(str), do: str
  defp serialize_ts(_), do: nil

  defp do_delete(agent_id, relationship_id) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id
      )

    case Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  defp do_touch(agent_id, relationship_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id and r.id == ^relationship_id,
        update: [
          inc: [access_count: 1],
          set: [last_interaction: ^now, updated_at: ^now]
        ]
      )

    case Repo.update_all(query, []) do
      {0, _} ->
        {:error, :not_found}

      {1, _} ->
        # Touch committed: missing or uncertain post-image is indeterminate.
        case do_fetch(agent_id, relationship_id) do
          {:ok, plain} -> {:ok, plain}
          {:error, _reason} -> {:error, :indeterminate}
        end

      {_n, _} ->
        {:error, :indeterminate}
    end
  end

  defp do_count(agent_id) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id,
        select: count(r.id)
      )

    {:ok, Repo.one(query) || 0}
  end

  defp do_fetch_primary(agent_id) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id,
        order_by: [desc: r.salience, asc: r.name, asc: r.id],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> encode_row(schema)
    end
  end

  defp do_delete_all(agent_id) do
    case Repo.transaction(fn ->
           query = from(r in Schema, where: r.agent_id == ^agent_id)
           {_count, _} = Repo.delete_all(query)
           remaining = post_delete_remaining(agent_id)

           if remaining == 0 do
             :ok
           else
             Repo.rollback(:indeterminate)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, :indeterminate} -> {:error, :indeterminate}
      {:error, _reason} -> {:error, :backend_failure}
    end
  end

  defp do_absent?(agent_id) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id,
        select: count(r.id)
      )

    case Repo.one(query) || 0 do
      0 -> {:ok, true}
      _n -> {:ok, false}
    end
  end

  defp post_delete_remaining(agent_id) do
    if Mix.env() == :test do
      case Process.get(@verify_hook_key) do
        n when is_integer(n) and n >= 0 -> n
        _ -> real_count(agent_id)
      end
    else
      real_count(agent_id)
    end
  end

  defp real_count(agent_id) do
    query =
      from(r in Schema,
        where: r.agent_id == ^agent_id,
        select: count(r.id)
      )

    Repo.one(query) || 0
  end

  # Deterministic secondary order: name ASC, id ASC on every primary sort.
  defp apply_sort(query, :salience, :desc),
    do: from(r in query, order_by: [desc: r.salience, asc: r.name, asc: r.id])

  defp apply_sort(query, :salience, :asc),
    do: from(r in query, order_by: [asc: r.salience, asc: r.name, asc: r.id])

  defp apply_sort(query, :last_interaction, :desc),
    do:
      from(r in query,
        order_by: [desc_nulls_last: r.last_interaction, asc: r.name, asc: r.id]
      )

  defp apply_sort(query, :last_interaction, :asc),
    do:
      from(r in query,
        order_by: [asc_nulls_last: r.last_interaction, asc: r.name, asc: r.id]
      )

  defp apply_sort(query, :name, :desc),
    do: from(r in query, order_by: [desc: r.name, asc: r.id])

  defp apply_sort(query, :name, :asc),
    do: from(r in query, order_by: [asc: r.name, asc: r.id])

  defp apply_sort(query, :access_count, :desc),
    do: from(r in query, order_by: [desc: r.access_count, asc: r.name, asc: r.id])

  defp apply_sort(query, :access_count, :asc),
    do: from(r in query, order_by: [asc: r.access_count, asc: r.name, asc: r.id])

  # ---------------------------------------------------------------------------
  # Encoding / byte budgets
  # ---------------------------------------------------------------------------

  defp encode_row(%Schema{} = schema) do
    plain = Schema.to_plain_map(schema)

    case canonical_bytes(plain) do
      {:ok, size} when size <= @max_row_bytes -> {:ok, plain}
      {:ok, _size} -> {:error, :backend_failure}
      {:error, _} -> {:error, :backend_failure}
    end
  end

  defp encode_rows(schemas) do
    # Two bytes account for the surrounding JSON array. Each row after the
    # first adds one comma, so the page ceiling describes the actual envelope.
    Enum.reduce_while(schemas, {:ok, [], 2}, fn schema, {:ok, acc, total} ->
      case encode_row(schema) do
        {:ok, plain} ->
          case canonical_bytes(plain) do
            {:ok, size} ->
              separator_bytes = if acc == [], do: 0, else: 1
              next = total + separator_bytes + size

              if next <= @max_page_bytes do
                {:cont, {:ok, [plain | acc], next}}
              else
                {:halt, {:error, :backend_failure}}
              end

            {:error, _} ->
              {:halt, {:error, :backend_failure}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc, _total} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record_bytes(map) do
    case canonical_bytes(map) do
      {:ok, size} when size <= @max_row_bytes -> :ok
      {:ok, _} -> {:error, :invalid_request}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp validate_put_record_bytes(normalized) do
    @plain_record_defaults
    |> Map.merge(normalized)
    |> Map.put(:id, @max_encoded_id_budget)
    |> validate_record_bytes()
  end

  defp canonical_bytes(value) do
    json_safe = json_safe(value)

    case Jason.encode(json_safe) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, _} -> {:error, :encode_failed}
    end
  end

  defp json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), json_safe(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
  end

  defp json_safe(other), do: other

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_agent_id(id), do: validate_id_like(id)
  defp validate_id(id), do: validate_id_like(id)
  defp validate_name(name), do: validate_id_like(name)

  defp validate_id_like(value) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" and byte_size(value) <= @max_id_bytes do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp validate_id_like(_), do: {:error, :invalid_request}

  defp validate_put_map(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- reject_string_or_mixed_keys(attrs),
         :ok <- reject_unknown_keys(attrs, @put_keys),
         :ok <- reject_agent_id_key(attrs),
         :ok <- require_keys(attrs, @required_put_keys),
         {:ok, normalized} <- normalize_fields(attrs, :put) do
      {:ok, normalized}
    end
  end

  defp validate_put_map(_), do: {:error, :invalid_request}

  defp validate_update_map(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- reject_string_or_mixed_keys(attrs),
         :ok <- reject_forbidden_update_keys(attrs),
         :ok <- reject_unknown_keys(attrs, @update_keys),
         :ok <- reject_empty_update(attrs),
         {:ok, normalized} <- normalize_fields(attrs, :update) do
      {:ok, normalized}
    end
  end

  defp validate_update_map(_), do: {:error, :invalid_request}

  defp reject_empty_update(attrs) do
    if map_size(attrs) == 0, do: {:error, :invalid_request}, else: :ok
  end

  defp reject_string_or_mixed_keys(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &is_binary/1) -> {:error, :invalid_request}
      Enum.any?(keys, &(not is_atom(&1))) -> {:error, :invalid_request}
      true -> :ok
    end
  end

  defp reject_unknown_keys(attrs, allowed) do
    unknown = MapSet.difference(MapSet.new(Map.keys(attrs)), allowed)

    if MapSet.size(unknown) == 0, do: :ok, else: {:error, :invalid_request}
  end

  defp reject_agent_id_key(attrs) do
    if Map.has_key?(attrs, :agent_id) or Map.has_key?(attrs, "agent_id") do
      {:error, :invalid_request}
    else
      :ok
    end
  end

  defp reject_forbidden_update_keys(attrs) do
    if Enum.any?(@forbidden_update_keys, &Map.has_key?(attrs, &1)) do
      {:error, :invalid_request}
    else
      :ok
    end
  end

  defp require_keys(attrs, required) do
    missing = Enum.reject(required, &Map.has_key?(attrs, &1))
    if missing == [], do: :ok, else: {:error, :invalid_request}
  end

  defp normalize_fields(attrs, mode) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_field(key, value, mode) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_field(:id, value, _), do: with(:ok <- validate_id(value), do: {:ok, value})
  defp normalize_field(:name, value, _), do: with(:ok <- validate_name(value), do: {:ok, value})

  defp normalize_field(key, value, _)
       when key in [:preferred_name, :relationship_dynamic] do
    normalize_optional_string(value)
  end

  defp normalize_field(key, value, _)
       when key in [
              :background,
              :values,
              :connections,
              :personal_details,
              :current_focus,
              :uncertainties
            ] do
    normalize_string_list(value)
  end

  defp normalize_field(:key_moments, value, _), do: normalize_moments(value)

  defp normalize_field(key, value, _) when key in [:first_encountered, :last_interaction] do
    normalize_timestamp(value)
  end

  defp normalize_field(:salience, value, _)
       when is_float(value) and value >= 0.0 and value <= 1.0,
       do: {:ok, value}

  defp normalize_field(:salience, value, _) when is_integer(value) and value >= 0 and value <= 1,
    do: {:ok, value * 1.0}

  defp normalize_field(:salience, _, _), do: {:error, :invalid_request}

  defp normalize_field(:access_count, value, _) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize_field(:access_count, _, _), do: {:error, :invalid_request}

  defp normalize_field(_, _, _), do: {:error, :invalid_request}

  defp normalize_optional_string(nil), do: {:ok, nil}

  defp normalize_optional_string(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_optional_string_bytes do
      {:ok, value}
    else
      {:error, :invalid_request}
    end
  end

  defp normalize_optional_string(_), do: {:error, :invalid_request}

  defp normalize_string_list(list) when is_list(list) do
    if not bounded_proper_list?(list, @max_list_elems) do
      {:error, :invalid_request}
    else
      Enum.reduce_while(list, {:ok, []}, fn
        elem, {:ok, acc} when is_binary(elem) ->
          if String.valid?(elem) and byte_size(elem) <= @max_list_elem_bytes do
            {:cont, {:ok, [elem | acc]}}
          else
            {:halt, {:error, :invalid_request}}
          end

        _elem, _acc ->
          {:halt, {:error, :invalid_request}}
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp normalize_string_list(_), do: {:error, :invalid_request}

  defp normalize_moments(list) when is_list(list) do
    if not bounded_proper_list?(list, @max_moments) do
      {:error, :invalid_request}
    else
      Enum.reduce_while(list, {:ok, []}, fn moment, {:ok, acc} ->
        case normalize_moment(moment) do
          {:ok, m} -> {:cont, {:ok, [m | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp normalize_moments(_), do: {:error, :invalid_request}

  defp normalize_moment(moment) when is_map(moment) and not is_struct(moment) do
    with :ok <- reject_string_or_mixed_keys(moment),
         :ok <- reject_unknown_keys(moment, @moment_keys),
         {:ok, summary} <- normalize_moment_summary(Map.get(moment, :summary)),
         {:ok, timestamp} <- normalize_timestamp(Map.get(moment, :timestamp)),
         {:ok, markers} <- normalize_markers(Map.get(moment, :emotional_markers, [])),
         {:ok, salience} <- normalize_moment_salience(Map.get(moment, :salience, 0.5)) do
      {:ok,
       %{
         summary: summary,
         timestamp: timestamp,
         emotional_markers: markers,
         salience: salience
       }}
    end
  end

  defp normalize_moment(_), do: {:error, :invalid_request}

  defp normalize_moment_summary(summary) when is_binary(summary) do
    if String.valid?(summary) and byte_size(summary) <= @max_moment_summary_bytes do
      {:ok, summary}
    else
      {:error, :invalid_request}
    end
  end

  defp normalize_moment_summary(_), do: {:error, :invalid_request}

  defp normalize_moment_salience(value)
       when is_float(value) and value >= 0.0 and value <= 1.0,
       do: {:ok, value}

  defp normalize_moment_salience(value) when is_integer(value) and value >= 0 and value <= 1,
    do: {:ok, value * 1.0}

  defp normalize_moment_salience(_), do: {:error, :invalid_request}

  defp normalize_markers(list) when is_list(list) do
    if not bounded_proper_list?(list, @max_markers) do
      {:error, :invalid_request}
    else
      Enum.reduce_while(list, {:ok, []}, fn
        marker, {:ok, acc} when is_atom(marker) ->
          s = Atom.to_string(marker)

          if byte_size(s) <= @max_marker_bytes do
            {:cont, {:ok, [s | acc]}}
          else
            {:halt, {:error, :invalid_request}}
          end

        marker, {:ok, acc} when is_binary(marker) ->
          if String.valid?(marker) and byte_size(marker) <= @max_marker_bytes do
            {:cont, {:ok, [marker | acc]}}
          else
            {:halt, {:error, :invalid_request}}
          end

        _, _ ->
          {:halt, {:error, :invalid_request}}
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp normalize_markers(_), do: {:error, :invalid_request}

  defp bounded_proper_list?(list, maximum), do: bounded_proper_list?(list, maximum, 0)

  defp bounded_proper_list?([], _maximum, _count), do: true

  defp bounded_proper_list?([_head | tail], maximum, count) when count < maximum,
    do: bounded_proper_list?(tail, maximum, count + 1)

  defp bounded_proper_list?(_list_or_tail, _maximum, _count), do: false

  defp normalize_timestamp(nil), do: {:ok, nil}
  defp normalize_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp normalize_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp normalize_timestamp(_), do: {:error, :invalid_request}

  defp normalize_list_opts(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_options}

      true ->
        unknown = Enum.reject(Keyword.keys(opts), &(&1 in @list_option_keys))

        if unknown != [] do
          {:error, :invalid_options}
        else
          sort_by = Keyword.get(opts, :sort_by, :salience)
          sort_dir = Keyword.get(opts, :sort_dir, :desc)
          limit = Keyword.get(opts, :limit, @default_list_limit)

          cond do
            sort_by not in @sort_fields ->
              {:error, :invalid_options}

            sort_dir not in @sort_dirs ->
              {:error, :invalid_options}

            not (is_integer(limit) and limit > 0 and limit <= @max_list_limit) ->
              {:error, :invalid_options}

            true ->
              {:ok, %{sort_by: sort_by, sort_dir: sort_dir, limit: limit}}
          end
        end
    end
  end

  defp dispatch(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("RelationshipStore backend failure: #{Exception.message(error)}")
      {:error, :backend_failure}
  catch
    kind, reason ->
      Logger.warning("RelationshipStore dispatch #{kind}: #{inspect(reason)}")
      {:error, :backend_failure}
  end
end
