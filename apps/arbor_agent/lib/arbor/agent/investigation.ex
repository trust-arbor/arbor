defmodule Arbor.Agent.Investigation do
  @moduledoc """
  Structured investigation for BEAM runtime anomalies.

  Provides a systematic investigation flow:
  1. Gather symptoms via Monitor.Diagnostics
  2. Generate hypotheses with confidence scores
  3. Test hypotheses with diagnostic probes
  4. Build evidence chain for proposals

  ## Example

      # Start investigation from an anomaly
      investigation = Investigation.start(anomaly)

      # Gather symptoms
      investigation = Investigation.gather_symptoms(investigation)

      # Generate hypotheses
      investigation = Investigation.generate_hypotheses(investigation)

      # Build proposal with evidence
      proposal = Investigation.to_proposal(investigation)
  """

  alias Arbor.Monitor.Diagnostics
  alias Arbor.Historian
  alias Arbor.Historian.Timeline.Span

  require Logger

  defstruct [
    :id,
    :anomaly,
    :started_at,
    :symptoms,
    :hypotheses,
    :selected_hypothesis,
    :evidence_chain,
    :suggested_action,
    :confidence,
    :thinking_log
  ]

  @type symptom :: %{
          type: atom(),
          source: atom(),
          description: String.t(),
          value: term(),
          severity: atom(),
          timestamp: DateTime.t()
        }

  @type evidence :: %{
          type: atom(),
          description: String.t(),
          data: map(),
          timestamp: DateTime.t()
        }

  @type hypothesis :: %{
          id: String.t(),
          root_cause: String.t(),
          confidence: float(),
          evidence: [evidence()],
          suggested_action: atom(),
          action_target: term()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          anomaly: map(),
          started_at: DateTime.t(),
          symptoms: [symptom()],
          hypotheses: [hypothesis()],
          selected_hypothesis: hypothesis() | nil,
          evidence_chain: [evidence()],
          suggested_action: atom(),
          confidence: float(),
          thinking_log: [String.t()]
        }

  @doc """
  Start a new investigation from an anomaly.
  """
  @spec start(map()) :: t()
  def start(anomaly) do
    %__MODULE__{
      id: generate_id(),
      anomaly: anomaly,
      started_at: DateTime.utc_now(),
      symptoms: [],
      hypotheses: [],
      selected_hypothesis: nil,
      evidence_chain: [],
      suggested_action: :none,
      confidence: 0.0,
      thinking_log: ["Investigation started for #{anomaly.skill} anomaly"]
    }
  end

  @doc """
  Gather symptoms using Monitor.Diagnostics.

  Collects relevant runtime data based on the anomaly type.
  """
  @spec gather_symptoms(t()) :: t()
  def gather_symptoms(%__MODULE__{anomaly: anomaly} = investigation) do
    symptoms = []
    log = ["Gathering symptoms..."]

    # Get system-wide metrics
    memory = safe_call(fn -> Diagnostics.memory_info() end, %{})
    scheduler = safe_call(fn -> Diagnostics.scheduler_utilization() end, 0.0)

    symptoms =
      symptoms ++
        [
          %{
            type: :memory,
            source: :diagnostics,
            description: "System memory usage",
            value: memory,
            severity: classify_memory_severity(memory),
            timestamp: DateTime.utc_now()
          },
          %{
            type: :scheduler,
            source: :diagnostics,
            description: "Scheduler utilization",
            value: scheduler,
            severity: classify_scheduler_severity(scheduler),
            timestamp: DateTime.utc_now()
          }
        ]

    log =
      log ++
        [
          "Memory usage: #{format_memory(memory)}",
          "Scheduler: #{Float.round(scheduler * 100, 1)}%"
        ]

    # Skill-specific symptoms
    {skill_symptoms, skill_log} = gather_skill_symptoms(anomaly)
    symptoms = symptoms ++ skill_symptoms
    log = log ++ skill_log

    # Check for bloated queues
    bloated = safe_call(fn -> Diagnostics.find_bloated_queues(100) end, [])

    {bloated_symptoms, bloated_log} =
      if length(bloated) > 0 do
        {[
           %{
             type: :bloated_queues,
             source: :diagnostics,
             description: "Processes with high message queues",
             value: bloated,
             severity: :high,
             timestamp: DateTime.utc_now()
           }
         ], ["Found #{length(bloated)} processes with bloated queues"]}
      else
        {[], []}
      end

    symptoms = symptoms ++ bloated_symptoms
    log = log ++ bloated_log

    # Get recent historian events
    recent_events = fetch_recent_events(anomaly)

    symptoms =
      symptoms ++
        [
          %{
            type: :recent_events,
            source: :historian,
            description: "Events in 30s before anomaly",
            value: recent_events,
            severity: :info,
            timestamp: DateTime.utc_now()
          }
        ]

    log = log ++ ["Found #{length(recent_events)} recent events from Historian"]

    %{investigation | symptoms: symptoms, thinking_log: investigation.thinking_log ++ log}
  end

  @doc """
  Generate hypotheses based on gathered symptoms.
  """
  @spec generate_hypotheses(t()) :: t()
  def generate_hypotheses(%__MODULE__{anomaly: anomaly, symptoms: symptoms} = investigation) do
    log = ["Generating hypotheses..."]

    hypotheses =
      case anomaly.skill do
        :processes -> hypothesize_process_issue(symptoms, anomaly)
        :memory -> hypothesize_memory_issue(symptoms, anomaly)
        :beam -> hypothesize_beam_issue(symptoms, anomaly)
        :supervisor -> hypothesize_supervisor_issue(symptoms, anomaly)
        _ -> hypothesize_generic(symptoms, anomaly)
      end

    # Sort by confidence
    hypotheses = Enum.sort_by(hypotheses, & &1.confidence, :desc)

    log =
      log ++
        Enum.map(hypotheses, fn h ->
          "Hypothesis: #{h.root_cause} (confidence: #{Float.round(h.confidence * 100, 1)}%)"
        end)

    # Select top hypothesis
    selected = List.first(hypotheses)

    investigation =
      if selected do
        %{
          investigation
          | selected_hypothesis: selected,
            suggested_action: selected.suggested_action,
            confidence: selected.confidence,
            evidence_chain: selected.evidence
        }
      else
        investigation
      end

    %{investigation | hypotheses: hypotheses, thinking_log: investigation.thinking_log ++ log}
  end

  @doc """
  Use AI to enhance hypothesis with detailed analysis.
  """
  @spec enhance_with_ai(t()) :: t()
  def enhance_with_ai(%__MODULE__{} = investigation) do
    prompt = build_ai_prompt(investigation)

    case safe_call(fn -> Arbor.AI.generate_text(prompt, backend: :api, max_tokens: 500) end, nil) do
      nil ->
        log = ["AI enhancement skipped (unavailable)"]
        %{investigation | thinking_log: investigation.thinking_log ++ log}

      {:ok, response} ->
        # Parse AI response and update confidence/evidence
        enhanced = parse_ai_response(investigation, response)
        text = extract_response_text(response)
        log = ["AI analysis complete: #{String.slice(text, 0, 100)}..."]
        %{enhanced | thinking_log: investigation.thinking_log ++ log}

      {:error, reason} ->
        log = ["AI enhancement failed: #{inspect(reason)}"]
        %{investigation | thinking_log: investigation.thinking_log ++ log}
    end
  end

  @doc """
  Convert investigation to a proposal for the consensus council.
  """
  @spec to_proposal(t()) :: map()
  def to_proposal(%__MODULE__{} = investigation) do
    hyp = investigation.selected_hypothesis || %{}
    anomaly = investigation.anomaly

    %{
      topic: :runtime_fix,
      proposer: "debug-agent",
      description: build_proposal_description(investigation),
      target_module: nil,
      fix_code: "",
      root_cause: hyp[:root_cause] || "Unknown",
      confidence: investigation.confidence,
      context: %{
        proposer: "debug-agent",
        skill: anomaly.skill,
        severity: anomaly.severity,
        metric: get_in(anomaly, [:details, :metric]) || :unknown,
        value: get_in(anomaly, [:details, :value]) || 0,
        threshold: get_in(anomaly, [:details, :threshold]) || 0,
        root_cause: hyp[:root_cause] || "Unknown",
        recommended_fix: describe_action(investigation.suggested_action, hyp[:action_target]),
        suggested_action: investigation.suggested_action,
        action_target: hyp[:action_target],
        evidence_chain: investigation.evidence_chain,
        thinking_log: investigation.thinking_log,
        investigation_id: investigation.id,
        anomaly: anomaly
      }
    }
  end

  @doc """
  Get a summary of the investigation for display.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = investigation) do
    hyp = investigation.selected_hypothesis || %{}

    %{
      id: investigation.id,
      anomaly_skill: investigation.anomaly.skill,
      symptom_count: length(investigation.symptoms),
      hypothesis_count: length(investigation.hypotheses),
      selected_hypothesis: hyp[:root_cause],
      suggested_action: investigation.suggested_action,
      confidence: investigation.confidence,
      duration_ms: DateTime.diff(DateTime.utc_now(), investigation.started_at, :millisecond)
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp generate_id do
    "inv_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp gather_skill_symptoms(%{skill: :processes, details: details}) do
    pid = Map.get(details, :pid) || Map.get(details, :process)

    # Process-specific symptoms
    {pid_symptoms, pid_log} =
      if is_pid(pid) do
        case safe_call(fn -> Diagnostics.inspect_process(pid) end, nil) do
          nil ->
            {[], []}

          info ->
            {[
               %{
                 type: :process_info,
                 source: :diagnostics,
                 description: "Anomalous process details",
                 value: info,
                 severity: :high,
                 timestamp: DateTime.utc_now()
               }
             ],
             ["Process #{inspect(pid)}: queue=#{info.message_queue_len}, memory=#{info.memory}"]}
        end
      else
        {[], []}
      end

    # Top processes by message queue
    top_queue = safe_call(fn -> Diagnostics.top_processes_by(:message_queue, 5) end, [])

    {queue_symptoms, queue_log} =
      if length(top_queue) > 0 do
        {[
           %{
             type: :top_by_queue,
             source: :diagnostics,
             description: "Top processes by message queue",
             value: top_queue,
             severity: :medium,
             timestamp: DateTime.utc_now()
           }
         ], ["Top queue: #{inspect(Enum.map(top_queue, & &1.value))}"]}
      else
        {[], []}
      end

    {pid_symptoms ++ queue_symptoms, pid_log ++ queue_log}
  end

  defp gather_skill_symptoms(%{skill: :memory, details: details}) do
    pid = Map.get(details, :pid) || Map.get(details, :process)

    # Process-specific memory symptoms
    {pid_symptoms, pid_log} =
      if is_pid(pid) do
        case safe_call(fn -> Diagnostics.inspect_process(pid) end, nil) do
          nil ->
            {[], []}

          info ->
            {[
               %{
                 type: :process_memory,
                 source: :diagnostics,
                 description: "High memory process details",
                 value: info,
                 severity: :high,
                 timestamp: DateTime.utc_now()
               }
             ], ["Memory process: heap=#{info.heap_size}, total=#{info.total_heap_size}"]}
        end
      else
        {[], []}
      end

    # Top processes by memory
    top_mem = safe_call(fn -> Diagnostics.top_processes_by(:memory, 5) end, [])

    {mem_symptoms, mem_log} =
      if length(top_mem) > 0 do
        {[
           %{
             type: :top_by_memory,
             source: :diagnostics,
             description: "Top processes by memory",
             value: top_mem,
             severity: :medium,
             timestamp: DateTime.utc_now()
           }
         ], ["Top memory: #{inspect(Enum.map(top_mem, & &1.value))}"]}
      else
        {[], []}
      end

    {pid_symptoms ++ mem_symptoms, pid_log ++ mem_log}
  end

  defp gather_skill_symptoms(%{skill: :beam}) do
    # Get process count and top by reductions
    top_red = safe_call(fn -> Diagnostics.top_processes_by(:reductions, 5) end, [])
    process_count = length(Process.list())

    symptoms = [
      %{
        type: :process_count,
        source: :diagnostics,
        description: "Total process count",
        value: process_count,
        severity: if(process_count > 10_000, do: :high, else: :medium),
        timestamp: DateTime.utc_now()
      },
      %{
        type: :top_by_reductions,
        source: :diagnostics,
        description: "Top processes by reductions",
        value: top_red,
        severity: :info,
        timestamp: DateTime.utc_now()
      }
    ]

    log = [
      "Process count: #{process_count}",
      "Top reductions: #{inspect(Enum.map(top_red, & &1.value))}"
    ]

    {symptoms, log}
  end

  defp gather_skill_symptoms(%{skill: :supervisor, details: details}) do
    sup_pid = Map.get(details, :supervisor)

    if is_pid(sup_pid) do
      info = safe_call(fn -> Diagnostics.inspect_supervisor(sup_pid) end, nil)

      if info do
        symptoms = [
          %{
            type: :supervisor_info,
            source: :diagnostics,
            description: "Supervisor details",
            value: info,
            severity: :high,
            timestamp: DateTime.utc_now()
          }
        ]

        log = ["Supervisor: #{info.child_count} children, intensity=#{info.restart_intensity}"]
        {symptoms, log}
      else
        {[], []}
      end
    else
      {[], []}
    end
  end

  defp gather_skill_symptoms(_), do: {[], []}

  defp hypothesize_process_issue(symptoms, anomaly) do
    bloated = find_symptom(symptoms, :bloated_queues)
    process_info = find_symptom(symptoms, :process_info)
    details = anomaly.details || %{}

    # Hypothesis 1: Message queue flood
    bloated_hyp =
      if bloated && is_list(bloated.value) && length(bloated.value) > 0 do
        top_process = List.first(bloated.value)

        [
          %{
            id: generate_id(),
            root_cause: "Message queue flood in process #{inspect(top_process.pid)}",
            confidence: 0.85,
            evidence: [
              %{
                type: :symptom,
                description: "Process has #{top_process.message_queue_len} pending messages",
                data: top_process,
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :kill_process,
            action_target: top_process.pid
          }
        ]
      else
        []
      end

    # Hypothesis 2: Specific process from anomaly
    pid = Map.get(details, :pid) || Map.get(details, :process)

    pid_hyp =
      if is_pid(pid) && process_info do
        [
          %{
            id: generate_id(),
            root_cause: "Identified anomalous process #{inspect(pid)}",
            confidence: 0.90,
            evidence: [
              %{
                type: :anomaly,
                description: "Process flagged by monitor",
                data: process_info.value,
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :kill_process,
            action_target: pid
          }
        ]
      else
        []
      end

    bloated_hyp ++ pid_hyp
  end

  defp hypothesize_memory_issue(symptoms, anomaly) do
    process_memory = find_symptom(symptoms, :process_memory)
    top_memory = find_symptom(symptoms, :top_by_memory)
    details = anomaly.details || %{}
    pid = Map.get(details, :pid) || Map.get(details, :process)

    # Hypothesis 1: Specific high memory process
    pid_hyp =
      if is_pid(pid) && process_memory do
        [
          %{
            id: generate_id(),
            root_cause: "High memory usage in process #{inspect(pid)}",
            confidence: 0.80,
            evidence: [
              %{
                type: :symptom,
                description: "Process using excessive memory",
                data: process_memory.value,
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :force_gc,
            action_target: pid
          }
        ]
      else
        []
      end

    # Hypothesis 2: Top memory consumer
    top_hyp =
      if top_memory && is_list(top_memory.value) && length(top_memory.value) > 0 do
        top = List.first(top_memory.value)

        [
          %{
            id: generate_id(),
            root_cause: "Top memory consumer: #{inspect(top.pid)}",
            confidence: 0.70,
            evidence: [
              %{
                type: :ranking,
                description: "Process is #1 by memory usage",
                data: top,
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :force_gc,
            action_target: top.pid
          }
        ]
      else
        []
      end

    pid_hyp ++ top_hyp
  end

  defp hypothesize_beam_issue(symptoms, _anomaly) do
    process_count = find_symptom(symptoms, :process_count)
    bloated = find_symptom(symptoms, :bloated_queues)

    # Hypothesis 1: Process leak
    leak_hyp =
      if process_count && process_count.value > 5000 do
        [
          %{
            id: generate_id(),
            root_cause: "Possible process leak (#{process_count.value} processes)",
            confidence: 0.75,
            evidence: [
              %{
                type: :symptom,
                description: "High process count",
                data: %{count: process_count.value},
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :logged_warning,
            action_target: nil
          }
        ]
      else
        []
      end

    # Hypothesis 2: Combined with bloated queues suggests overload
    overload_hyp =
      if bloated && is_list(bloated.value) && length(bloated.value) > 3 do
        [
          %{
            id: generate_id(),
            root_cause: "System overload (multiple bloated queues)",
            confidence: 0.70,
            evidence: [
              %{
                type: :symptom,
                description: "#{length(bloated.value)} processes with bloated queues",
                data: bloated.value,
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :logged_warning,
            action_target: nil
          }
        ]
      else
        []
      end

    leak_hyp ++ overload_hyp
  end

  defp hypothesize_supervisor_issue(symptoms, anomaly) do
    sup_info = find_symptom(symptoms, :supervisor_info)
    details = anomaly.details || %{}
    sup_pid = Map.get(details, :supervisor)

    if sup_info && is_pid(sup_pid) do
      [
        %{
          id: generate_id(),
          root_cause: "Supervisor restart storm (intensity: #{sup_info.value.restart_intensity})",
          confidence: 0.80,
          evidence: [
            %{
              type: :symptom,
              description: "High restart intensity detected",
              data: sup_info.value,
              timestamp: DateTime.utc_now()
            }
          ],
          suggested_action: :stop_supervisor,
          action_target: sup_pid
        }
      ]
    else
      []
    end
  end

  defp hypothesize_generic(symptoms, anomaly) do
    [
      %{
        id: generate_id(),
        root_cause: "Unknown anomaly in #{anomaly.skill}",
        confidence: 0.30,
        evidence:
          Enum.take(symptoms, 3)
          |> Enum.map(fn s ->
            %{
              type: :symptom,
              description: s.description,
              data: %{type: s.type, severity: s.severity},
              timestamp: s.timestamp
            }
          end),
        suggested_action: :logged_warning,
        action_target: nil
      }
    ]
  end

  defp find_symptom(symptoms, type) do
    Enum.find(symptoms, fn s -> s.type == type end)
  end

  defp classify_memory_severity(%{usage_ratio: ratio}) when ratio > 0.90, do: :critical
  defp classify_memory_severity(%{usage_ratio: ratio}) when ratio > 0.80, do: :high
  defp classify_memory_severity(%{usage_ratio: ratio}) when ratio > 0.70, do: :medium
  defp classify_memory_severity(_), do: :low

  defp classify_scheduler_severity(util) when util > 0.95, do: :critical
  defp classify_scheduler_severity(util) when util > 0.85, do: :high
  defp classify_scheduler_severity(util) when util > 0.70, do: :medium
  defp classify_scheduler_severity(_), do: :low

  defp format_memory(%{usage_ratio: ratio}), do: "#{Float.round(ratio * 100, 1)}%"
  defp format_memory(_), do: "unknown"

  defp fetch_recent_events(anomaly) do
    from = DateTime.add(anomaly.timestamp, -30, :second)
    span = Span.new(from: from, to: anomaly.timestamp)

    case safe_call(fn -> Historian.reconstruct(span, max_results: 10) end, {:ok, []}) do
      {:ok, events} ->
        Enum.map(events, fn e ->
          %{type: e.type, category: e.category, timestamp: e.timestamp}
        end)

      _ ->
        []
    end
  end

  defp build_ai_prompt(investigation) do
    symptoms_text =
      investigation.symptoms
      |> Enum.map(fn s -> "- #{s.description}: #{inspect(s.value)}" end)
      |> Enum.join("\n")

    hypotheses_text =
      investigation.hypotheses
      |> Enum.map(fn h -> "- #{h.root_cause} (confidence: #{h.confidence})" end)
      |> Enum.join("\n")

    """
    Analyze this BEAM runtime investigation and refine the diagnosis:

    ## Anomaly
    Skill: #{investigation.anomaly.skill}
    Severity: #{investigation.anomaly.severity}

    ## Symptoms Gathered
    #{symptoms_text}

    ## Current Hypotheses
    #{hypotheses_text}

    Based on the evidence, provide:
    1. Which hypothesis is most likely correct and why
    2. Any additional root cause not considered
    3. Recommended action with confidence (0.0-1.0)
    """
  end

  defp parse_ai_response(investigation, response) do
    # Extract text from response map (Arbor.AI returns %{text: ..., usage: ...})
    text = extract_response_text(response)

    # Extract confidence adjustment from AI response
    confidence_match = Regex.run(~r/confidence[:\s]+(\d+\.?\d*)/i, text)

    new_confidence =
      case confidence_match do
        [_, num] ->
          case Float.parse(num) do
            {f, _} when f > 1.0 -> f / 100
            {f, _} -> f
            _ -> investigation.confidence
          end

        _ ->
          investigation.confidence
      end

    # Add AI analysis as evidence
    evidence =
      investigation.evidence_chain ++
        [
          %{
            type: :ai_analysis,
            description: "AI refinement of hypothesis",
            data: %{response: String.slice(text, 0, 500)},
            timestamp: DateTime.utc_now()
          }
        ]

    %{investigation | confidence: new_confidence, evidence_chain: evidence}
  end

  defp build_proposal_description(investigation) do
    hyp = investigation.selected_hypothesis || %{}

    """
    Fix for #{investigation.anomaly.skill} #{investigation.anomaly.severity} anomaly.

    Root Cause: #{hyp[:root_cause] || "Unknown"}
    Confidence: #{Float.round(investigation.confidence * 100, 1)}%
    Action: #{describe_action(investigation.suggested_action, hyp[:action_target])}
    """
  end

  defp describe_action(:kill_process, pid), do: "Kill process #{inspect(pid)}"
  defp describe_action(:force_gc, pid), do: "Force GC on #{inspect(pid)}"
  defp describe_action(:stop_supervisor, pid), do: "Stop supervisor #{inspect(pid)}"
  defp describe_action(:restart_child, id), do: "Restart child #{inspect(id)}"
  defp describe_action(:logged_warning, _), do: "Log warning (manual intervention needed)"
  defp describe_action(action, _), do: "#{action}"

  # Extract text string from various AI response formats.
  # Handles plain maps, structs, and raw strings safely.
  defp extract_response_text(response) when is_binary(response), do: response

  defp extract_response_text(response) when is_struct(response) do
    Map.get(response, :text) || Map.get(response, :content) || inspect(response)
  end

  defp extract_response_text(response) when is_map(response) do
    response[:text] || response["text"] || response[:content] || response["content"] || inspect(response)
  end

  defp extract_response_text(response), do: to_string(response)

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
