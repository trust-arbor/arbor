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
    Enum.filter(models, &admissible?/1)
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
    Enum.reject(models, &admissible?/1)
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

    # Report the evidence that EXISTS. This previously read `eval`, `score` and
    # `at` from tier 2 unconditionally, so a tier-1-only admission printed
    # "eval=arbor.eval.task, score=nil" — claiming a provenance that never ran
    # and rendering an absent value as though it were a measurement.
    admitted_lines =
      Enum.map(admitted, fn record ->
        id = model_id(record)
        evidence = evidence(record)
        tier = if evidence_level(record) == :full, do: "tier2", else: "tier1"
        t = Map.get(evidence, tier) || %{}
        eval = Map.get(t, "eval") || "unrecorded"
        at = Map.get(t, "at") || state.recorded_at || "unknown"

        case Map.get(t, "score") do
          nil -> "  - #{id}  (#{tier}: #{eval}, at=#{at})"
          score -> "  - #{id}  (#{tier}: #{eval}, score=#{score}, at=#{at})"
        end
      end)

    # "Rejected" must mean MEASURED AND FAILED. A model the relay rate-limits
    # for honest attribution is not defective — Arbor declines to spoof a
    # User-Agent to reach it — and merging that with genuine tool-call failures
    # leaves an operator unable to tell "this model is bad" from "unreachable on
    # our terms", which is exactly what they need when the free tier rotates.
    {unreachable, failed} =
      Enum.split_with(rejected, fn record ->
        reason = to_string(Map.get(record, "reason") || Map.get(record, :reason) || "")
        String.contains?(reason, "ua_gated")
      end)

    rejected_lines = Enum.map(failed, &rejection_line/1)
    unreachable_lines = Enum.map(unreachable, &rejection_line/1)

    """
    #{disclosure_text()}
    Admitted models (measured, recorded #{state.recorded_at || "unknown"}).
    Each line states which tier the evidence comes from:
    #{Enum.join(admitted_lines, "\n")}
    #{section("Failed evaluation (measured, will not be retried automatically):", rejected_lines)}#{section("Unreachable on Arbor's terms (the model may be fine; Arbor sends honest attribution and will not spoof a User-Agent to get free compute):", unreachable_lines)}
    """
  end

  defp rejection_line(record) do
    reason = Map.get(record, "reason") || Map.get(record, :reason) || "unrecorded"
    "  - #{model_id(record)}  (#{reason})"
  end

  defp section(_heading, []), do: ""

  defp section(heading, lines) do
    "\n" <> heading <> "\n" <> Enum.join(lines, "\n") <> "\n"
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

  # Admission requires a PASSING tier 1 and the absence of a tier-2 FAILURE.
  #
  # This is a deliberate loosening from "both tiers passed" (2026-08-24). The
  # gate applies only to the keyless shared tier — `ensure_keyless_ready/3`
  # returns `:ok` for every user-credentialed provider — so it is a QUALITY
  # filter over a provider Arbor chose on the user's behalf, not a security
  # boundary. A quality filter that admits nothing protects no one; it just
  # makes the advertised zero-config path dead.
  #
  # The distinction that still matters, and is enforced below: a model whose
  # tier 2 was MEASURED AND FAILED stays rejected forever. Only a tier 2 that
  # has not run is permissive. "We have not tested this yet" and "we tested
  # this and it failed" must never collapse into the same verdict.
  defp admissible?(record) when is_map(record) do
    evidence = evidence(record)

    evidence_passed?(Map.get(evidence, "tier1")) and
      not tier2_failed?(Map.get(evidence, "tier2"))
  end

  defp admissible?(_), do: false

  # Absent or explicitly skipped tier 2 = not run = not a failure.
  # Present, not passed, and not skipped = a real measured failure.
  defp tier2_failed?(nil), do: false

  defp tier2_failed?(tier2) when is_map(tier2) do
    skipped? = Map.get(tier2, "skipped") == true or Map.get(tier2, :skipped) == true
    not evidence_passed?(tier2) and not skipped?
  end

  defp tier2_failed?(_), do: false

  @doc """
  How much evidence stands behind an admitted record: `:full` when both tiers
  passed, `:tier1_only` when tier 2 has not run.

  Surfaced so a listing can state its own confidence rather than presenting
  partial evidence as complete.
  """
  @spec evidence_level(map()) :: :full | :tier1_only | :none
  def evidence_level(record) when is_map(record) do
    evidence = evidence(record)

    cond do
      not evidence_passed?(Map.get(evidence, "tier1")) -> :none
      evidence_passed?(Map.get(evidence, "tier2")) -> :full
      true -> :tier1_only
    end
  end

  def evidence_level(_), do: :none

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
       when is_binary(name) and name != "",
       do: well_formed_arguments?(arguments)

  defp tool_call_part?(%{"kind" => kind, "name" => name, "arguments" => arguments})
       when kind in [:tool_call, "tool_call"] and is_binary(name) and name != "",
       do: well_formed_arguments?(arguments)

  defp tool_call_part?(_), do: false

  # The OpenAI wire shape carries `arguments` as a JSON STRING, and that is what
  # ReqLLM surfaces:
  #
  #     %{id: "call_...", name: "ping", type: "function",
  #       arguments: "{\"note\":\"ok\"}", kind: :tool_call}
  #
  # Requiring `is_map(arguments)` therefore rejected every model that emits a
  # standard, correct tool call — the tier-1 gate could never pass, which is
  # consistent with an admission catalog that was written rather than measured.
  # Accept a decodable JSON object string as well as an already-decoded map.
  defp well_formed_arguments?(arguments) when is_map(arguments), do: true

  defp well_formed_arguments?(arguments) when is_binary(arguments) do
    case JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> true
      _ -> false
    end
  end

  defp well_formed_arguments?(_arguments), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(_), do: %{}
end
