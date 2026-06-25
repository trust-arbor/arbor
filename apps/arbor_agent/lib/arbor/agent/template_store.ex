defmodule Arbor.Agent.TemplateStore do
  @moduledoc """
  File-backed template storage with ETS caching.

  ## Resolution precedence (Phase B1 — file-first, fallback-safe)

  When a template is resolved by name, the layers are tried in order and the
  first hit wins:

    1. **user**        `<user_templates_dir>/<name>.md`  (Markdown+frontmatter)
    2. **shipped**     `<priv>/templates/<name>.md`        (Markdown+frontmatter)
    3. **legacy_json** `<legacy_dir>/<name>.json`          (the old JSON store)
    4. **module**      `from_module/1`                      (per-persona modules)

  Layers 1–3 are loaded into the ETS cache by `reload/0` (user winning over
  shipped, and `.md` winning over legacy `.json`). Layer 4 is the final fallback
  in `resolve/1` for names that have no file at all.

  Every resolved template carries `data["template_source"]` provenance:
  `%{"name" => name, "path" => abs_path_or_nil, "layer" => layer}` where layer is
  one of `"user" | "shipped" | "legacy_json" | "module"`.

  `put/2`, `update/2`, and `create_from_opts/2` still write user JSON files into
  the legacy dir (the writable layer); they update the ETS cache too. Use
  `reload/0` after manual edits.

  Builtin templates ship as `.md` files in `priv/templates/` and remain backed by
  per-persona modules as a final fallback. They can be overridden by a user `.md`
  but not deleted.
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
    Arbor.Agent.Templates.Conversationalist => "conversationalist",
    Arbor.Agent.Templates.InterviewAgent => "interview_agent",
    Arbor.Agent.Templates.ApiAgent => "api_agent",
    Arbor.Agent.Templates.CouncilEvaluator => "council_evaluator"
  }

  @builtin_names Map.values(@builtin_modules)

  # --- ETS Management ---

  @doc "Ensure the ETS table exists."
  def ensure_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        try do
          :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> @ets_table
        end

      _ref ->
        @ets_table
    end
  end

  # --- CRUD API ---

  @doc "Get a template by name (file-first: user .md → shipped .md → legacy .json)."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    ensure_table()

    case :ets.lookup(@ets_table, name) do
      [{^name, data}] ->
        {:ok, data}

      [] ->
        case load_layered(name) do
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
      [] -> match?({:ok, _}, load_layered(name))
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

  @doc """
  Reload all templates from disk into ETS, layering source dirs.

  Load order (later overwrites earlier in ETS, so the LAST writer wins):

    1. legacy `.json` files in the writable/legacy dir
    2. shipped `.md` files in `priv/templates/`
    3. user `.md` files in `user_templates_dir/0`

  Net precedence: **user .md > shipped .md > legacy .json**. The module layer is
  not loaded here — it is the final fallback in `resolve/1` for names that have
  no file in any dir.
  """
  @spec reload() :: :ok
  def reload do
    ensure_table()

    # 1. Legacy JSON (lowest precedence) — load first so .md overwrites it.
    load_dir_into_ets(legacy_templates_dir(), ".json", "legacy_json")

    # 2. Shipped .md
    load_dir_into_ets(shipped_templates_dir(), ".md", "shipped")

    # 3. User .md (highest precedence) — loaded last, overwrites the rest.
    load_dir_into_ets(user_templates_dir(), ".md", "user")

    :ok
  end

  @doc "Reload a single template from disk (re-runs the layered lookup)."
  @spec reload(String.t()) :: {:ok, map()} | {:error, term()}
  def reload(name) when is_binary(name) do
    ensure_table()

    case load_layered(name) do
      {:ok, data} ->
        :ets.insert(@ets_table, {name, data})
        {:ok, data}

      error ->
        error
    end
  end

  # Load every `<name><ext>` file in `dir` into ETS, tagging each with the
  # given provenance layer. No-op when the dir is missing. The legacy dir may
  # equal a `.md` dir under a test override — that is harmless because the
  # extension filter keeps the file types separate.
  defp load_dir_into_ets(dir, ext, layer) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ext))
      |> Enum.each(fn filename ->
        name = String.trim_trailing(filename, ext)
        path = Path.join(dir, filename)

        case load_file_at(path, ext) do
          {:ok, data} ->
            :ets.insert(@ets_table, {name, with_source(data, name, path, layer)})

          {:error, _} ->
            :ok
        end
      end)
    end

    :ok
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
        # Final fallback: load directly from the module definition.
        if Code.ensure_loaded?(module) and function_exported?(module, :character, 0) do
          data = with_source(from_module(module), name, nil, "module")
          # Cache in ETS only (do NOT write a JSON file) — the module IS the
          # source of truth for this fallback path; writing a .json would
          # silently shadow a later-added shipped/user .md.
          ensure_table()
          :ets.insert(@ets_table, {name, data})
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
          String.to_existing_atom(tier)

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
      meta_awareness:
        %{
          grown_from_template: true,
          template_name: character.name,
          note: "These initial values came from a template. You can question them."
        }
        |> maybe_put_meta_source(data["template_source"])
    ]
  end

  # Surface template provenance in meta_awareness when the data map carries it
  # (resolve/1 attaches it; raw from_module/1 output does not).
  defp maybe_put_meta_source(meta, %{} = source) when map_size(source) > 0 do
    Map.put(meta, :template_source, source)
  end

  defp maybe_put_meta_source(meta, _), do: meta

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
      "required_capabilities" =>
        stringify_keys_list(Keyword.get(opts, :required_capabilities, [])),
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

  @doc """
  Return the legacy/writable templates directory (the `.json` store).

  This is also the directory `put/2`, `update/2`, and `create_from_opts/2`
  write to. A test override set via `set_templates_dir/1` takes precedence.
  """
  @spec templates_dir() :: String.t()
  def templates_dir, do: legacy_templates_dir()

  @doc """
  Directory of user-editable `.md` templates (highest resolution precedence).

  Defaults to `~/.arbor/templates` (configurable via
  `config :arbor_agent, :user_templates_dir`). A test override set via
  `set_templates_dir/1` takes precedence — so tests can point this at a tmp
  dir and never touch the real home directory.
  """
  @spec user_templates_dir() :: String.t()
  def user_templates_dir do
    case Process.get(:arbor_template_dir_override) do
      nil ->
        :arbor_agent
        |> Application.get_env(:user_templates_dir, "~/.arbor/templates")
        |> Path.expand()

      dir ->
        dir
    end
  end

  @doc """
  Directory of shipped `.md` templates baked into the release
  (`priv/templates/`). Read-only at runtime.
  """
  @spec shipped_templates_dir() :: String.t()
  def shipped_templates_dir do
    Path.join(:code.priv_dir(:arbor_agent), "templates")
  end

  # Legacy JSON store (lowest file-layer precedence). Honors the test override.
  defp legacy_templates_dir do
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

  # File-first layered single-name lookup: user .md → shipped .md → legacy .json.
  # The module layer is NOT tried here (it lives in resolve/1) so `get/1` stays a
  # pure file lookup. Each hit is tagged with its provenance via with_source/4.
  defp load_layered(name) do
    layers = [
      {Path.join(user_templates_dir(), "#{name}.md"), ".md", "user"},
      {Path.join(shipped_templates_dir(), "#{name}.md"), ".md", "shipped"},
      {Path.join(legacy_templates_dir(), "#{name}.json"), ".json", "legacy_json"}
    ]

    Enum.reduce_while(layers, {:error, :not_found}, fn {path, ext, layer}, acc ->
      case load_file_at(path, ext) do
        {:ok, data} -> {:halt, {:ok, with_source(data, name, path, layer)}}
        {:error, :not_found} -> {:cont, acc}
        # A malformed file should not silently fall through to a lower layer —
        # surface the error so the operator notices the bad file.
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Read + parse a single template file by extension. Returns {:error, :not_found}
  # when the file is absent so the layered reducer can fall through.
  defp load_file_at(path, ext) do
    case File.read(path) do
      {:ok, content} -> decode_template(content, ext)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp decode_template(content, ".md") do
    case Template.File.parse(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_markdown, reason}}
    end
  end

  defp decode_template(content, ".json") do
    case Jason.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # Attach provenance so a created agent can persist where its template came from.
  defp with_source(data, name, path, layer) when is_map(data) do
    Map.put(data, "template_source", %{
      "name" => name,
      "path" => path,
      "layer" => layer
    })
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

  defp stringify_value(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

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
