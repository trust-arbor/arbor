defmodule Arbor.Agent.TemplateStore do
  @moduledoc """
  File-backed template storage with ETS caching.

  Templates are stored as JSON files in `.arbor/templates/`, one file per template.
  An ETS table provides fast runtime lookup. Files are the source of truth —
  use `reload/0` after manual edits.

  Builtin templates are seeded from module definitions on first boot. They can be
  edited in-place but not deleted.
  """

  alias Arbor.Agent.{Character, Template}

  @ets_table :arbor_agent_templates
  @templates_dir ".arbor/templates"

  # Builtin module → name mapping
  @builtin_modules %{
    Arbor.Agent.Templates.CliAgent => "cli_agent",
    Arbor.Agent.Templates.Scout => "scout",
    Arbor.Agent.Templates.Researcher => "researcher",
    Arbor.Agent.Templates.CodeReviewer => "code_reviewer",
    Arbor.Agent.Templates.Monitor => "monitor",
    Arbor.Agent.Templates.Diagnostician => "diagnostician",
    Arbor.Agent.Templates.Conversationalist => "conversationalist"
  }

  @builtin_names Map.values(@builtin_modules)

  # --- ETS Management ---

  @doc "Ensure the ETS table exists."
  def ensure_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

      _ref ->
        @ets_table
    end
  end

  # --- CRUD API ---

  @doc "Get a template by name."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    ensure_table()

    case :ets.lookup(@ets_table, name) do
      [{^name, data}] ->
        {:ok, data}

      [] ->
        case load_from_file(name) do
          {:ok, data} ->
            :ets.insert(@ets_table, {name, data})
            {:ok, data}

          error ->
            error
        end
    end
  end

  @doc "Store a template by name. Writes JSON file and updates ETS cache."
  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(name, data) when is_binary(name) and is_map(data) do
    ensure_table()
    data = Map.put(data, "name", name)

    case write_to_file(name, data) do
      :ok ->
        :ets.insert(@ets_table, {name, data})
        :ok

      error ->
        error
    end
  end

  @doc "Delete a template. Refuses to delete builtin templates."
  @spec delete(String.t()) :: :ok | {:error, :builtin_protected}
  def delete(name) when is_binary(name) do
    if name in @builtin_names do
      {:error, :builtin_protected}
    else
      ensure_table()
      :ets.delete(@ets_table, name)
      path = template_path(name)
      if File.exists?(path), do: File.rm(path)
      :ok
    end
  end

  @doc "List all available templates."
  @spec list() :: [map()]
  def list do
    ensure_table()
    reload()

    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_name, data} -> data end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc "Check if a template exists."
  @spec exists?(String.t()) :: boolean()
  def exists?(name) when is_binary(name) do
    ensure_table()

    case :ets.lookup(@ets_table, name) do
      [{^name, _}] -> true
      [] -> File.exists?(template_path(name))
    end
  end

  @doc "Update a template by merging changes. Bumps version and updated_at."
  @spec update(String.t(), map()) :: :ok | {:error, term()}
  def update(name, changes) when is_binary(name) and is_map(changes) do
    case get(name) do
      {:ok, existing} ->
        updated =
          Map.merge(existing, changes)
          |> Map.put("version", (existing["version"] || 0) + 1)
          |> Map.put("updated_at", DateTime.to_iso8601(DateTime.utc_now()))

        put(name, updated)

      {:error, _} = error ->
        error
    end
  end

  # --- Reload ---

  @doc "Reload all templates from disk into ETS."
  @spec reload() :: :ok
  def reload do
    ensure_table()
    dir = templates_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.each(fn filename ->
        name = String.trim_trailing(filename, ".json")

        case load_from_file(name) do
          {:ok, data} -> :ets.insert(@ets_table, {name, data})
          {:error, _} -> :ok
        end
      end)
    end

    :ok
  end

  @doc "Reload a single template from disk."
  @spec reload(String.t()) :: {:ok, map()} | {:error, term()}
  def reload(name) when is_binary(name) do
    ensure_table()

    case load_from_file(name) do
      {:ok, data} ->
        :ets.insert(@ets_table, {name, data})
        {:ok, data}

      error ->
        error
    end
  end

  # --- Seeding ---

  @doc "Seed builtin templates from module definitions. Idempotent — skips existing files."
  @spec seed_builtins() :: {:ok, non_neg_integer()}
  def seed_builtins do
    ensure_table()
    dir = templates_dir()
    File.mkdir_p!(dir)

    count =
      @builtin_modules
      |> Enum.count(fn {module, name} ->
        path = template_path(name)

        if File.exists?(path) do
          false
        else
          if Code.ensure_loaded?(module) do
            data = from_module(module)
            write_to_file(name, data) == :ok
          else
            false
          end
        end
      end)

    # Load all into ETS
    reload()
    {:ok, count}
  end

  # --- Resolution ---

  @doc "Resolve a template by name (string) or module atom."
  @spec resolve(atom() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolve(name) when is_binary(name), do: get(name)

  def resolve(module) when is_atom(module) do
    name = module_to_name(module)

    case get(name) do
      {:ok, _} = ok ->
        ok

      {:error, :not_found} ->
        # Fallback: try loading directly from module
        if Code.ensure_loaded?(module) and function_exported?(module, :character, 0) do
          data = from_module(module)
          put(name, data)
          {:ok, data}
        else
          {:error, :not_found}
        end
    end
  end

  # --- Name Mapping ---

  @doc "Convert a template module to its name slug."
  @spec module_to_name(atom()) :: String.t()
  def module_to_name(module) when is_atom(module) do
    case Map.get(@builtin_modules, module) do
      nil ->
        module
        |> Module.split()
        |> List.last()
        |> Macro.underscore()

      name ->
        name
    end
  end

  @doc "Convert a template name to its builtin module (if any)."
  @spec name_to_module(String.t()) :: atom() | nil
  def name_to_module(name) when is_binary(name) do
    inverse = Map.new(@builtin_modules, fn {mod, n} -> {n, mod} end)
    Map.get(inverse, name)
  end

  @doc "Normalize a template reference (atom or string) to a name string."
  @spec normalize_ref(atom() | String.t() | nil) :: String.t() | nil
  def normalize_ref(nil), do: nil
  def normalize_ref(name) when is_binary(name), do: name
  def normalize_ref(module) when is_atom(module), do: module_to_name(module)

  # --- Conversion ---

  @doc "Convert a template module to a data map."
  @spec from_module(module()) :: map()
  def from_module(module) when is_atom(module) do
    kw = Template.apply(module)
    now = DateTime.to_iso8601(DateTime.utc_now())
    name = module_to_name(module)

    %{
      "name" => name,
      "version" => 1,
      "source" => if(module in Map.keys(@builtin_modules), do: "builtin", else: "user"),
      "character" => character_to_map(kw[:character]),
      "trust_tier" => to_string(kw[:trust_tier]),
      "initial_goals" => stringify_keys_list(kw[:initial_goals] || []),
      "required_capabilities" => stringify_keys_list(kw[:required_capabilities] || []),
      "description" => kw[:description] || "",
      "nature" => kw[:nature] || "",
      "values" => kw[:values] || [],
      "initial_interests" => kw[:interests] || [],
      "initial_thoughts" => kw[:initial_thoughts] || [],
      "relationship_style" => stringify_keys(kw[:relationship_style] || %{}),
      "domain_context" => kw[:domain_context] || "",
      "metadata" => stringify_keys(kw[:metadata] || %{}),
      "created_at" => now,
      "updated_at" => now
    }
  end

  @doc "Convert a stored template data map to the keyword list format used by Lifecycle."
  @spec to_keyword(map()) :: keyword()
  def to_keyword(data) when is_map(data) do
    character = Character.from_map(data["character"] || %{"name" => data["name"] || "Unknown"})

    trust_tier =
      case data["trust_tier"] do
        tier when tier in ~w(untrusted probationary trusted established veteran autonomous) ->
          String.to_atom(tier)

        tier when is_atom(tier) and not is_nil(tier) ->
          tier

        _ ->
          :untrusted
      end

    [
      name: character.name,
      character: character,
      trust_tier: trust_tier,
      initial_goals: data["initial_goals"] || [],
      required_capabilities: data["required_capabilities"] || [],
      nature: data["nature"] || "",
      values: data["values"] || [],
      interests: data["initial_interests"] || [],
      initial_thoughts: data["initial_thoughts"] || [],
      relationship_style: data["relationship_style"] || %{},
      domain_context: data["domain_context"] || "",
      description: data["description"] || "",
      metadata: data["metadata"] || %{},
      meta_awareness: %{
        grown_from_template: true,
        template_name: character.name,
        note: "These initial values came from a template. You can question them."
      }
    ]
  end

  @doc "Create a template from keyword opts (convenience for programmatic creation)."
  @spec create_from_opts(String.t(), keyword()) :: :ok | {:error, term()}
  def create_from_opts(name, opts) when is_binary(name) do
    character =
      case Keyword.get(opts, :character) do
        %Character{} = c -> character_to_map(c)
        %{} = m -> stringify_keys(m)
        nil -> %{"name" => name}
      end

    now = DateTime.to_iso8601(DateTime.utc_now())

    data = %{
      "name" => name,
      "version" => 1,
      "source" => "user",
      "character" => character,
      "trust_tier" => to_string(Keyword.get(opts, :trust_tier, :probationary)),
      "initial_goals" => stringify_keys_list(Keyword.get(opts, :initial_goals, [])),
      "required_capabilities" => stringify_keys_list(Keyword.get(opts, :required_capabilities, [])),
      "description" => Keyword.get(opts, :description, ""),
      "nature" => Keyword.get(opts, :nature, ""),
      "values" => Keyword.get(opts, :values, []),
      "initial_interests" => Keyword.get(opts, :initial_interests, []),
      "initial_thoughts" => Keyword.get(opts, :initial_thoughts, []),
      "relationship_style" => stringify_keys(Keyword.get(opts, :relationship_style, %{})),
      "domain_context" => Keyword.get(opts, :domain_context, ""),
      "metadata" => stringify_keys(Keyword.get(opts, :metadata, %{})),
      "created_at" => now,
      "updated_at" => now
    }

    put(name, data)
  end

  @doc "Return the list of builtin template names."
  @spec builtin_names() :: [String.t()]
  def builtin_names, do: @builtin_names

  @doc "Return the templates directory path."
  @spec templates_dir() :: String.t()
  def templates_dir do
    case Process.get(:arbor_template_dir_override) do
      nil ->
        root = project_root()
        Path.join(root, @templates_dir)

      dir ->
        dir
    end
  end

  @doc "Override the templates directory (for testing only)."
  @spec set_templates_dir(String.t()) :: :ok
  def set_templates_dir(dir) do
    Process.put(:arbor_template_dir_override, dir)
    :ok
  end

  @doc "Clear the templates directory override."
  @spec clear_templates_dir_override() :: :ok
  def clear_templates_dir_override do
    Process.delete(:arbor_template_dir_override)
    :ok
  end

  @doc "Check if TemplateStore is available (ETS table exists)."
  @spec available?() :: boolean()
  def available? do
    :ets.whereis(@ets_table) != :undefined
  end

  # --- Private ---

  defp template_path(name) do
    Path.join(templates_dir(), "#{name}.json")
  end

  defp load_from_file(name) do
    path = template_path(name)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp write_to_file(name, data) do
    dir = templates_dir()
    File.mkdir_p!(dir)
    path = template_path(name)

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  end

  defp character_to_map(%Character{} = char) do
    char
    |> Character.to_map()
    |> stringify_keys()
  end

  defp character_to_map(map) when is_map(map), do: stringify_keys(map)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_keys(other), do: other

  defp stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp stringify_value(other), do: other

  defp stringify_keys_list(list) when is_list(list) do
    Enum.map(list, fn
      map when is_map(map) -> stringify_keys(map)
      other -> other
    end)
  end

  defp project_root do
    # Try common approaches for finding project root
    cond do
      # In umbrella context, mix.exs is at root
      File.exists?(Path.join(File.cwd!(), "mix.exs")) and
          File.exists?(Path.join(File.cwd!(), "apps")) ->
        File.cwd!()

      # We might be in an app dir during tests
      File.exists?(Path.join([File.cwd!(), "..", "..", "mix.exs"])) ->
        Path.expand(Path.join([File.cwd!(), "..", ".."]))

      true ->
        File.cwd!()
    end
  end
end
