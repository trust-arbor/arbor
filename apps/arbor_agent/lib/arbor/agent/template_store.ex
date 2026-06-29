defmodule Arbor.Agent.TemplateStore do
  @moduledoc """
  File-backed template storage with ETS caching.

  ## Resolution precedence (Phase B2 — data-first, file is the source of truth)

  When a template is resolved by name, the layers are tried in order and the
  first hit wins:

    1. **user**        `<user_templates_dir>/<name>.md`  (Markdown+frontmatter)
    2. **shipped**     `<priv>/templates/<name>.md`        (Markdown+frontmatter)
    3. **legacy_json** `<legacy_dir>/<name>.json`          (the old JSON store)

  All three layers are loaded into the ETS cache by `reload/0` (user winning over
  shipped, and `.md` winning over legacy `.json`). There is no longer a module
  fallback — the per-persona template modules were deleted in Phase B2; the
  shipped `.md` files in `priv/templates/` ARE the source of truth.

  Every resolved template carries `data["template_source"]` provenance:
  `%{"name" => name, "path" => abs_path_or_nil, "layer" => layer}` where layer is
  one of `"user" | "shipped" | "legacy_json"`.

  `put/2`, `update/2`, and `create_from_opts/2` still write user JSON files into
  the legacy dir (the writable layer); they update the ETS cache too. Use
  `reload/0` after manual edits.

  Builtin templates ship as `.md` files in `priv/templates/`. `builtin_names/0`
  derives the builtin set from the basenames of those shipped files. They can be
  overridden by a user `.md` but not deleted.
  """

  alias Arbor.Agent.Character

  @ets_table :arbor_agent_templates
  @templates_dir ".arbor/templates"

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
    if name in builtin_names() do
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

  # --- Resolution ---

  @doc """
  Resolve a template by name (string) or — for stray atom callers — by module.

  The string clause is the canonical path: file-first layered lookup. The atom
  clause is a back-compat convenience for any caller still passing a module
  atom (e.g. a legacy `Arbor.Agent.Templates.Scout`); it inflects the atom's
  last segment into a slug name and delegates to the string path. There is no
  module fallback — the per-persona modules were deleted in Phase B2.
  """
  @spec resolve(atom() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def resolve(name) when is_binary(name), do: get(name)

  def resolve(module) when is_atom(module) do
    resolve(module_to_name(module))
  end

  # --- Name Mapping ---

  @doc """
  Convert a template module atom to its name slug by inflecting the last
  module segment (e.g. `Arbor.Agent.Templates.CodeReviewer` -> `"code_reviewer"`).
  Kept for stray atom callers; the modules themselves no longer exist.
  """
  @spec module_to_name(atom()) :: String.t()
  def module_to_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @doc "Normalize a template reference (atom or string) to a name string."
  @spec normalize_ref(atom() | String.t() | nil) :: String.t() | nil
  def normalize_ref(nil), do: nil
  def normalize_ref(name) when is_binary(name), do: name
  def normalize_ref(module) when is_atom(module), do: module_to_name(module)

  # --- Conversion ---

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
      sandbox_level: Arbor.Contracts.Security.SandboxLevel.coerce(data["sandbox_level"]),
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
  # (resolve/1 attaches it; a raw data map without a resolved source does not).
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

  @doc """
  Return the list of builtin template names.

  Derived from the basenames of the shipped `.md` files in
  `shipped_templates_dir/0` (the source of truth for builtins). Sorted for
  stable output. Returns `[]` if the shipped dir is somehow absent.
  """
  @spec builtin_names() :: [String.t()]
  def builtin_names do
    dir = shipped_templates_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(&String.trim_trailing(&1, ".md"))
      |> Enum.sort()
    else
      []
    end
  end

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
    case Arbor.Agent.Template.File.parse(content) do
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
