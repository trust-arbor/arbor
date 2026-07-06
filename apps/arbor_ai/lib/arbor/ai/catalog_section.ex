defmodule Arbor.AI.CatalogSection do
  @moduledoc """
  Kind-parameterized progressive-disclosure catalog for the system prompt.

  Injects a compact, byte-capped, config-gated catalog of *names + one-line
  purposes* for a capability kind (`:skill`, `:action`, and — designed but not
  yet wired — `:pipeline`). The model sees WHAT exists and selects what it can
  see, instead of searching a hidden catalog and guessing.

  This is the proven skill-catalog pattern hoisted up one level so tools and
  skills share it. It fixes the `tool_find_tools` discovery loop: discovery was
  "search against a hidden catalog," which forces re-querying when the guess is
  wrong; a visible catalog turns it into "select from what you can see."

  ## Kinds

  Each kind maps to `{header, activate/call instruction, list source, per-kind
  config gate}`:

  - `:skill` — `# Available Skills`, gated by `:skills` (per-agent) /
    `:skill_catalog_enabled` (system). List source: `Arbor.Common.SkillLibrary`.
  - `:action` — `# Available Tools`, gated by `:tools` (per-agent) /
    `:tool_catalog_enabled` (system, defaults ON). List source:
    `Arbor.Actions.all_tools/0` via the runtime bridge (see `entries/1`).

  `:pipeline` is the designed third call site (the resolver already indexes
  `:pipeline`); add a `@kinds` entry + `entries(:pipeline)` clause when the
  pipeline registry exposes a name+description list. Nothing else changes.

  Every path is rescue-safe: catalog assembly must never break prompt building.
  """

  alias Arbor.Common.{LazyLoader, SkillLibrary}

  # Per-kind config: header, activate/call instruction, per-agent opts key +
  # system flag gate, byte-cap for the whole bullet body, and an optional
  # per-entry purpose char cap.
  #
  # - skills: few entries with short descriptions → keep the original 4k body
  #   cap and the FULL first-line description (`purpose_max: nil`) so the skill
  #   catalog renders byte-for-byte as it did before extraction.
  # - actions: ~172 tools → a 4k body cap would silently hide core tools like
  #   file_read (the flat tool ordering puts file ops near the END, after
  #   security_*), which reintroduces the discovery loop for whatever got cut.
  #   The fix's whole value is that NO callable tool is hidden, so size the cap
  #   to fit the full set: trimming each purpose to ≤`purpose_max` chars puts the
  #   172-tool body at ~12.2k bytes (~3k cacheable tokens), and a 13k cap shows
  #   all of it with headroom. If the tool count grows materially, bump
  #   `max_bytes` (or prioritize core tools first) so late tools stay visible —
  #   truncation is graceful (marker + the runaway guard backstop), but a hidden
  #   tool is exactly the bug.
  @kinds %{
    skill: %{
      header: "# Available Skills",
      instruction: "Activate any of these with the skill tool to load its full guidance:",
      opts_key: :skills,
      system_flag: :skill_catalog_enabled,
      max_bytes: 4_000,
      purpose_max: nil
    },
    action: %{
      header: "# Available Tools",
      instruction:
        "These tools are callable directly. Only use tool_find_tools to discover something NOT listed here:",
      opts_key: :tools,
      system_flag: :tool_catalog_enabled,
      # Generous BACKSTOP, not a routine truncation: ~172 tools ≈ 12.2k today, so 32k leaves
      # headroom for growth and keeps ALL tools visible (a truncated catalog re-hides tools and
      # reintroduces the discovery loop the catalog exists to remove). If it ever does truncate,
      # truncate_catalog/2 degrades gracefully to "use discovery for the rest". Eventually this
      # should derive from the model's usable window — see
      # .arbor/roadmap/0-inbox/tool-discovery-loop-fix.md ("Catalog sizing").
      max_bytes: 32_000,
      purpose_max: 48
    }
  }

  @doc """
  Build the prompt section for `kind`, or `""` when disabled, empty, or unknown.

  ## Options

  - `<opts_key>` — per-agent override (`:enabled` / `:disabled` / `:inherit`);
    `:inherit` (or absent) falls back to the system config flag.
  """
  @spec build(atom(), keyword()) :: String.t()
  def build(kind, opts) do
    case Map.fetch(@kinds, kind) do
      {:ok, cfg} -> build_kind(kind, cfg, opts)
      :error -> ""
    end
  end

  defp build_kind(kind, cfg, opts) do
    if context_enabled?(opts, cfg.opts_key, cfg.system_flag) do
      kind
      |> entries()
      |> Enum.reject(fn {name, _desc} -> name in [nil, ""] end)
      |> format_catalog(cfg)
    else
      ""
    end
  rescue
    # Catalog assembly must never break prompt building.
    _ -> ""
  end

  # ── Per-kind list sources ──────────────────────────────────────────
  #
  # Skills live in arbor_common (a compile-time dep — call directly). Tools live
  # in arbor_actions (L6), which is ABOVE arbor_ai (L4) and DEPENDS ON it, so a
  # compile-time call would be a dependency cycle + a hierarchy violation. Reach
  # it through the runtime bridge (module-in-a-variable + `apply`, the same
  # pattern this library uses for Arbor.Agent.* and Arbor.Memory.*): returns []
  # when arbor_actions isn't loaded in the current BEAM (e.g. arbor_ai's own
  # isolated test suite), and the drift-guard sees no new mix.exs dep.
  defp entries(:skill) do
    SkillLibrary.list()
    |> Enum.map(fn skill -> {Map.get(skill, :name), Map.get(skill, :description)} end)
  end

  defp entries(:action) do
    actions = Arbor.Actions

    if LazyLoader.exported?(actions, :all_tools, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      actions
      |> apply(:all_tools, [])
      |> Enum.map(fn tool -> {Map.get(tool, :name), Map.get(tool, :description)} end)
    else
      []
    end
  end

  # ── Formatting ─────────────────────────────────────────────────────

  defp format_catalog([], _cfg), do: ""

  defp format_catalog(entries, cfg) do
    body =
      entries
      |> Enum.map_join("\n", fn {name, desc} ->
        "- **#{name}**: #{purpose(desc, cfg.purpose_max)}"
      end)
      |> truncate_catalog(cfg.max_bytes)

    "#{cfg.header}\n\n#{cfg.instruction}\n\n" <> body
  end

  # First line of the description, optionally trimmed to a compact purpose.
  defp purpose(desc, purpose_max), do: desc |> one_line() |> truncate_purpose(purpose_max)

  defp one_line(nil), do: ""
  defp one_line(desc), do: desc |> String.split("\n", parts: 2) |> hd() |> String.trim()

  # Character-based (UTF-8 safe) — `max` is a grapheme count, not bytes.
  defp truncate_purpose(text, nil), do: text

  defp truncate_purpose(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"
  end

  defp truncate_catalog(body, max_bytes) when byte_size(body) <= max_bytes, do: body

  # Graceful overflow: NEVER silently hide. Tell the model more items exist and to discover the
  # rest, so a truncation degrades to search (its correct role — the rare tail) instead of
  # re-creating the hidden-catalog loop the catalog exists to remove.
  defp truncate_catalog(body, max_bytes) do
    binary_part(body, 0, max_bytes) <>
      "\n…(catalog truncated — more items exist; use your discovery/search tool to find any not listed above)"
  end

  # Per-agent :enabled/:disabled override the system flag; :inherit (or nil)
  # uses the system config flag under :arbor_common.
  defp context_enabled?(opts, opts_key, system_flag) do
    case Keyword.get(opts, opts_key, :inherit) do
      :enabled -> true
      :disabled -> false
      _ -> Application.get_env(:arbor_common, system_flag, false)
    end
  end
end
