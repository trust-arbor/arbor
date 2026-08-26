defmodule Mix.Tasks.Arbor.Doctor.ProviderPicker do
  @moduledoc """
  Pure core for the interactive provider picker in `mix arbor.doctor --configure`.

  Builds the numbered menu, renders it, and parses what the operator typed.
  No IO here — `Mix.Tasks.Arbor.Doctor` prints the menu and reads the answer,
  so this module is unit-testable without a TTY.

  The menu lists, in the doctor's priority order:

    * every *ready* provider (the first one is the recommended default), then
    * every provider that is missing **only** an API key — chosen, the doctor
      prompts for the key, writes it to `.env`, and configures that provider.

  Accepted answers:

    * empty — the recommended (first ready) option
    * a menu number — `2`
    * a provider name — the catalog key (`lm_studio`) or the config atom
      (`lmstudio`), case-insensitive
  """

  @type option :: %{
          index: pos_integer(),
          catalog_key: String.t(),
          config_atom: atom(),
          llmdb_atom: atom(),
          display_name: String.t(),
          acp_agent: String.t() | nil,
          recommended?: boolean(),
          needs_key: String.t() | nil
        }

  @doc """
  Menu options for the catalog `entries`, ordered by `priority` (the doctor's
  `@provider_priority` triples): ready providers first, then those whose only
  blocker is a single missing API key (offered with `needs_key` set to the env
  var name). Entries the doctor cannot configure are not offered.
  """
  @spec options([map()], [{String.t(), atom(), atom()}], keyword()) :: [option()]
  def options(entries, priority, opts \\ []) do
    by_key = Map.new(entries, &{&1.provider, &1})
    acp_agents = Keyword.get(opts, :acp_agents, [])

    offered =
      for {catalog_key, config_atom, llmdb_atom} <- priority,
          entry = by_key[catalog_key],
          entry != nil,
          offer = offer_kind(entry),
          offer != :skip,
          expanded <- expand(offer, catalog_key, config_atom, llmdb_atom, entry, acp_agents) do
        expanded
      end

    ready = Enum.filter(offered, &match?({:ready, _, _, _, _, _}, &1))
    keyed = Enum.filter(offered, &match?({{:needs_key, _}, _, _, _, _, _}, &1))

    (ready ++ keyed)
    |> Enum.with_index(1)
    |> Enum.map(fn {{offer, catalog_key, config_atom, llmdb_atom, display_name, acp_agent}, index} ->
      %{
        index: index,
        catalog_key: catalog_key,
        config_atom: config_atom,
        llmdb_atom: llmdb_atom,
        display_name: display_name,
        acp_agent: acp_agent,
        recommended?: index == 1 and offer == :ready,
        needs_key:
          case offer do
            {:needs_key, var} -> var
            :ready -> nil
          end
      }
    end)
  end

  # ACP is one catalog entry but several possible agents (Claude Code, Codex,
  # Gemini CLI, …). When the doctor tells us which are installed, offer one row
  # per agent — in the order given, which is the doctor's quality preference —
  # so the operator picks the agent, not just "ACP".
  defp expand(:ready, "acp", config_atom, llmdb_atom, _entry, [_ | _] = agents) do
    Enum.map(agents, fn agent ->
      {:ready, "acp", config_atom, llmdb_atom, "ACP: #{agent_display_name(agent)}", agent}
    end)
  end

  defp expand(offer, catalog_key, config_atom, llmdb_atom, entry, _agents) do
    [
      {offer, catalog_key, config_atom, llmdb_atom, Map.get(entry, :display_name) || catalog_key,
       nil}
    ]
  end

  @agent_display_names %{
    "claude" => "Claude Code",
    "codex" => "Codex",
    "gemini" => "Gemini CLI",
    "goose" => "Goose",
    "aider" => "Aider",
    "opencode" => "OpenCode",
    "cline" => "Cline",
    "grok" => "Grok CLI",
    "cursor" => "Cursor"
  }

  @doc "Human name for an ACP agent id (`\"claude\"` → `\"Claude Code\"`)."
  @spec agent_display_name(String.t()) :: String.t()
  def agent_display_name(agent), do: Map.get(@agent_display_names, agent, agent)

  @doc """
  What the menu can do with a catalog entry: `:ready`, `{:needs_key, "VAR"}`
  when a single missing env var is the only failed check, else `:skip`.
  """
  @spec offer_kind(map()) :: :ready | {:needs_key, String.t()} | :skip
  def offer_kind(%{available?: true}), do: :ready

  def offer_kind(%{check_result: {:error, [{:env_vars, {:missing, missing, _}}]}}) do
    case missing do
      var when is_binary(var) -> {:needs_key, var}
      [%{name: var}] when is_binary(var) -> {:needs_key, var}
      [var] when is_binary(var) -> {:needs_key, var}
      _ -> :skip
    end
  end

  def offer_kind(_entry), do: :skip

  @doc "Renders the numbered menu."
  @spec render([option()]) :: String.t()
  def render(options) do
    width = options |> Enum.map(&String.length(&1.display_name)) |> Enum.max(fn -> 0 end)

    lines =
      Enum.map(options, fn option ->
        name = String.pad_trailing(option.display_name, width)

        tag =
          cond do
            option.recommended? -> "  (recommended)"
            option.needs_key -> "  (needs #{option.needs_key})"
            true -> ""
          end

        key =
          if option.acp_agent,
            do: "#{option.catalog_key}/#{option.acp_agent}",
            else: option.catalog_key

        "    #{option.index}) #{name}  #{key}#{tag}"
      end)

    Enum.join(["  Available LLM providers:" | lines], "\n")
  end

  @doc """
  Parses the operator's answer against the menu.

  Returns `{:ok, option}`, or `{:error, reason}` where reason is
  `:empty_menu`, `{:out_of_range, n}`, or `{:unknown, input}`.
  """
  @spec parse_selection(String.t() | nil, [option()]) :: {:ok, option()} | {:error, term()}
  def parse_selection(_input, []), do: {:error, :empty_menu}

  def parse_selection(nil, [first | _]), do: {:ok, first}

  def parse_selection(input, [first | _] = options) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:ok, first}

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} -> by_index(n, options)
          _ -> by_name(trimmed, options)
        end
    end
  end

  @doc "Validates a pasted API key: non-empty, single line, no surrounding whitespace issues."
  @spec parse_api_key(String.t() | nil) :: {:ok, String.t()} | {:error, :empty | :multiline}
  def parse_api_key(nil), do: {:error, :empty}

  def parse_api_key(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" -> {:error, :empty}
      String.contains?(trimmed, ["\n", "\r"]) -> {:error, :multiline}
      true -> {:ok, trimmed}
    end
  end

  defp by_index(n, options) do
    case Enum.find(options, &(&1.index == n)) do
      nil -> {:error, {:out_of_range, n}}
      option -> {:ok, option}
    end
  end

  defp by_name(name, options) do
    wanted = String.downcase(name)

    # `acp` alone means the first (preferred) ACP agent; an agent id such as
    # `codex` picks that agent's row.
    case Enum.find(options, fn option ->
           wanted in Enum.reject(
             [
               String.downcase(option.catalog_key),
               String.downcase(Atom.to_string(option.config_atom)),
               option.acp_agent && String.downcase(option.acp_agent)
             ],
             &is_nil/1
           )
         end) do
      nil -> {:error, {:unknown, name}}
      option -> {:ok, option}
    end
  end
end
