defmodule Arbor.Actions.Session.ProcessResultsCore do
  @moduledoc """
  Pure parse-and-classify core for `Arbor.Actions.Session.ProcessResults`.

  A heartbeat reply is LLM text that should hold one JSON object in the
  heartbeat response contract. Until 2026-09-28 every reply that failed to
  parse produced the same all-empty field map as a reply that parsed and
  asked for nothing, so a broken reply (empty content from an exhausted
  reasoning budget, prose instead of JSON, a truncated object) looked exactly
  like an idle agent.

  Extraction is unchanged: only a parsed reply yields fields, and a failed
  parse still yields no actions (fail closed). What this core adds is an
  explicit outcome, so "parse rate" and "result given a parse" are two
  separate numbers:

    * `:parsed` — a JSON object carrying at least one heartbeat contract key
      (an object holding only `"thinking"` is a legitimately idle reply).
      `rejected_fields` names contract fields that were present but
      malformed: not a list, or holding items the validators dropped.
    * `:parse_failed` — no heartbeat object was found. `reason` is one of:
        * `:empty` — blank reply (or a blank fenced block)
        * `:not_json` — text that does not decode as JSON: prose,
          prose-wrapped JSON, or a truncated object
        * `:no_json_object` — valid JSON whose top level is not an object
        * `:invalid_shape` — a JSON object with none of the contract keys
    * `:no_reply` — the cognitive mode makes no LLM call before this node, and
      the input is not a heartbeat object. On the consolidation path the
      heartbeat graphs route `consolidate -> process`, so `last_response`
      holds the consolidate action's own JSON output, not an LLM reply.
      Nothing was asked, so nothing failed to parse.

  The contract keys are the union of what `Session.ProcessResults` extracts
  and what the heartbeat prompts ask for (`"thinking"`, `"cognitive_mode"`).
  The two have drifted (the parser reads `"new_intents"`, which no prompt asks
  for), so a reply is recognised by any of them.

  Construct with `new/2`, convert with `show/1`. The module has no side
  effects: no IO, logging, time, or randomness. The action logs, emits the
  signal, and returns `show/1` as its result.
  """

  @validated_list_fields ~w(actions goal_updates new_goals memory_notes concerns curiosity
                            decompositions new_intents proposal_decisions identity_insights)

  @contract_keys @validated_list_fields ++ ~w(proposals fix_proposal thinking cognitive_mode)

  # Modes whose graph path reaches `process` without an LLM call.
  @no_reply_modes ["consolidation"]

  @proposal_decisions ~w(accept reject defer)
  @eval_fix_kinds ~w(fix bug_fix fix_proposal)

  # Redact inside a bounded window, then truncate, so a secret is never cut in
  # half before the redactor sees it.
  @preview_window_bytes 2048
  @preview_window_chars 512
  @preview_chars 160

  @empty_fields %{
    actions: [],
    goal_updates: [],
    new_goals: [],
    memory_notes: [],
    concerns: [],
    curiosity: [],
    decompositions: [],
    new_intents: [],
    proposal_decisions: [],
    identity_insights: [],
    proposals: [],
    fix_proposal: nil
  }

  @type status :: :parsed | :parse_failed | :no_reply
  @type reason :: :empty | :not_json | :no_json_object | :invalid_shape

  @type t :: %__MODULE__{
          status: status(),
          reason: reason() | nil,
          parsed: map() | nil,
          rejected_fields: [String.t()],
          reply_bytes: non_neg_integer()
        }

  defstruct status: :parse_failed,
            reason: :empty,
            parsed: nil,
            rejected_fields: [],
            reply_bytes: 0

  # ============================================================================
  # Construct
  # ============================================================================

  @doc """
  Classify a raw heartbeat reply.

  ## Options

    * `:cognitive_mode` — the heartbeat's cognitive mode. In a mode listed as
      making no LLM call (`"consolidation"`), a non-heartbeat input is
      `:no_reply` rather than `:parse_failed`.
  """
  @spec new(term(), keyword()) :: t()
  def new(raw, opts \\ []) do
    mode = normalize_mode(Keyword.get(opts, :cognitive_mode))

    raw
    |> decode()
    |> classify(mode)
    |> Map.put(:reply_bytes, reply_bytes(raw))
  end

  defp decode(raw) when is_binary(raw) do
    case extract_json(raw) do
      "" ->
        {:error, :empty}

      text ->
        case Jason.decode(text) do
          {:ok, object} when is_map(object) -> {:ok, object}
          {:ok, _not_an_object} -> {:error, :no_json_object}
          {:error, _reason} -> {:error, :not_json}
        end
    end
  end

  defp decode(nil), do: {:error, :empty}
  defp decode(_not_text), do: {:error, :not_json}

  defp classify({:ok, object}, mode) do
    if Enum.any?(@contract_keys, &Map.has_key?(object, &1)) do
      %__MODULE__{
        status: :parsed,
        reason: nil,
        parsed: object,
        rejected_fields: rejected_fields(object)
      }
    else
      unparsed(:invalid_shape, mode)
    end
  end

  defp classify({:error, reason}, mode), do: unparsed(reason, mode)

  defp unparsed(_reason, mode) when mode in @no_reply_modes,
    do: %__MODULE__{status: :no_reply, reason: nil}

  defp unparsed(reason, _mode), do: %__MODULE__{status: :parse_failed, reason: reason}

  defp normalize_mode(mode) when is_atom(mode) and not is_nil(mode), do: Atom.to_string(mode)
  defp normalize_mode(mode) when is_binary(mode), do: mode
  defp normalize_mode(_mode), do: nil

  defp reply_bytes(raw) when is_binary(raw), do: byte_size(raw)
  defp reply_bytes(_raw), do: 0

  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?```/s, text) do
      [_, json] -> String.trim(json)
      nil -> String.trim(text)
    end
  end

  # A present contract field is malformed when it is not a list, or when the
  # extractor would drop any of its items. `null` counts as omitted.
  defp rejected_fields(object) do
    for key <- @validated_list_fields ++ ["proposals"],
        malformed_field?(key, Map.get(object, key)),
        do: key
  end

  defp malformed_field?(_key, nil), do: false

  defp malformed_field?(key, items) when is_list(items),
    do: not Enum.all?(items, &valid_item?(key, &1))

  defp malformed_field?(_key, _not_a_list), do: true

  # ============================================================================
  # Reduce — field extraction (only a parsed reply yields fields)
  # ============================================================================

  @doc """
  The typed heartbeat fields extracted from the reply.

  Anything but a `:parsed` outcome yields the all-empty field map: a reply
  that could not be read executes nothing.
  """
  @spec fields(t()) :: map()
  def fields(%__MODULE__{status: :parsed, parsed: parsed}) when is_map(parsed) do
    %{
      actions: validated_list(parsed, "actions"),
      goal_updates: validated_list(parsed, "goal_updates"),
      new_goals: validated_list(parsed, "new_goals"),
      memory_notes: validated_list(parsed, "memory_notes"),
      concerns: validated_list(parsed, "concerns"),
      curiosity: validated_list(parsed, "curiosity"),
      decompositions: validated_list(parsed, "decompositions"),
      new_intents: validated_list(parsed, "new_intents"),
      proposal_decisions: validated_list(parsed, "proposal_decisions"),
      identity_insights: validated_list(parsed, "identity_insights"),
      proposals: extract_authored_proposals(parsed),
      fix_proposal: extract_fix_proposal(parsed)
    }
  end

  def fields(%__MODULE__{}), do: @empty_fields

  defp validated_list(parsed, key) do
    case Map.get(parsed, key) do
      items when is_list(items) -> Enum.filter(items, &valid_item?(key, &1))
      _ -> []
    end
  end

  defp valid_item?("actions", %{"type" => type}) when is_binary(type), do: true
  defp valid_item?("actions", _item), do: false

  defp valid_item?("memory_notes", note) when is_binary(note), do: true
  defp valid_item?("memory_notes", %{"text" => text}) when is_binary(text), do: true
  defp valid_item?("memory_notes", _item), do: false

  defp valid_item?(key, item) when key in ["concerns", "curiosity"], do: is_binary(item)

  defp valid_item?("proposal_decisions", %{"proposal_id" => id, "decision" => decision})
       when is_binary(id) and decision in @proposal_decisions,
       do: true

  defp valid_item?("proposal_decisions", _item), do: false

  defp valid_item?("proposals", item), do: valid_authored_proposal?(item)

  # goal_updates, new_goals, decompositions, new_intents, identity_insights
  defp valid_item?(_map_field, item), do: is_map(item)

  defp extract_authored_proposals(parsed) do
    from_list = validated_list(parsed, "proposals")

    if from_list != [] do
      from_list
    else
      case extract_legacy_fix_proposal(parsed) do
        nil -> []
        text -> [%{"kind" => "fix", "content" => text}]
      end
    end
  end

  defp valid_authored_proposal?(%{"kind" => kind, "content" => content})
       when is_binary(kind) and is_binary(content) do
    String.trim(kind) != "" and nonempty_trim(content) != nil
  end

  defp valid_authored_proposal?(_item), do: false

  defp extract_fix_proposal(parsed) do
    parsed
    |> extract_authored_proposals()
    |> Enum.find_value(fn item ->
      kind = item["kind"] || item[:kind]

      if to_string(kind) in @eval_fix_kinds do
        nonempty_trim(item["content"] || item[:content] || "")
      end
    end)
  end

  defp extract_legacy_fix_proposal(parsed) do
    case Map.get(parsed, "fix_proposal") do
      text when is_binary(text) -> nonempty_trim(text)
      %{"content" => text} when is_binary(text) -> nonempty_trim(text)
      %{"text" => text} when is_binary(text) -> nonempty_trim(text)
      _ -> nil
    end
  end

  defp nonempty_trim(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ============================================================================
  # Convert
  # ============================================================================

  @doc """
  The action result: the extracted fields plus the parse outcome.

  JSON-clean for the engine context (the result lands under the node's
  `output_prefix`, e.g. `session.parse_status`):

    * `parse_status` — `"parsed" | "parse_failed" | "no_reply"`
    * `parse_error` — `nil` or `"empty" | "not_json" | "no_json_object" |
      "invalid_shape"`
    * `parse_rejected_fields` — contract field names that were present but
      malformed (only ever non-empty for `"parsed"`)
  """
  @spec show(t()) :: map()
  def show(%__MODULE__{} = core) do
    core
    |> fields()
    |> Map.merge(%{
      parse_status: Atom.to_string(core.status),
      parse_error: core.reason && Atom.to_string(core.reason),
      parse_rejected_fields: core.rejected_fields
    })
  end

  @doc "True when the reply should have parsed and did not."
  @spec parse_failed?(t()) :: boolean()
  def parse_failed?(%__MODULE__{status: status}), do: status == :parse_failed

  @doc """
  A bounded, valid-UTF-8 window of the raw reply for the caller to redact.

  Redact this window, then pass it to `truncate_preview/1`.
  """
  @spec preview_window(term()) :: String.t()
  def preview_window(raw) when is_binary(raw) do
    raw
    |> binary_part(0, min(byte_size(raw), @preview_window_bytes))
    |> String.replace_invalid()
    |> String.slice(0, @preview_window_chars)
  end

  def preview_window(_raw), do: ""

  @doc "Collapse whitespace and cut a (redacted) window to a one-line preview."
  @spec truncate_preview(String.t()) :: String.t()
  def truncate_preview(text) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(collapsed) > @preview_chars do
      String.slice(collapsed, 0, @preview_chars) <> "..."
    else
      collapsed
    end
  end
end
