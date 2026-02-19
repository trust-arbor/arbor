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

  alias Arbor.Historian
  alias Arbor.Historian.Timeline.Span
  alias Arbor.Monitor.Diagnostics

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
    :thinking_log,
    :similar_events,
    :error_classification,
    :fix_strategy,
    :safety_validation,
    :codebase_context
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
          thinking_log: [String.t()],
          similar_events: [map()],
          error_classification: map() | nil,
          fix_strategy: atom() | nil,
          safety_validation: map() | nil,
          codebase_context: map() | nil
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
      thinking_log: ["Investigation started for #{anomaly.skill} anomaly"],
      similar_events: [],
      error_classification: nil,
      fix_strategy: nil,
      safety_validation: nil,
      codebase_context: nil
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
      if bloated != [] do
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
  Search for similar past events in Historian to inform hypotheses.

  Queries the last 30 minutes of events and filters for those matching
  the anomaly's skill or sharing keywords with the error context.
  """
  @spec find_similar_events(t()) :: t()
  def find_similar_events(%__MODULE__{anomaly: anomaly} = investigation) do
    log = ["Searching for similar events..."]

    similar =
      if historian_available?() do
        span =
          Span.new(from: DateTime.add(DateTime.utc_now(), -30, :minute), to: DateTime.utc_now())

        case safe_call(fn -> Historian.reconstruct(span, max_results: 50) end, {:ok, []}) do
          {:ok, events} ->
            events
            |> Enum.filter(fn e -> similar_to_anomaly?(e, anomaly) end)
            |> Enum.map(fn e ->
              %{
                type: e.type,
                category: e.category,
                timestamp: e.timestamp,
                similarity: compute_similarity(e, anomaly)
              }
            end)
            |> Enum.sort_by(& &1.similarity, :desc)
            |> Enum.take(10)

          _ ->
            []
        end
      else
        []
      end

    # Add as symptom if we found related events
    symptoms =
      if similar != [] do
        [
          %{
            type: :similar_event,
            source: :historian,
            description: "#{length(similar)} similar events in last 30 minutes",
            value: similar,
            severity: if(length(similar) > 5, do: :high, else: :medium),
            timestamp: DateTime.utc_now()
          }
        ]
      else
        []
      end

    # Also gather codebase context from anomaly details
    codebase_ctx = gather_codebase_context(anomaly)

    log =
      log ++
        [
          "Found #{length(similar)} similar events",
          "Extracted #{map_size(codebase_ctx)} codebase context categories"
        ]

    %{
      investigation
      | similar_events: similar,
        symptoms: investigation.symptoms ++ symptoms,
        codebase_context: codebase_ctx,
        thinking_log: investigation.thinking_log ++ log
    }
  end

  @doc """
  Classify error details when the anomaly has error context.

  Determines error type, severity, category, and subsystem from
  error messages and stacktrace information.
  """
  @spec categorize_error(t()) :: t()
  def categorize_error(%__MODULE__{anomaly: anomaly} = investigation) do
    details = anomaly[:details] || anomaly.details || %{}
    error_text = extract_error_text(details)

    if error_text != "" do
      classification = %{
        error_type: classify_error_type(error_text),
        severity: classify_error_severity(error_text),
        category: classify_error_category(error_text),
        subsystem: infer_subsystem(error_text, investigation.codebase_context)
      }

      evidence = %{
        type: :error_classification,
        description:
          "Error classified as #{classification.error_type} " <>
            "(#{classification.severity}, #{classification.category})",
        data: classification,
        timestamp: DateTime.utc_now()
      }

      log = [
        "Error categorized: type=#{classification.error_type}, " <>
          "severity=#{classification.severity}, category=#{classification.category}"
      ]

      %{
        investigation
        | error_classification: classification,
          evidence_chain: investigation.evidence_chain ++ [evidence],
          thinking_log: investigation.thinking_log ++ log
      }
    else
      log = ["No error context found — skipping error categorization"]
      %{investigation | thinking_log: investigation.thinking_log ++ log}
    end
  end

  @doc """
  Validate safety of the proposed fix before submission.

  Scans fix_code and AI suggestions for dangerous patterns.
  Produces a safety score (0-100, higher = safer).
  """
  @spec validate_safety(t()) :: t()
  def validate_safety(%__MODULE__{} = investigation) do
    # Collect all text that might contain dangerous patterns
    texts_to_scan = collect_scannable_text(investigation)
    issues = scan_for_dangerous_patterns(texts_to_scan)

    # Runtime actions (kill/gc/stop/suppress/reset) get simpler validation
    runtime_issues = validate_runtime_action(investigation.suggested_action)
    all_issues = issues ++ runtime_issues

    safety_score = max(0, 100 - length(all_issues) * 20)
    requires_approval = all_issues != [] || safety_score < 60

    validation = %{
      safety_score: safety_score,
      issues: all_issues,
      requires_approval: requires_approval,
      scanned_at: DateTime.utc_now()
    }

    evidence = %{
      type: :safety_validation,
      description: "Safety score: #{safety_score}/100 (#{length(all_issues)} issues)",
      data: validation,
      timestamp: DateTime.utc_now()
    }

    log = [
      "Safety validation: score=#{safety_score}, issues=#{length(all_issues)}, " <>
        "requires_approval=#{requires_approval}"
    ]

    %{
      investigation
      | safety_validation: validation,
        evidence_chain: investigation.evidence_chain ++ [evidence],
        thinking_log: investigation.thinking_log ++ log
    }
  end

  @doc """
  Convert investigation to a proposal for the consensus council.
  """
  @spec to_proposal(t()) :: map()
  def to_proposal(%__MODULE__{} = investigation) do
    hyp = investigation.selected_hypothesis || %{}
    anomaly = investigation.anomaly

    # Classify fix strategy from root cause analysis
    fix_strategy = classify_fix_strategy(investigation)

    # Build impact assessment
    impact = build_impact_assessment(investigation, fix_strategy)

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
        anomaly: anomaly,
        fix_strategy: fix_strategy,
        safety_validation: investigation.safety_validation,
        impact_assessment: impact,
        similar_events_count: length(investigation.similar_events),
        error_categorization: investigation.error_classification,
        codebase_context: investigation.codebase_context
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

  # --- Similar Events Helpers ---

  defp historian_available? do
    Code.ensure_loaded?(Historian) and Process.whereis(Arbor.Historian.Store) != nil
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp similar_to_anomaly?(event, anomaly) do
    # Match by skill/category
    skill_match = to_string(event.category) == to_string(anomaly.skill)

    # Match by keyword overlap in details
    event_text = stringify_map(Map.get(event, :data, %{}))
    anomaly_text = stringify_map(Map.get(anomaly, :details, %{}))
    keyword_match = has_common_keywords?(event_text, anomaly_text)

    skill_match || keyword_match
  end

  defp has_common_keywords?(text_a, text_b) do
    words_a = extract_keywords(text_a)
    words_b = extract_keywords(text_b)
    common = MapSet.intersection(words_a, words_b)
    MapSet.size(common) >= 2
  end

  defp extract_keywords(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/)
    |> Enum.filter(&(String.length(&1) > 3))
    |> MapSet.new()
  end

  defp compute_similarity(event, anomaly) do
    score = 0.0
    score = if to_string(event.category) == to_string(anomaly.skill), do: score + 0.5, else: score

    event_text = stringify_map(Map.get(event, :data, %{}))
    anomaly_text = stringify_map(Map.get(anomaly, :details, %{}))
    event_words = extract_keywords(event_text)
    anomaly_words = extract_keywords(anomaly_text)

    if MapSet.size(anomaly_words) > 0 do
      overlap = MapSet.intersection(event_words, anomaly_words) |> MapSet.size()
      score + 0.5 * (overlap / max(MapSet.size(anomaly_words), 1))
    else
      score
    end
  end

  defp stringify_map(map) when is_map(map) do
    Enum.map_join(map, " ", fn {k, v} -> "#{k} #{inspect(v)}" end)
  end

  defp stringify_map(other), do: inspect(other)

  # --- Codebase Context Extraction ---

  defp gather_codebase_context(anomaly) do
    text = stringify_map(Map.get(anomaly, :details, %{}))

    files = Regex.scan(~r/\b[\w\/]+\.ex[s]?\b/, text) |> List.flatten() |> Enum.uniq()
    modules = Regex.scan(~r/\b[A-Z]\w*(?:\.[A-Z]\w*)+\b/, text) |> List.flatten() |> Enum.uniq()
    functions = Regex.scan(~r/\b\w+\/\d+\b/, text) |> List.flatten() |> Enum.uniq()

    ctx = %{}
    ctx = if files != [], do: Map.put(ctx, :files, files), else: ctx
    ctx = if modules != [], do: Map.put(ctx, :modules, modules), else: ctx
    ctx = if functions != [], do: Map.put(ctx, :functions, functions), else: ctx
    ctx
  end

  # --- Error Categorization Helpers ---

  defp extract_error_text(details) when is_map(details) do
    error = Map.get(details, :error) || Map.get(details, "error") || ""
    message = Map.get(details, :message) || Map.get(details, "message") || ""
    stacktrace = Map.get(details, :stacktrace) || Map.get(details, "stacktrace") || ""

    [to_string(error), to_string(message), to_string(stacktrace)]
    |> Enum.join(" ")
    |> String.trim()
  end

  defp extract_error_text(_), do: ""

  defp classify_error_type(text) do
    downcased = String.downcase(text)

    cond do
      String.contains?(downcased, ["matcherror", "badmatch", "no match", "pattern"]) ->
        :runtime_match

      String.contains?(downcased, ["undefinedfunction", "undefined function", "undef"]) ->
        :runtime_undefined

      String.contains?(downcased, ["argumenterror", "badarg", "bad argument", "functionclause"]) ->
        :runtime_argument

      String.contains?(downcased, ["timeout", "timed out", "genserver call"]) ->
        :runtime_timeout

      String.contains?(downcased, ["compileerror", "compile error", "syntax error"]) ->
        :compile_error

      String.contains?(downcased, ["slow", "performance", "latency", "throughput"]) ->
        :performance

      true ->
        :unknown
    end
  end

  defp classify_error_severity(text) do
    downcased = String.downcase(text)

    cond do
      String.contains?(downcased, ["crash", "halt", "fatal", "segfault", "killed"]) -> :critical
      String.contains?(downcased, ["error", "failure", "failed", "exception"]) -> :error
      String.contains?(downcased, ["warn", "warning", "deprecat"]) -> :warning
      true -> :info
    end
  end

  defp classify_error_category(text) do
    downcased = String.downcase(text)

    cond do
      String.contains?(downcased, [
        "repo",
        "postgres",
        "mysql",
        "ecto",
        "query",
        "sql",
        "database"
      ]) ->
        :database

      String.contains?(downcased, ["socket", "connect", "http", "tcp", "dns", "network"]) ->
        :network

      String.contains?(downcased, ["file", "path", "directory", "enoent", "eacces"]) ->
        :filesystem

      String.contains?(downcased, ["memory", "heap", "alloc", "oom"]) ->
        :memory

      String.contains?(downcased, ["auth", "permission", "denied", "capability", "security"]) ->
        :security

      true ->
        :application
    end
  end

  defp infer_subsystem(text, codebase_context) do
    # Try to infer from module names in codebase context
    modules = (codebase_context || %{})[:modules] || []

    cond do
      Enum.any?(modules, &String.contains?(&1, "Arbor.Agent")) -> :agent
      Enum.any?(modules, &String.contains?(&1, "Arbor.Monitor")) -> :monitor
      Enum.any?(modules, &String.contains?(&1, "Arbor.Security")) -> :security
      Enum.any?(modules, &String.contains?(&1, "Arbor.Consensus")) -> :consensus
      Enum.any?(modules, &String.contains?(&1, "Arbor.AI")) -> :ai
      Enum.any?(modules, &String.contains?(&1, "Arbor.Persistence")) -> :persistence
      String.contains?(text, "GenServer") -> :genserver
      true -> :unknown
    end
  end

  # --- Fix Strategy Classification ---

  defp classify_fix_strategy(investigation) do
    root_cause =
      case investigation.selected_hypothesis do
        %{root_cause: rc} when is_binary(rc) -> String.downcase(rc)
        _ -> ""
      end

    error_type =
      case investigation.error_classification do
        %{error_type: et} -> et
        _ -> nil
      end

    cond do
      investigation.suggested_action in [
        :suppress_fingerprint,
        :reset_baseline,
        :kill_process,
        :force_gc,
        :stop_supervisor
      ] ->
        :runtime_remediation

      error_type in [:runtime_match] || String.contains?(root_cause, ["pattern", "match"]) ->
        :pattern_fix

      error_type in [:runtime_argument] || String.contains?(root_cause, ["type", "argument"]) ->
        :type_safety

      error_type in [:compile_error] || String.contains?(root_cause, ["logic", "algorithm"]) ->
        :logic_refactor

      error_type in [:runtime_timeout, :performance] ||
          String.contains?(root_cause, ["timeout", "performance", "slow"]) ->
        :performance_optimization

      String.contains?(root_cause, ["config", "configuration", "env"]) ->
        :configuration_change

      String.contains?(root_cause, ["race", "concurrency", "deadlock"]) ->
        :concurrency_fix

      String.contains?(root_cause, ["memory", "leak", "heap"]) ->
        :memory_management

      true ->
        nil
    end
  end

  # --- Safety Validation Helpers ---

  @dangerous_patterns [
    {~r/System\.cmd/, "System.cmd — arbitrary command execution"},
    {~r/System\.halt/, "System.halt — VM termination"},
    {~r/:erlang\.halt/, ":erlang.halt — VM termination"},
    {~r/File\.rm/, "File.rm — file deletion"},
    {~r/File\.rm_rf/, "File.rm_rf — recursive file deletion"},
    {~r/Code\.eval_string/, "Code.eval_string — dynamic code evaluation"},
    {~r/Code\.eval_quoted/, "Code.eval_quoted — dynamic code evaluation"},
    {~r/Code\.compile_string/, "Code.compile_string — dynamic compilation"},
    {~r/Application\.stop/, "Application.stop — application shutdown"},
    {~r/delete_all/i, "delete_all — bulk data deletion"},
    {~r/drop\s+table/i, "DROP TABLE — database table deletion"},
    {~r/truncate\s+table/i, "TRUNCATE TABLE — database data wipe"}
  ]

  defp collect_scannable_text(investigation) do
    texts = []

    # Fix code from proposal
    hyp = investigation.selected_hypothesis || %{}
    fix_code = hyp[:fix_code] || ""
    texts = if fix_code != "", do: [fix_code | texts], else: texts

    # AI analysis evidence
    ai_texts =
      investigation.evidence_chain
      |> Enum.filter(&(&1.type == :ai_analysis))
      |> Enum.map(fn e -> get_in(e, [:data, :response]) || "" end)

    texts ++ ai_texts
  end

  defp scan_for_dangerous_patterns(texts) do
    Enum.flat_map(@dangerous_patterns, fn {pattern, description} ->
      if Enum.any?(texts, &Regex.match?(pattern, &1)) do
        [%{pattern: Regex.source(pattern), description: description}]
      else
        []
      end
    end)
  end

  defp validate_runtime_action(:kill_process), do: []
  defp validate_runtime_action(:force_gc), do: []
  defp validate_runtime_action(:stop_supervisor), do: []
  defp validate_runtime_action(:suppress_fingerprint), do: []
  defp validate_runtime_action(:reset_baseline), do: []
  defp validate_runtime_action(:logged_warning), do: []
  defp validate_runtime_action(:none), do: []

  defp validate_runtime_action(action) do
    [%{pattern: "unknown_action", description: "Unknown action: #{action}"}]
  end

  defp generate_id do
    "inv_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp gather_skill_symptoms(%{skill: :processes, details: details}) do
    pid = Map.get(details, :pid) || Map.get(details, :process)

    {pid_symptoms, pid_log} =
      inspect_process_symptom(pid, :process_info, "Anomalous process details", fn info ->
        "Process #{inspect(pid)}: queue=#{info.message_queue_len}, memory=#{info.memory}"
      end)

    # Top processes by message queue
    top_queue = safe_call(fn -> Diagnostics.top_processes_by(:message_queue, 5) end, [])

    {queue_symptoms, queue_log} =
      if top_queue != [] do
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

    {pid_symptoms, pid_log} =
      inspect_process_symptom(pid, :process_memory, "High memory process details", fn info ->
        "Memory process: heap=#{info.heap_size}, total=#{info.total_heap_size}"
      end)

    # Top processes by memory
    top_mem = safe_call(fn -> Diagnostics.top_processes_by(:memory, 5) end, [])

    {mem_symptoms, mem_log} =
      if top_mem != [] do
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

  defp inspect_process_symptom(pid, type, description, log_fn) when is_pid(pid) do
    case safe_call(fn -> Diagnostics.inspect_process(pid) end, nil) do
      nil ->
        {[], []}

      info ->
        {[
           %{
             type: type,
             source: :diagnostics,
             description: description,
             value: info,
             severity: :high,
             timestamp: DateTime.utc_now()
           }
         ], [log_fn.(info)]}
    end
  end

  defp inspect_process_symptom(_pid, _type, _description, _log_fn), do: {[], []}

  defp hypothesize_process_issue(symptoms, anomaly) do
    bloated = find_symptom(symptoms, :bloated_queues)
    process_info = find_symptom(symptoms, :process_info)
    details = anomaly.details || %{}

    # Hypothesis 1: Message queue flood
    bloated_hyp =
      if bloated && is_list(bloated.value) && bloated.value != [] do
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
      if top_memory && is_list(top_memory.value) && top_memory.value != [] do
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

  defp hypothesize_beam_issue(symptoms, anomaly) do
    process_count = find_symptom(symptoms, :process_count)
    bloated = find_symptom(symptoms, :bloated_queues)

    # Hypothesis 1: Process leak (global threshold)
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

    # Hypothesis 3+: EWMA deviation-based hypotheses from anomaly details
    deviation_hyp = hypothesize_from_deviation(anomaly)

    leak_hyp ++ overload_hyp ++ deviation_hyp
  end

  defp hypothesize_from_deviation(%{details: details, skill: skill})
       when is_map(details) do
    metric = Map.get(details, :metric)
    value = Map.get(details, :value)
    ewma = Map.get(details, :ewma)
    stddev = Map.get(details, :stddev)
    deviation_stddevs = Map.get(details, :deviation_stddevs)

    cond do
      # Not enough data for deviation analysis
      is_nil(metric) or is_nil(value) or is_nil(ewma) ->
        []

      # Low deviation — likely noise, suppress the fingerprint
      is_number(deviation_stddevs) and deviation_stddevs < 4.0 ->
        [
          %{
            id: generate_id(),
            root_cause:
              "#{skill}/#{metric} at #{format_number(value)}, " <>
                "#{format_number(deviation_stddevs)} stddevs from baseline #{format_number(ewma)} " <>
                "(likely noise)",
            confidence: 0.60,
            evidence: [
              %{
                type: :deviation,
                description: "Low EWMA deviation — below 4.0 stddevs threshold",
                data: %{
                  metric: metric,
                  value: value,
                  ewma: ewma,
                  stddev: stddev,
                  deviation_stddevs: deviation_stddevs
                },
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :suppress_fingerprint,
            action_target: nil
          }
        ]

      # High deviation — baseline may have drifted, reset it
      is_number(deviation_stddevs) and deviation_stddevs >= 4.0 ->
        [
          %{
            id: generate_id(),
            root_cause:
              "#{skill}/#{metric} at #{format_number(value)}, " <>
                "#{format_number(deviation_stddevs)} stddevs from baseline #{format_number(ewma)} " <>
                "(baseline drift)",
            confidence: 0.65,
            evidence: [
              %{
                type: :deviation,
                description: "High EWMA deviation — baseline may have drifted",
                data: %{
                  metric: metric,
                  value: value,
                  ewma: ewma,
                  stddev: stddev,
                  deviation_stddevs: deviation_stddevs
                },
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :reset_baseline,
            action_target: nil
          }
        ]

      # Has metric data but no deviation_stddevs — generate descriptive hypothesis
      true ->
        [
          %{
            id: generate_id(),
            root_cause:
              "#{skill}/#{metric} anomaly: value #{format_number(value)}, " <>
                "baseline #{format_number(ewma)}",
            confidence: 0.50,
            evidence: [
              %{
                type: :deviation,
                description: "Metric deviation detected without stddev data",
                data: %{metric: metric, value: value, ewma: ewma},
                timestamp: DateTime.utc_now()
              }
            ],
            suggested_action: :logged_warning,
            action_target: nil
          }
        ]
    end
  end

  defp hypothesize_from_deviation(_anomaly), do: []

  defp format_number(n) when is_float(n), do: Float.round(n, 2) |> to_string()
  defp format_number(n) when is_integer(n), do: to_string(n)
  defp format_number(n), do: inspect(n)

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
    # Try deviation-based hypothesis first for any skill with EWMA data
    deviation_hyp = hypothesize_from_deviation(anomaly)

    fallback_hyp = [
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

    if deviation_hyp != [], do: deviation_hyp ++ fallback_hyp, else: fallback_hyp
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
      Enum.map_join(investigation.symptoms, "\n", fn s ->
        "- #{s.description}: #{inspect(s.value)}"
      end)

    hypotheses_text =
      Enum.map_join(investigation.hypotheses, "\n", fn h ->
        "- #{h.root_cause} (confidence: #{h.confidence})"
      end)

    details = investigation.anomaly.details || %{}

    details_text =
      Enum.map_join(details, "\n", fn {k, v} ->
        "  #{k}: #{inspect(v)}"
      end)

    """
    Analyze this BEAM runtime investigation and refine the diagnosis.

    ## Anomaly
    Skill: #{investigation.anomaly.skill}
    Severity: #{investigation.anomaly.severity}
    Details:
    #{details_text}

    ## Symptoms Gathered
    #{symptoms_text}

    ## Current Hypotheses
    #{hypotheses_text}

    ## Instructions
    Respond with a JSON object (no other text):
    ```json
    {
      "root_cause": "Brief description of the most likely root cause",
      "suggested_action": "one of: kill_process, force_gc, stop_supervisor, suppress_fingerprint, reset_baseline, logged_warning, none",
      "confidence": 0.0 to 1.0,
      "reasoning": "Why this action is appropriate"
    }
    ```

    Valid actions:
    - kill_process: Kill a specific runaway process
    - force_gc: Force garbage collection on a bloated process
    - stop_supervisor: Stop a failing supervisor tree
    - suppress_fingerprint: Suppress this anomaly for 30 minutes (noise/false positive)
    - reset_baseline: Reset the EWMA baseline for this metric (baseline drift)
    - logged_warning: Log for human review, no automated action
    - none: No action needed
    """
  end

  defp parse_ai_response(investigation, response) do
    # Extract text from response map (Arbor.AI returns %{text: ..., usage: ...})
    text = extract_response_text(response)

    case extract_json(text) do
      {:ok, parsed} when is_map(parsed) ->
        parse_ai_json_response(investigation, parsed, text)

      _ ->
        # Fallback: regex-based confidence extraction
        parse_ai_text_response(investigation, text)
    end
  end

  defp parse_ai_json_response(investigation, parsed, raw_text) do
    ai_confidence = parse_confidence(parsed["confidence"])
    ai_action = parse_action(parsed["suggested_action"])
    ai_root_cause = parsed["root_cause"]
    ai_reasoning = parsed["reasoning"]

    # Build AI hypothesis
    ai_hypothesis = %{
      id: generate_id(),
      root_cause: ai_root_cause || "AI analysis",
      confidence: ai_confidence || investigation.confidence,
      evidence: [
        %{
          type: :ai_analysis,
          description: "AI diagnostic: #{ai_reasoning || "no reasoning provided"}",
          data: %{response: String.slice(raw_text, 0, 500)},
          timestamp: DateTime.utc_now()
        }
      ],
      suggested_action: ai_action || investigation.suggested_action,
      action_target: nil
    }

    # If AI confidence is higher, promote AI hypothesis to selected
    effective_confidence = ai_confidence || investigation.confidence

    if effective_confidence > investigation.confidence do
      %{
        investigation
        | confidence: effective_confidence,
          selected_hypothesis: ai_hypothesis,
          suggested_action: ai_action || investigation.suggested_action,
          hypotheses: [ai_hypothesis | investigation.hypotheses],
          evidence_chain: investigation.evidence_chain ++ ai_hypothesis.evidence
      }
    else
      %{
        investigation
        | hypotheses: investigation.hypotheses ++ [ai_hypothesis],
          evidence_chain: investigation.evidence_chain ++ ai_hypothesis.evidence
      }
    end
  end

  defp parse_ai_text_response(investigation, text) do
    # Fallback: extract confidence via regex
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

  # Multi-strategy JSON extraction (markdown fence → raw decode → brace match)
  defp extract_json(text) when is_binary(text) do
    # Strategy 1: JSON in markdown code fence
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?```/s, text) do
      [_, json_str] ->
        case Jason.decode(String.trim(json_str)) do
          {:ok, parsed} -> {:ok, parsed}
          _ -> extract_json_direct(text)
        end

      nil ->
        extract_json_direct(text)
    end
  end

  defp extract_json(_), do: {:error, :not_text}

  defp extract_json_direct(text) do
    # Strategy 2: Direct decode of trimmed text
    case Jason.decode(String.trim(text)) do
      {:ok, parsed} ->
        {:ok, parsed}

      _ ->
        # Strategy 3: Find first JSON object via brace matching
        case Regex.run(~r/\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}/s, text) do
          [json_str] -> Jason.decode(json_str)
          _ -> {:error, :no_json}
        end
    end
  end

  defp parse_confidence(val) when is_float(val) and val >= 0.0 and val <= 1.0, do: val
  defp parse_confidence(val) when is_float(val) and val > 1.0, do: val / 100.0
  defp parse_confidence(val) when is_integer(val) and val >= 0 and val <= 1, do: val / 1.0
  defp parse_confidence(val) when is_integer(val) and val > 1, do: val / 100.0
  defp parse_confidence(_), do: nil

  @valid_actions ~w(kill_process force_gc stop_supervisor suppress_fingerprint reset_baseline logged_warning none)a

  defp parse_action(str) when is_binary(str) do
    atom =
      try do
        String.to_existing_atom(str)
      rescue
        ArgumentError -> nil
      end

    if atom in @valid_actions, do: atom, else: nil
  end

  defp parse_action(_), do: nil

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

  defp describe_action(:suppress_fingerprint, _),
    do: "Suppress anomaly fingerprint for 30 minutes"

  defp describe_action(:reset_baseline, _), do: "Reset EWMA baseline for metric"
  defp describe_action(:none, _), do: "No action"
  defp describe_action(action, _), do: "#{action}"

  defp build_impact_assessment(investigation, fix_strategy) do
    action = investigation.suggested_action
    similar_count = length(investigation.similar_events)
    safety = investigation.safety_validation

    scope =
      cond do
        action in [:kill_process, :force_gc] -> :single_process
        action in [:stop_supervisor] -> :supervisor_tree
        action in [:suppress_fingerprint, :reset_baseline] -> :monitoring
        action in [:logged_warning, :none] -> :none
        true -> :unknown
      end

    risk_level =
      cond do
        safety && safety.safety_score < 40 -> :high
        action in [:stop_supervisor] -> :medium
        action in [:kill_process] -> :medium
        action in [:force_gc, :suppress_fingerprint, :reset_baseline] -> :low
        true -> :low
      end

    %{
      scope: scope,
      risk_level: risk_level,
      breaking_changes: action in [:kill_process, :stop_supervisor],
      monitoring_needs: similar_count > 3,
      fix_strategy: fix_strategy,
      recurrence_likelihood: if(similar_count > 5, do: :high, else: :low)
    }
  end

  # Extract text string from various AI response formats.
  # Handles plain maps, structs, and raw strings safely.
  defp extract_response_text(response) when is_binary(response), do: response

  defp extract_response_text(response) when is_struct(response) do
    Map.get(response, :text) || Map.get(response, :content) || inspect(response)
  end

  defp extract_response_text(response) when is_map(response) do
    response[:text] || response["text"] || response[:content] || response["content"] ||
      inspect(response)
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
