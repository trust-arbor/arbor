defmodule Arbor.Orchestrator.CodingPlan.ActionCatalog do
  @moduledoc """
  Builds a deterministic, JSON-clean snapshot of live Jido action schemas.

  Production snapshots **union** modules from the running
  `Arbor.Common.ActionRegistry` with the current `Arbor.Actions.list_actions/0`
  facade:

  - The registry preserves dynamically registered / plugin actions that may not
    appear in the facade.
  - The facade covers core actions that were hot-loaded after the registry was
    populated and core-locked (so a stale locked registry alone cannot hide a
    published action until node restart).
  - When the registry is unavailable, the facade alone is sufficient.

  Entries are deduplicated by module (registry aliases and facade overlap collapse
  to one inspect). Distinct modules that publish the same action name still fail
  closed via `{:duplicate_action_name, name}`.

  Registry entries contain aliases and runtime module references. A snapshot
  deduplicates those aliases by module, calls each action's `to_tool/0`, and
  combines its schema with `Arbor.Actions.runtime_descriptor/1` plus catalog-only
  `execution_dependencies` metadata from `Arbor.Actions.execution_dependencies/1`.
  Module names and loaded BEAM digests are retained as JSON strings so compilation
  can bind exact executable code without retaining atoms, functions, PIDs, or
  other runtime references. The catalog digest binds dependency metadata; final
  execution manifests strip it after transitive closure expansion.
  """

  alias Arbor.Common.ActionRegistry

  @max_error_message_bytes 512

  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | %{optional(String.t()) => json_value()}

  @type action_spec :: %{
          required(String.t()) => json_value()
        }

  @type snapshot :: %{
          required(String.t()) => String.t() | [action_spec()]
        }

  @type error_reason ::
          :invalid_options
          | :ambiguous_source
          | {:unknown_options, [atom()]}
          | {:invalid_registry_entries, term()}
          | {:invalid_registry_entry, non_neg_integer()}
          | {:invalid_modules, term()}
          | {:invalid_module, non_neg_integer()}
          | {:action_source_unavailable, String.t()}
          | {:action_uninspectable, String.t(), String.t()}
          | {:invalid_action_spec, String.t(), term()}
          | {:duplicate_action_name, String.t()}
          | {:catalog_digest_failed, String.t()}

  @doc """
  Build the current action-schema snapshot.

  With no options, production mode unions the live action registry (when it is
  running) with the public Actions facade so plugin/dynamic entries and
  post-lock facade core actions are both present. If the registry is unavailable,
  the facade alone supplies the module map.

  Tests and other deterministic callers can inject either registry-shaped
  `:entries` (`{name, module, metadata}` tuples) or facade-shaped `:modules`
  (a category map or flat module list). The two options are mutually exclusive
  and bypass production reconciliation.
  """
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, error_reason()}
  def snapshot(opts \\ [])

  def snapshot(opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, modules} <- modules_for(opts),
         {:ok, actions} <- inspect_actions(modules),
         {:ok, digest} <- digest(actions) do
      {:ok,
       %{
         "actions" => actions,
         "digest" => digest
       }}
    end
  end

  def snapshot(_opts), do: {:error, :invalid_options}

  @doc """
  Fetch an action spec by its exact Jido tool name.
  """
  @spec fetch(snapshot(), String.t()) :: {:ok, action_spec()} | :error
  def fetch(%{"actions" => actions}, name) when is_list(actions) and is_binary(name) do
    case Enum.find(actions, &(Map.get(&1, "name") == name)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  def fetch(_snapshot, _name), do: :error

  @doc """
  Return the sorted action names in a snapshot.
  """
  @spec names(snapshot()) :: [String.t()]
  def names(%{"actions" => actions}) when is_list(actions) do
    Enum.map(actions, &Map.fetch!(&1, "name"))
  end

  def names(_snapshot), do: []

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      unknown = Keyword.keys(opts) -- [:entries, :modules]

      cond do
        unknown != [] ->
          {:error, {:unknown_options, Enum.uniq(unknown)}}

        Keyword.has_key?(opts, :entries) and Keyword.has_key?(opts, :modules) ->
          {:error, :ambiguous_source}

        true ->
          :ok
      end
    else
      {:error, :invalid_options}
    end
  end

  defp modules_for(opts) do
    cond do
      Keyword.has_key?(opts, :entries) -> modules_from_entries(Keyword.fetch!(opts, :entries))
      Keyword.has_key?(opts, :modules) -> modules_from_facade(Keyword.fetch!(opts, :modules))
      true -> production_modules()
    end
  end

  defp production_modules do
    case registry_entries() do
      {:ok, entries} ->
        with {:ok, registry_modules} <- modules_from_entries(entries),
             {:ok, facade_modules} <- fallback_modules() do
          # Union: keep plugin/dynamic registry modules and always include the
          # current facade so hot-loaded core actions appear without restart.
          dedupe_modules({:ok, registry_modules ++ facade_modules})
        end

      :unavailable ->
        fallback_modules()
    end
  end

  defp registry_entries do
    if Process.whereis(ActionRegistry) do
      list_registry_entries()
    else
      :unavailable
    end
  end

  defp list_registry_entries do
    {:ok, ActionRegistry.list_all()}
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp fallback_modules do
    Arbor.Actions.list_actions()
    |> modules_from_facade()
  rescue
    exception ->
      {:error, {:action_source_unavailable, exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:action_source_unavailable, caught_message(kind, reason)}}
  end

  defp modules_from_entries(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {{name, module, metadata}, _index}, {:ok, modules}
      when is_binary(name) and is_atom(module) and is_map(metadata) ->
        {:cont, {:ok, [module | modules]}}

      {_entry, index}, _acc ->
        {:halt, {:error, {:invalid_registry_entry, index}}}
    end)
    |> dedupe_modules()
  end

  defp modules_from_entries(entries),
    do: {:error, {:invalid_registry_entries, source_shape(entries)}}

  defp modules_from_facade(modules) when is_map(modules) do
    modules
    |> Map.values()
    |> Enum.reduce_while({:ok, []}, fn
      category_modules, {:ok, acc} when is_list(category_modules) ->
        {:cont, {:ok, category_modules ++ acc}}

      category_modules, _acc ->
        {:halt, {:error, {:invalid_modules, source_shape(category_modules)}}}
    end)
    |> validate_modules()
  end

  defp modules_from_facade(modules) when is_list(modules) do
    modules
    |> then(&{:ok, &1})
    |> validate_modules()
  end

  defp modules_from_facade(modules), do: {:error, {:invalid_modules, source_shape(modules)}}

  defp validate_modules({:error, _reason} = error), do: error

  defp validate_modules({:ok, modules}) do
    modules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {module, _index}, {:ok, acc} when is_atom(module) ->
        {:cont, {:ok, [module | acc]}}

      {_module, index}, _acc ->
        {:halt, {:error, {:invalid_module, index}}}
    end)
    |> dedupe_modules()
  end

  defp dedupe_modules({:error, _reason} = error), do: error

  defp dedupe_modules({:ok, modules}) do
    modules =
      modules
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)

    {:ok, modules}
  end

  defp inspect_actions(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, actions} ->
      case inspect_action(module) do
        {:ok, action} -> {:cont, {:ok, [action | actions]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, actions} -> sort_and_validate_names(actions)
      {:error, _reason} = error -> error
    end
  end

  defp inspect_action(module) do
    module_name = Atom.to_string(module)

    try do
      with {:ok, spec} <- module |> apply(:to_tool, []) |> normalize_action_spec(module_name),
           {:ok, descriptor} <- Arbor.Actions.runtime_descriptor(module),
           :ok <- require_descriptor_name(descriptor, spec, module_name),
           {:ok, execution_dependencies} <- Arbor.Actions.execution_dependencies(module) do
        {:ok,
         spec
         |> Map.merge(descriptor)
         |> Map.put("execution_dependencies", execution_dependencies)}
      else
        {:error, reason} when is_atom(reason) ->
          {:error, {:action_uninspectable, module_name, bounded_message(Atom.to_string(reason))}}

        {:error, _reason} = error ->
          error
      end
    rescue
      exception ->
        {:error, {:action_uninspectable, module_name, exception_message(exception)}}
    catch
      kind, reason ->
        {:error, {:action_uninspectable, module_name, caught_message(kind, reason)}}
    end
  end

  defp normalize_action_spec(%_{} = _spec, module_name),
    do: {:error, {:invalid_action_spec, module_name, :expected_map}}

  defp normalize_action_spec(spec, module_name) when is_map(spec) do
    with {:ok, name} <- spec_field(spec, :name, module_name),
         :ok <- validate_name(name, module_name),
         {:ok, description} <- spec_field(spec, :description, module_name),
         :ok <- validate_description(description, module_name),
         {:ok, schema} <- spec_field(spec, :parameters_schema, module_name),
         {:ok, schema} <- normalize_json(schema, ["parameters_schema"]),
         :ok <- validate_schema(schema, module_name) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "parameters_schema" => schema
       }}
    else
      {:error, {:invalid_json, reason}} ->
        {:error, {:invalid_action_spec, module_name, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_action_spec(_spec, module_name),
    do: {:error, {:invalid_action_spec, module_name, :expected_map}}

  defp require_descriptor_name(%{"name" => name}, %{"name" => name}, _module_name), do: :ok

  defp require_descriptor_name(_descriptor, _spec, module_name),
    do: {:error, {:invalid_action_spec, module_name, :runtime_name_mismatch}}

  defp spec_field(spec, field, module_name) do
    string_field = Atom.to_string(field)

    case {Map.fetch(spec, field), Map.fetch(spec, string_field)} do
      {{:ok, value}, :error} ->
        {:ok, value}

      {:error, {:ok, value}} ->
        {:ok, value}

      {{:ok, value}, {:ok, value}} ->
        {:ok, value}

      {{:ok, _atom_value}, {:ok, _string_value}} ->
        {:error, {:invalid_action_spec, module_name, {:conflicting_field, string_field}}}

      {:error, :error} ->
        {:error, {:invalid_action_spec, module_name, {:missing_field, string_field}}}
    end
  end

  defp validate_name(name, module_name) when is_binary(name) do
    if String.valid?(name) and String.trim(name) != "" do
      :ok
    else
      {:error, {:invalid_action_spec, module_name, :invalid_name}}
    end
  end

  defp validate_name(_name, module_name),
    do: {:error, {:invalid_action_spec, module_name, :invalid_name}}

  defp validate_description(description, module_name) when is_binary(description) do
    if String.valid?(description) do
      :ok
    else
      {:error, {:invalid_action_spec, module_name, :invalid_description}}
    end
  end

  defp validate_description(_description, module_name),
    do: {:error, {:invalid_action_spec, module_name, :invalid_description}}

  defp validate_schema(schema, _module_name) when is_map(schema) do
    case Jason.encode(schema) do
      {:ok, _json} ->
        :ok

      {:error, reason} ->
        {:error, {:invalid_json, {:not_json_encodable, error_message(reason)}}}
    end
  end

  defp validate_schema(_schema, module_name),
    do: {:error, {:invalid_action_spec, module_name, :invalid_parameters_schema}}

  defp normalize_json(%_{} = _struct, path), do: {:error, {:invalid_json, {:struct, path}}}

  defp normalize_json(value, _path)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value}

  defp normalize_json(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, items} ->
      case normalize_json(item, path ++ [index]) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, {:invalid_json, {:improper_list, path}}}
  end

  defp normalize_json(value, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, normalized} ->
      with {:ok, key} <- normalize_json_key(key, path),
           false <- Map.has_key?(normalized, key),
           {:ok, item} <- normalize_json(item, path ++ [key]) do
        {:cont, {:ok, Map.put(normalized, key, item)}}
      else
        true -> {:halt, {:error, {:invalid_json, {:duplicate_key, path, key}}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_json(value, _path) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize_json(_value, path), do: {:error, {:invalid_json, {:unsupported_value, path}}}

  defp normalize_json_key(key, _path) when is_binary(key), do: {:ok, key}
  defp normalize_json_key(key, _path) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_json_key(_key, path), do: {:error, {:invalid_json, {:invalid_key, path}}}

  defp sort_and_validate_names(actions) do
    actions = Enum.sort_by(actions, &Map.fetch!(&1, "name"))

    case duplicate_name(actions) do
      nil -> {:ok, actions}
      name -> {:error, {:duplicate_action_name, name}}
    end
  end

  defp duplicate_name(actions) do
    actions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [left, right] ->
      name = Map.fetch!(left, "name")
      if name == Map.fetch!(right, "name"), do: name
    end)
  end

  defp digest(actions) do
    with {:ok, encoded} <- actions |> canonicalize() |> Jason.encode() do
      digest =
        encoded
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, digest}
    else
      {:error, reason} -> {:error, {:catalog_digest_failed, error_message(reason)}}
    end
  rescue
    exception -> {:error, {:catalog_digest_failed, exception_message(exception)}}
  catch
    kind, reason -> {:error, {:catalog_digest_failed, caught_message(kind, reason)}}
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp exception_message(exception) do
    exception
    |> Exception.message()
    |> bounded_message()
  end

  defp error_message(%{__exception__: true} = exception), do: exception_message(exception)
  defp error_message(reason), do: caught_message(:error, reason)

  defp caught_message(kind, reason) do
    reason =
      inspect(reason,
        limit: 20,
        printable_limit: @max_error_message_bytes,
        width: 80,
        structs: false
      )

    bounded_message("#{kind}: #{reason}")
  end

  defp bounded_message(message) do
    message =
      message
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if byte_size(message) <= @max_error_message_bytes do
      message
    else
      prefix_bytes = @max_error_message_bytes - byte_size("...")

      message
      |> binary_part(0, prefix_bytes)
      |> trim_incomplete_utf8()
      |> Kernel.<>("...")
    end
  end

  defp trim_incomplete_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_incomplete_utf8()
    end
  end

  defp source_shape(value) when is_list(value), do: :list
  defp source_shape(value) when is_map(value), do: :map
  defp source_shape(value) when is_tuple(value), do: :tuple
  defp source_shape(value) when is_atom(value), do: :atom
  defp source_shape(value) when is_binary(value), do: :string
  defp source_shape(_value), do: :other
end
