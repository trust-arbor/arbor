defmodule Arbor.LLM.OpenCodeZen.AdmissionCore do
  @moduledoc """
  Pure decisions for the OpenCode Zen free-tier catalog.

  The admitted list is derived from recorded eval evidence, never from
  vendor claims. A model is admitted only when both probe tiers passed:

    * Tier 1 — mechanical well-formed tool call
    * Tier 2 — `mix arbor.eval.task` reached a proposal

  Status strings in the recorded file are informational; evidence is
  authoritative. All functions are side-effect free.
  """

  @type record :: map()
  @type t :: %{version: pos_integer(), recorded_at: String.t() | nil, models: [record()]}

  @disclosure """
  OpenCode Zen free tier — data disclosure

  Before Arbor sends any request to OpenCode's API (https://opencode.ai/zen):

    1. Your prompts, and any context the agent includes — such as file
       contents and command output — are sent to OpenCode's API.
    2. Arbor makes NO representations or guarantees about OpenCode's
       data-handling or privacy claims, whatever their documentation states.
    3. Do not use this free tier for sensitive, confidential, or regulated data.

  You must actively acknowledge this once. Arbor stores that acknowledgement
  locally and will not re-prompt on later runs.
  """

  @doc "Construct catalog state from a decoded admission payload."
  @spec new(map()) :: t()
  def new(payload) when is_map(payload) do
    models =
      payload
      |> Map.get("models", Map.get(payload, :models, []))
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    %{
      version: Map.get(payload, "version") || Map.get(payload, :version) || 1,
      recorded_at: Map.get(payload, "recorded_at") || Map.get(payload, :recorded_at),
      models: models
    }
  end

  def new(_payload), do: %{version: 1, recorded_at: nil, models: []}

  @doc "Models whose recorded evidence passed both admission tiers."
  @spec admitted(t()) :: [record()]
  def admitted(%{models: models}) do
    Enum.filter(models, &both_tiers_passed?/1)
  end

  @doc "Admitted model ids, in recorded order."
  @spec admitted_ids(t()) :: [String.t()]
  def admitted_ids(state), do: state |> admitted() |> Enum.flat_map(&id_list/1)

  @doc "True when `id` is in the admitted set derived from recorded evidence."
  @spec admitted_id?(t(), term()) :: boolean()
  def admitted_id?(state, id) when is_binary(id) and id != "", do: id in admitted_ids(state)
  def admitted_id?(_state, _id), do: false

  @doc "Models that did not pass both tiers, with their recorded reason."
  @spec rejected(t()) :: [record()]
  def rejected(%{models: models}) do
    Enum.reject(models, &both_tiers_passed?/1)
  end

  @doc "True when the response contains a well-formed tool call (tier 1)."
  @spec well_formed_tool_call?(term()) :: boolean()
  def well_formed_tool_call?(%{content_parts: parts}) when is_list(parts) do
    Enum.any?(parts, &tool_call_part?/1)
  end

  def well_formed_tool_call?(_), do: false

  @doc """
  Classify a free-tier slug.

  Suffixed `-free` ids are the stable catalog shape. Unsuffixed ids are
  rotating slots the relay advertises without the suffix.
  """
  @spec classify_slug(String.t()) :: :free_suffix | :unsuffixed_slot | :invalid
  def classify_slug(slug) when is_binary(slug) and slug != "" do
    if String.ends_with?(slug, "-free"), do: :free_suffix, else: :unsuffixed_slot
  end

  def classify_slug(_), do: :invalid

  @doc "Permit a request only after an active acknowledgement."
  @spec request_permitted?(term()) :: :ok | {:error, :disclosure_not_acknowledged}
  def request_permitted?(%{"acknowledged" => true}), do: :ok
  def request_permitted?(%{acknowledged: true}), do: :ok
  def request_permitted?(true), do: :ok
  def request_permitted?(_), do: {:error, :disclosure_not_acknowledged}

  @doc "The user-facing disclosure text (all three required points)."
  @spec disclosure_text() :: String.t()
  def disclosure_text, do: String.trim(@disclosure) <> "\n"

  @doc "Convert internal state to the listing shown to users."
  @spec show(t()) :: String.t()
  def show(state) do
    admitted = admitted(state)
    rejected = rejected(state)

    admitted_lines =
      Enum.map(admitted, fn record ->
        id = model_id(record)
        evidence = evidence(record)
        t2 = Map.get(evidence, "tier2") || %{}
        score = Map.get(t2, "score")
        at = Map.get(t2, "at") || state.recorded_at
        eval = Map.get(t2, "eval") || "arbor.eval.task"

        "  - #{id}  (eval=#{eval}, score=#{inspect(score)}, at=#{at})"
      end)

    rejected_lines =
      Enum.map(rejected, fn record ->
        id = model_id(record)
        reason = Map.get(record, "reason") || Map.get(record, :reason) || "rejected"
        "  - #{id}  (#{reason})"
      end)

    """
    #{disclosure_text()}
    Admitted models (derived from recorded eval evidence, recorded #{state.recorded_at || "unknown"}):
    #{Enum.join(admitted_lines, "\n")}

    Rejected (kept so the catalog can be re-synced rather than re-litigated):
    #{Enum.join(rejected_lines, "\n")}
    """
  end

  @doc "Build a recorded-eval row from tier results. Pure."
  @spec record(String.t(), map()) :: record()
  def record(id, attrs) when is_binary(id) and is_map(attrs) do
    tier1 = Map.get(attrs, :tier1) || Map.get(attrs, "tier1") || %{}
    tier2 = Map.get(attrs, :tier2) || Map.get(attrs, "tier2") || %{}
    reason = Map.get(attrs, :reason) || Map.get(attrs, "reason")

    status =
      if evidence_passed?(tier1) and evidence_passed?(tier2),
        do: "admitted",
        else: "rejected"

    %{
      "id" => id,
      "status" => status,
      "reason" => reason,
      "context_window" => Map.get(attrs, :context_window) || Map.get(attrs, "context_window"),
      "evidence" => %{
        "tier1" => stringify_keys(tier1),
        "tier2" => stringify_keys(tier2)
      }
    }
  end

  defp both_tiers_passed?(record) when is_map(record) do
    evidence = evidence(record)
    evidence_passed?(Map.get(evidence, "tier1")) and evidence_passed?(Map.get(evidence, "tier2"))
  end

  defp both_tiers_passed?(_), do: false

  defp evidence_passed?(evidence) when is_map(evidence) do
    Map.get(evidence, "passed") == true or Map.get(evidence, :passed) == true
  end

  defp evidence_passed?(_), do: false

  defp evidence(record) do
    raw = Map.get(record, "evidence") || Map.get(record, :evidence) || %{}
    stringify_keys(raw)
  end

  defp model_id(record) do
    Map.get(record, "id") || Map.get(record, :id) || "unknown"
  end

  defp id_list(record) do
    case model_id(record) do
      id when is_binary(id) and id != "" and id != "unknown" -> [id]
      _ -> []
    end
  end

  defp tool_call_part?(%{kind: :tool_call, name: name, arguments: arguments})
       when is_binary(name) and name != "" and is_map(arguments),
       do: true

  defp tool_call_part?(%{"kind" => kind, "name" => name, "arguments" => arguments})
       when kind in [:tool_call, "tool_call"] and is_binary(name) and name != "" and is_map(arguments),
       do: true

  defp tool_call_part?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(_), do: %{}
end
