defmodule Arbor.Agent.Template.File do
  @moduledoc """
  Markdown + YAML-frontmatter file format for agent templates.

  This is the data-first template format: a `.md` file whose YAML frontmatter
  (between `---` fences) carries the *structured* template fields and whose
  Markdown body carries the long *prose* fields as `#`-headed sections.

  The canonical in-memory shape is the string-keyed template data map (the same
  shape `TemplateStore.resolve/1` returns) — so a parsed file can be fed straight
  into `TemplateStore.to_keyword/1`.

  ## Frontmatter (structured)

  - top-level: `name`, `version`, `source`
  - `metadata` (model / provider / context_management / version / category / …)
  - `character`: `name`, `description`, `role`, `tone`, `style`, `traits`,
    `values`, `quirks`, `knowledge` (the structured sub-fields)
  - top-level lists: `values`, `initial_interests`, `initial_thoughts`,
    `initial_goals`, `required_capabilities`
  - `relationship_style` (a flat string→string map)

  ## Markdown body (prose), in this fixed section order

  - `# Description`        → top-level `description`
  - `# Nature`             → `nature`
  - `# Background`         → `character.background`
  - `# Domain Context`     → `domain_context`
  - `# Instructions`       → `character.instructions` (a `-` bullet list)

  The volatile `created_at` / `updated_at` fields are intentionally NOT written
  (they are regenerated on load), so files stay stable and diffable.
  """

  # The structured character sub-fields that live in the frontmatter.
  # `background` and `instructions` are prose → they live in the body.
  @character_frontmatter_keys ~w(name description role tone style traits values quirks knowledge)

  @doc """
  Render a canonical template data map (the `TemplateStore.resolve/1` shape) to a
  Markdown+frontmatter string.
  """
  @spec serialize(map()) :: String.t()
  def serialize(data) when is_map(data) do
    frontmatter = build_frontmatter(data)
    body = build_body(data)

    yaml = emit_yaml(frontmatter)

    "---\n" <> yaml <> "---\n" <> body
  end

  @doc """
  Parse a Markdown+frontmatter string back into the canonical data map
  (string keys, the `TemplateStore.resolve/1` shape), regenerating
  `created_at`/`updated_at`.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(content) when is_binary(content) do
    with {:ok, fm_str, body} <- split_frontmatter(content),
         {:ok, fm} <- YamlElixir.read_from_string(fm_str) do
      {:ok, reconstruct(fm, parse_body(body))}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  @doc """
  Validate a canonical data map. Returns `:ok` or `{:error, [reason]}`.

  Checks required fields are present and well-typed:

  - `character` is a map with a non-empty `name`
  - `initial_goals` each have `type` + `description`
  - `required_capabilities` each have a `resource`
  """
  @spec validate(map()) :: :ok | {:error, [term()]}
  def validate(data) when is_map(data) do
    []
    |> validate_character(data)
    |> validate_goals(data)
    |> validate_capabilities(data)
    |> case do
      [] -> :ok
      reasons -> {:error, Enum.reverse(reasons)}
    end
  end

  defp validate_character(reasons, data) do
    case data["character"] do
      %{} = char ->
        name = char["name"]

        if is_binary(name) and name != "" do
          reasons
        else
          [{:character, :missing_name} | reasons]
        end

      _ ->
        [{:character, :not_a_map} | reasons]
    end
  end

  defp validate_goals(reasons, data) do
    goals = data["initial_goals"] || []

    Enum.reduce(goals, reasons, fn goal, acc ->
      if is_map(goal) and Map.has_key?(goal, "type") and Map.has_key?(goal, "description") do
        acc
      else
        [{:initial_goals, {:malformed, goal}} | acc]
      end
    end)
  end

  defp validate_capabilities(reasons, data) do
    caps = data["required_capabilities"] || []

    Enum.reduce(caps, reasons, fn cap, acc ->
      if is_map(cap) and Map.has_key?(cap, "resource") do
        acc
      else
        [{:required_capabilities, {:malformed, cap}} | acc]
      end
    end)
  end

  # --- Serialize: frontmatter assembly ---

  defp build_frontmatter(data) do
    character = data["character"] || %{}

    character_fm =
      character
      |> Map.take(@character_frontmatter_keys)
      |> reject_empty()

    %{}
    |> put_present("name", data["name"])
    |> put_present("version", data["version"])
    |> put_present("source", data["source"])
    |> put_present("metadata", reject_empty(data["metadata"] || %{}))
    |> put_present("character", character_fm)
    |> put_present("values", data["values"] || [])
    |> put_present("initial_interests", data["initial_interests"] || [])
    |> put_present("initial_thoughts", data["initial_thoughts"] || [])
    |> put_present("initial_goals", data["initial_goals"] || [])
    |> put_present("required_capabilities", data["required_capabilities"] || [])
    |> put_present("relationship_style", reject_empty(data["relationship_style"] || %{}))
  end

  # Only keep a key if the value is non-nil and non-empty (so absent prose
  # fields don't appear and round-trip back as "" — see reconstruct/2 which
  # restores empty defaults).
  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, _key, v) when v == %{}, do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, v), do: Map.put(map, key, v)

  defp reject_empty(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, "", [], %{}] end)
    |> Map.new()
  end

  # --- Serialize: body assembly ---

  defp build_body(data) do
    character = data["character"] || %{}

    sections =
      [
        prose_section("Description", data["description"]),
        prose_section("Nature", data["nature"]),
        prose_section("Background", character["background"]),
        prose_section("Domain Context", data["domain_context"]),
        instructions_section(character["instructions"])
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> ""
      # Each section carries its verbatim value. Sections are joined by exactly
      # one framing newline; the parser's lookahead consumes that newline, so a
      # value's own trailing newline (e.g. from a heredoc) round-trips
      # byte-exact. No file-terminating newline is added for the same reason.
      list -> Enum.join(list, "\n")
    end
  end

  defp prose_section(_header, nil), do: nil
  defp prose_section(_header, ""), do: nil

  # Header line + blank line (fixed framing) + the value VERBATIM (no trim).
  defp prose_section(header, value) when is_binary(value) do
    "# " <> header <> "\n\n" <> value
  end

  defp instructions_section(nil), do: nil
  defp instructions_section([]), do: nil

  defp instructions_section(list) when is_list(list) do
    body = Enum.map_join(list, "\n", &("- " <> &1))
    "# Instructions\n\n" <> body
  end

  # --- Parse: split + body parsing ---

  defp split_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      ["", fm, body] -> {:ok, fm, body}
      _ -> {:error, :missing_frontmatter}
    end
  end

  # Returns a map of section header → verbatim value text.
  #
  # Framing is unambiguous: a section is `# Header\n\n<value>` and sections are
  # joined by exactly one framing `\n`, with no file-terminating newline. The
  # value is captured non-greedily up to the framing newline that precedes the
  # next top-level header (`\n# `) or to EOF (`\z`) — so the framing newline is
  # consumed by the lookahead and the value (including any trailing newline of
  # its own) is captured byte-exact.
  defp parse_body(body) do
    Regex.scan(~r/^# (.+?)\n\n(.*?)(?=\n# |\z)/ms, body, capture: :all_but_first)
    |> Enum.map(fn [header, text] -> {String.trim(header), text} end)
    |> Map.new()
  end

  # --- Parse: reconstruct canonical data map ---

  defp reconstruct(fm, body_sections) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    character =
      (fm["character"] || %{})
      |> Map.put_new("name", fm["name"] || "Unknown")
      |> put_body_prose("background", body_sections["Background"])
      |> put_instructions(body_sections["Instructions"])
      |> ensure_character_defaults()

    %{
      "name" => fm["name"],
      "version" => fm["version"] || 1,
      "source" => fm["source"] || "user",
      "character" => character,
      "sandbox_level" => fm["sandbox_level"],
      "initial_goals" => fm["initial_goals"] || [],
      "required_capabilities" => fm["required_capabilities"] || [],
      "description" => body_sections["Description"] || "",
      "nature" => body_sections["Nature"] || "",
      "values" => fm["values"] || [],
      "initial_interests" => fm["initial_interests"] || [],
      "initial_thoughts" => fm["initial_thoughts"] || [],
      "relationship_style" => fm["relationship_style"] || %{},
      "domain_context" => body_sections["Domain Context"] || "",
      "metadata" => fm["metadata"] || %{},
      "created_at" => now,
      "updated_at" => now
    }
  end

  defp put_body_prose(map, _key, nil), do: map
  defp put_body_prose(map, key, value), do: Map.put(map, key, value)

  defp put_instructions(map, nil), do: Map.put_new(map, "instructions", [])

  defp put_instructions(map, text) do
    instructions =
      text
      |> String.split("\n", trim: true)
      |> Enum.map(&String.replace_prefix(&1, "- ", ""))

    Map.put(map, "instructions", instructions)
  end

  # `Character.to_map/1` always emits every struct field, so a fully-populated
  # character data map has all keys. To round-trip exactly, restore the struct
  # defaults for any character field that was empty (and thus omitted from the
  # frontmatter).
  defp ensure_character_defaults(char) do
    char
    |> Map.put_new("description", nil)
    |> Map.put_new("role", nil)
    |> Map.put_new("background", nil)
    |> Map.put_new("tone", nil)
    |> Map.put_new("style", nil)
    |> Map.put_new("traits", [])
    |> Map.put_new("values", [])
    |> Map.put_new("quirks", [])
    |> Map.put_new("knowledge", [])
    |> Map.put_new("instructions", [])
  end

  # --- Deterministic YAML emitter ---
  #
  # Hand-rolled so output is stable/diffable (sorted keys, consistent quoting).
  # Covers exactly the value shapes our data maps contain: strings, numbers,
  # booleans, lists of scalars, lists of flat maps, and flat maps.

  defp emit_yaml(map) when map_size(map) == 0, do: ""

  defp emit_yaml(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("", fn {k, v} -> emit_kv(k, v, 0) end)
  end

  defp emit_kv(key, value, indent) do
    pad = String.duplicate("  ", indent)

    cond do
      is_map(value) and map_size(value) == 0 ->
        "#{pad}#{key}: {}\n"

      is_map(value) ->
        "#{pad}#{key}:\n" <> emit_map(value, indent + 1)

      value == [] ->
        "#{pad}#{key}: []\n"

      is_list(value) ->
        "#{pad}#{key}:\n" <> emit_list(value, indent)

      true ->
        "#{pad}#{key}: #{emit_scalar(value)}\n"
    end
  end

  defp emit_map(map, indent) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join("", fn {k, v} -> emit_kv(to_string(k), v, indent) end)
  end

  defp emit_list(list, indent) do
    pad = String.duplicate("  ", indent)

    Enum.map_join(list, "", fn
      item when is_map(item) ->
        # First key inline after the dash, rest indented under it.
        pairs = item |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
        emit_list_map(pairs, pad, indent)

      item ->
        "#{pad}- #{emit_scalar(item)}\n"
    end)
  end

  defp emit_list_map([], pad, _indent), do: "#{pad}- {}\n"

  defp emit_list_map(pairs, pad, indent) do
    # Emit each key/value via emit_kv (which handles scalars, nested maps, and
    # lists), then turn the first line's leading indent into the list dash so a
    # list item can carry a nested map value (e.g. a capability `constraints:`
    # block). `pad <> "- "` is the same width as the child indent, keeping the
    # remaining lines aligned.
    child_indent = indent + 1
    child_pad = String.duplicate("  ", child_indent)

    pairs
    |> Enum.map_join("", fn {k, v} -> emit_kv(to_string(k), v, child_indent) end)
    |> String.replace_prefix(child_pad, pad <> "- ")
  end

  defp emit_scalar(value) when is_binary(value), do: quote_string(value)
  defp emit_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp emit_scalar(value) when is_float(value), do: emit_float(value)
  defp emit_scalar(true), do: "true"
  defp emit_scalar(false), do: "false"
  defp emit_scalar(nil), do: "null"
  defp emit_scalar(value) when is_atom(value), do: quote_string(Atom.to_string(value))

  # Floats: avoid trailing ".0"-vs-int ambiguity; print compactly but stably.
  defp emit_float(value) do
    str = Float.to_string(value)
    str
  end

  # Always double-quote strings and escape internal quotes/backslashes/newlines.
  # This keeps emission unambiguous regardless of content (colons, leading
  # special chars, multi-line prose accidentally landing in frontmatter, etc.).
  defp quote_string(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end
end
