defmodule Arbor.Agent.Eval.SummarizationEval do
  @moduledoc """
  Compares LLM models for context summarization quality.

  Tests each model's ability to compress conversation message batches
  while preserving key information (file paths, modules, person names,
  emotional markers, concepts).

  ## Usage

      # Quick test with one model
      SummarizationEval.run(models: [{"openrouter", "sambanova/trinity-large"}])

      # Full comparison
      SummarizationEval.run(
        models: [
          {"openrouter", "anthropic/claude-3-5-haiku-latest"},
          {"openrouter", "google/gemini-3-flash-preview"},
          {"openrouter", "sambanova/trinity-large"}
        ],
        transcripts: [:coding, :relational, :mixed]
      )

  ## Persistence

  Results are stored via EvalRun/EvalResult:
    - One EvalRun per model (domain: "summarization")
    - One EvalResult per transcript_type × batch_size within that run
  """

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.CompactionEval
  alias Arbor.Agent.Eval.RelationalTranscript

  require Logger

  @batch_sizes [4, 8, 16]
  @default_timeout 60_000
  @default_transcripts [:coding, :relational, :mixed]
  @prompt_strategies [:narrative, :structured, :extractive]

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Run summarization eval for one or more models.

  ## Options

    * `:models` - List of `{provider, model}` tuples (required)
    * `:transcripts` - Transcript types to test (default: [:coding, :relational, :mixed])
    * `:batch_sizes` - Message batch sizes to test (default: [4, 8, 16])
    * `:timeout` - Per-request timeout in ms (default: 60_000)
    * `:persist` - Whether to persist results (default: true)
    * `:tag` - Tag for identifying runs
    * `:prompt_strategies` - Prompt strategies to test (default: all)
  """
  @spec run(keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(opts \\ []) do
    models = Keyword.fetch!(opts, :models)
    transcript_types = Keyword.get(opts, :transcripts, @default_transcripts)
    batch_sizes = Keyword.get(opts, :batch_sizes, @batch_sizes)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    persist = Keyword.get(opts, :persist, true)
    tag = Keyword.get(opts, :tag)
    strategies = Keyword.get(opts, :prompt_strategies, @prompt_strategies)

    Logger.info(
      "[SummarizationEval] Starting: #{length(models)} model(s), " <>
        "#{length(transcript_types)} transcript type(s), " <>
        "#{length(batch_sizes)} batch size(s), " <>
        "#{length(strategies)} strategy(ies)"
    )

    transcripts = generate_test_transcripts(transcript_types)

    results =
      Enum.map(models, fn {provider, model} ->
        Logger.info("[SummarizationEval] Testing model: #{model} (#{provider})")

        batch_results =
          for transcript_type <- transcript_types,
              batch_size <- batch_sizes,
              strategy <- strategies do
            transcript = Map.fetch!(transcripts, transcript_type)
            messages = CompactionEval.reconstruct_messages(transcript)
            ground_truth = CompactionEval.extract_ground_truth(transcript)

            batches = extract_batches(messages, batch_size)

            if batches == [] do
              Logger.warning(
                "[SummarizationEval] No batches of size #{batch_size} " <>
                  "for #{transcript_type} transcript (#{length(messages)} messages)"
              )

              nil
            else
              # Use the first batch that has enough messages
              {batch_messages, _batch_idx} = hd(batches)

              run_single(
                provider,
                model,
                batch_messages,
                messages,
                ground_truth,
                transcript_type,
                batch_size,
                strategy,
                timeout
              )
            end
          end
          |> Enum.reject(&is_nil/1)

        model_result = %{
          model: model,
          provider: provider,
          results: batch_results,
          best_retention: best_retention(batch_results),
          avg_timing_ms: avg_timing(batch_results),
          total_cost: total_cost(batch_results)
        }

        if persist do
          persist_results(model_result, tag)
        end

        print_model_results(model_result)

        model_result
      end)

    if length(results) > 1 do
      print_comparison(results)
    end

    {:ok, results}
  end

  @doc """
  Run a single summarization for a specific model, transcript type, batch size, and strategy.

  Returns a map with retention metrics, timing, and cost.
  """
  @spec run_single(
          String.t(),
          String.t(),
          [map()],
          [map()],
          map(),
          atom(),
          non_neg_integer(),
          atom(),
          non_neg_integer()
        ) :: map()
  def run_single(
        provider,
        model,
        batch_messages,
        original_messages,
        ground_truth,
        transcript_type,
        batch_size,
        strategy,
        timeout
      ) do
    prompt = build_prompt(batch_messages, strategy)
    input_tokens = estimate_batch_tokens(batch_messages)

    start = System.monotonic_time(:millisecond)

    case call_llm(provider, model, prompt, timeout) do
      {:ok, %{text: summary_text, cost: cost}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        output_tokens = ContextCompactor.estimate_tokens(summary_text)

        retention = score_summary(summary_text, original_messages, ground_truth)

        compression_ratio =
          if input_tokens > 0 do
            Float.round(1.0 - output_tokens / input_tokens, 3)
          else
            0.0
          end

        Logger.info(
          "[SummarizationEval] #{transcript_type}/#{batch_size}/#{strategy}: " <>
            "retention=#{retention.retention_score}, " <>
            "compression=#{compression_ratio}, " <>
            "time=#{elapsed}ms"
        )

        %{
          transcript_type: transcript_type,
          batch_size: batch_size,
          prompt_strategy: strategy,
          retention_score: retention.retention_score,
          path_retention: retention.path_retention,
          module_retention: retention.module_retention,
          concept_retention: retention.concept_retention,
          person_name_retention: retention.person_name_retention,
          emotional_retention: retention.emotional_retention,
          dynamic_retention: retention.dynamic_retention,
          value_retention: retention.value_retention,
          compression_ratio: compression_ratio,
          timing_ms: elapsed,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost: cost,
          summary_length: String.length(summary_text),
          error: nil
        }

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start

        Logger.warning(
          "[SummarizationEval] #{transcript_type}/#{batch_size}/#{strategy} failed: #{inspect(reason)}"
        )

        %{
          transcript_type: transcript_type,
          batch_size: batch_size,
          prompt_strategy: strategy,
          retention_score: 0.0,
          path_retention: 0.0,
          module_retention: 0.0,
          concept_retention: 0.0,
          person_name_retention: 0.0,
          emotional_retention: 0.0,
          dynamic_retention: 0.0,
          value_retention: 0.0,
          compression_ratio: 0.0,
          timing_ms: elapsed,
          input_tokens: 0,
          output_tokens: 0,
          cost: 0.0,
          summary_length: 0,
          error: inspect(reason)
        }
    end
  end

  # ── Transcript Generation ──────────────────────────────────────

  @doc """
  Generate test transcripts for the specified types.

  Returns `%{coding: transcript, relational: transcript, mixed: transcript}`.
  """
  @spec generate_test_transcripts([atom()]) :: %{atom() => map()}
  def generate_test_transcripts(types \\ @default_transcripts) do
    Map.new(types, fn type ->
      {type, generate_transcript(type)}
    end)
  end

  @doc false
  def generate_transcript(:coding) do
    %{
      "task" => "Analyze the Arbor agent architecture and identify key patterns",
      "model" => "synthetic-coding-eval",
      "status" => "completed",
      "turns" => 12,
      "text" =>
        "The codebase uses a three-loop architecture with heartbeat, action cycle, " <>
          "and maintenance loops. The supervisor tree manages lifecycle through " <>
          "DynamicSupervisor with Registry. Memory persistence uses a BufferedStore " <>
          "pattern with ETS cache and Postgres backing. The ContextCompactor implements " <>
          "progressive forgetting via semantic squashing and detail level decay.",
      "tool_calls" => [
        %{
          "turn" => 1,
          "name" => "file_list",
          "args" => %{"path" => "apps/arbor_agent/lib/arbor/agent/"},
          "result" =>
            Jason.encode!(%{
              "entries" => [
                "api_agent.ex",
                "context_compactor.ex",
                "heartbeat_prompt.ex",
                "lifecycle.ex",
                "executor.ex",
                "action_cycle_server.ex",
                "maintenance_server.ex"
              ],
              "path" => "apps/arbor_agent/lib/arbor/agent/",
              "count" => 7
            })
        },
        %{
          "turn" => 2,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_agent/lib/arbor/agent/api_agent.ex"},
          "result" =>
            "apps/arbor_agent/lib/arbor/agent/api_agent.ex\n" <>
              "defmodule Arbor.Agent.APIAgent do\n" <>
              "  use GenServer\n" <>
              "  alias Arbor.Agent.Lifecycle\n" <>
              "  alias Arbor.Agent.Executor\n\n" <>
              "  def start_link(opts) do\n    GenServer.start_link(__MODULE__, opts)\n  end\n\n" <>
              "  def init(opts) do\n    {:ok, build_initial_state(opts)}\n  end\n\n" <>
              "  def handle_call({:chat, message}, from, state) do\n" <>
              "    # Async query via Task to avoid blocking\n" <>
              "    Task.start(fn -> process_query(message, from, state) end)\n" <>
              "    {:noreply, state}\n  end\n" <>
              String.duplicate("  # Agent lifecycle management\n", 15)
        },
        %{
          "turn" => 3,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_agent/lib/arbor/agent/lifecycle.ex"},
          "result" =>
            "apps/arbor_agent/lib/arbor/agent/lifecycle.ex\n" <>
              "defmodule Arbor.Agent.Lifecycle do\n" <>
              "  alias Arbor.Security\n" <>
              "  alias Arbor.Persistence\n\n" <>
              "  def create(template, opts) do\n    # Create agent with crypto identity\n  end\n\n" <>
              "  def start(agent_id) do\n    # Start supervised agent process\n  end\n\n" <>
              "  def build_signer(agent_id) do\n    # Create signing function for identity\n  end\n" <>
              String.duplicate("  # Lifecycle state machine\n", 10)
        },
        %{
          "turn" => 4,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_agent/lib/arbor/agent/context_compactor.ex"},
          "result" =>
            "apps/arbor_agent/lib/arbor/agent/context_compactor.ex\n" <>
              "defmodule Arbor.Agent.ContextCompactor do\n" <>
              "  @moduledoc \"Progressive context compaction with semantic squashing.\"\n\n" <>
              "  defstruct [:effective_window, :config, full_transcript: [], llm_messages: []]\n\n" <>
              "  def new(opts) do\n    # Initialize with model-aware window\n  end\n\n" <>
              "  def append(compactor, message) do\n    # Add to both transcripts\n  end\n\n" <>
              "  def maybe_compact(compactor) do\n    # 4-step pipeline: squash, decay, narrative, enrich\n  end\n" <>
              String.duplicate("  # Compaction internals\n", 15)
        },
        %{
          "turn" => 5,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_agent/lib/arbor/agent/executor.ex"},
          "result" =>
            "apps/arbor_agent/lib/arbor/agent/executor.ex\n" <>
              "defmodule Arbor.Agent.Executor do\n" <>
              "  alias Arbor.Actions\n" <>
              "  alias Arbor.Security\n\n" <>
              "  def execute(action_module, params, context) do\n" <>
              "    # Authorize then execute through ToolBridge\n  end\n" <>
              String.duplicate("  # Execution pipeline with security checks\n", 10)
        },
        %{
          "turn" => 6,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_agent/lib/arbor/agent/action_cycle_server.ex"},
          "result" =>
            "apps/arbor_agent/lib/arbor/agent/action_cycle_server.ex\n" <>
              "defmodule Arbor.Agent.ActionCycleServer do\n" <>
              "  use GenServer\n" <>
              "  alias Arbor.Agent.MentalExecutor\n\n" <>
              "  def start_link(opts) do\n    GenServer.start_link(__MODULE__, opts)\n  end\n\n" <>
              "  def handle_info({:percept, percept}, state) do\n" <>
              "    # Process percepts from execution results\n  end\n" <>
              String.duplicate("  # Action cycle with mental/physical split\n", 10)
        },
        %{
          "turn" => 7,
          "name" => "file_list",
          "args" => %{"path" => "apps/arbor_memory/lib/arbor/memory/"},
          "result" =>
            Jason.encode!(%{
              "entries" => [
                "goal_store.ex",
                "intent_store.ex",
                "working_memory.ex",
                "self_knowledge.ex",
                "thinking.ex"
              ],
              "path" => "apps/arbor_memory/lib/arbor/memory/",
              "count" => 5
            })
        },
        %{
          "turn" => 8,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_memory/lib/arbor/memory/goal_store.ex"},
          "result" =>
            "apps/arbor_memory/lib/arbor/memory/goal_store.ex\n" <>
              "defmodule Arbor.Memory.GoalStore do\n" <>
              "  use GenServer\n" <>
              "  alias Arbor.Persistence.BufferedStore\n\n" <>
              "  def add_goal(agent_id, description, opts) do\n" <>
              "    # BDI goal with decomposition support\n  end\n\n" <>
              "  def load_all(agent_id) do\n    # Restore from durable store on restart\n  end\n" <>
              String.duplicate("  # Goal lifecycle management\n", 10)
        },
        %{
          "turn" => 9,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_memory/lib/arbor/memory/working_memory.ex"},
          "result" =>
            "apps/arbor_memory/lib/arbor/memory/working_memory.ex\n" <>
              "defmodule Arbor.Memory.WorkingMemory do\n" <>
              "  @moduledoc \"Short-term working memory with temporal annotations.\"\n\n" <>
              "  defstruct [:thoughts, :observations, :concerns, :curiosities]\n\n" <>
              "  def format_thoughts(wm) do\n    # Format for LLM context with timestamps\n  end\n" <>
              String.duplicate("  # Working memory operations\n", 10)
        },
        %{
          "turn" => 10,
          "name" => "file_read",
          "args" => %{"path" => "apps/arbor_persistence/lib/arbor/persistence/buffered_store.ex"},
          "result" =>
            "apps/arbor_persistence/lib/arbor/persistence/buffered_store.ex\n" <>
              "defmodule Arbor.Persistence.BufferedStore do\n" <>
              "  use GenServer\n" <>
              "  @moduledoc \"ETS cache + pluggable backend persistence.\"\n\n" <>
              "  def put(store, key, record) do\n" <>
              "    # Write-through: ETS + async backend persist\n  end\n\n" <>
              "  def get(store, key) do\n    # Read from ETS first, fall back to backend\n  end\n" <>
              String.duplicate("  # Buffered persistence internals\n", 10)
        }
      ]
    }
  end

  def generate_transcript(:relational) do
    RelationalTranscript.generate(people: 3, self_insights: 4, recall_rounds: 2)
  end

  def generate_transcript(:mixed) do
    coding = generate_transcript(:coding)
    relational = generate_transcript(:relational)

    coding_calls = Enum.take(coding["tool_calls"], 5)
    relational_calls = Enum.take(relational["tool_calls"], 8)

    # Interleave: coding, relational, coding, relational...
    mixed_calls =
      interleave(coding_calls, relational_calls)
      |> Enum.with_index(1)
      |> Enum.map(fn {tc, idx} -> Map.put(tc, "turn", idx) end)

    %{
      "task" =>
        "Review the codebase architecture and reflect on your relationships " <>
          "and recent interactions. Combine technical understanding with personal growth.",
      "text" =>
        "The codebase uses a three-loop architecture. " <>
          "Relationships with Hysun and Dr. Chen continue to deepen. " <>
          "BufferedStore provides the persistence backbone.",
      "tool_calls" => mixed_calls,
      "model" => "synthetic-mixed-eval",
      "turns" => length(mixed_calls),
      "status" => "completed"
    }
  end

  # ── Batch Extraction ──────────────────────────────────────────

  @doc """
  Extract message batches of the given size from a message list.

  Skips system and initial user messages. Returns batches from the
  middle of the conversation (the oldest messages that would be
  candidates for compaction).

  Returns `[{batch_messages, batch_index}]`.
  """
  @spec extract_batches([map()], non_neg_integer()) :: [{[map()], non_neg_integer()}]
  def extract_batches(messages, batch_size) do
    # Skip system + user messages at the start (first 2)
    compactable = Enum.drop(messages, 2)

    if length(compactable) < batch_size do
      []
    else
      # Take one batch from the oldest compactable messages
      # (this is what the compactor would actually summarize)
      batch = Enum.take(compactable, batch_size)
      [{batch, 0}]
    end
  end

  # ── Scoring ──────────────────────────────────────────────────

  @doc """
  Score a summary against the original messages and ground truth.

  Builds a temporary ContextCompactor where `llm_messages` contains
  only the summary, then uses `CompactionEval.measure_retention/2`
  to get retention metrics.
  """
  @spec score_summary(String.t(), [map()], map()) :: map()
  def score_summary(summary_text, original_messages, ground_truth) do
    # Build a temporary compactor with the summary as the LLM view
    summary_msg = %{
      role: :assistant,
      content: "[Context Summary] #{summary_text}"
    }

    temp_compactor = %ContextCompactor{
      llm_messages: [summary_msg],
      full_transcript: original_messages,
      token_count: ContextCompactor.estimate_tokens(summary_msg),
      peak_tokens: estimate_batch_tokens(original_messages),
      effective_window: 999_999,
      turn: length(original_messages),
      config: %{
        effective_window: 999_999,
        compaction_model: nil,
        compaction_provider: nil,
        enable_llm_compaction: false
      }
    }

    CompactionEval.measure_retention(temp_compactor, ground_truth)
  end

  # ── Prompt Strategies ──────────────────────────────────────────

  @doc """
  Build the summarization prompt using the given strategy.

  Strategies:
    * `:narrative` — concise 2-3 sentence paragraph (baseline)
    * `:structured` — sectioned prose requesting file paths and modules
    * `:extractive` — numbered sections for maximum information preservation
  """
  @spec build_prompt([map()], atom()) :: String.t()
  def build_prompt(messages, strategy \\ :narrative)

  def build_prompt(messages, :narrative) do
    formatted = format_messages(messages)

    """
    Summarize these agent actions into a concise narrative paragraph (2-3 sentences).
    Preserve: what was attempted, what succeeded, what failed, and key findings.
    Failed attempts are especially important — note what didn't work and why.

    Messages:
    #{formatted}

    Write only the summary paragraph, nothing else.
    """
  end

  def build_prompt(messages, :structured) do
    formatted = format_messages(messages)

    """
    Summarize these agent actions, preserving specific technical details.

    Include ALL of the following in your summary:
    - Every file path that was read or modified (use the full path)
    - Every module or class name found in those files
    - Key architectural patterns or decisions discovered
    - What succeeded and what failed

    Messages:
    #{formatted}

    Write a structured summary with file paths and module names included inline. Do not omit any file paths or module names from the messages above.
    """
  end

  def build_prompt(messages, :extractive) do
    formatted = format_messages(messages)

    """
    Extract and preserve key information from these agent actions.

    You MUST include ALL of the following:
    1. FILES: List every file path mentioned (e.g., apps/arbor_agent/lib/arbor/agent/api_agent.ex)
    2. MODULES: List every module/class name found (e.g., Arbor.Agent.APIAgent)
    3. CONCEPTS: List key architectural concepts or patterns discovered
    4. PEOPLE: List any person names mentioned (or "none" if none)
    5. SUMMARY: One sentence describing what was accomplished

    Messages:
    #{formatted}

    Respond with the numbered sections above. Do NOT omit any file paths or module names from the messages.
    """
  end

  @doc false
  def format_messages(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role", :unknown)

      content =
        (Map.get(msg, :content) || Map.get(msg, "content", ""))
        |> to_string()
        |> String.slice(0, 300)

      name = Map.get(msg, :name) || Map.get(msg, "name")

      if name do
        "  [#{role}:#{name}] #{content}"
      else
        "  [#{role}] #{content}"
      end
    end)
  end

  @doc """
  Build the narrative prompt for summarization (legacy — delegates to build_prompt/2).
  """
  @spec build_narrative_prompt([map()]) :: String.t()
  def build_narrative_prompt(messages), do: build_prompt(messages, :narrative)

  # ── LLM Call ──────────────────────────────────────────────────

  defp call_llm(provider, model, prompt, timeout) do
    client_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Client])
    request_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Request])
    message_mod = Module.concat([:Arbor, :Orchestrator, :UnifiedLLM, :Message])

    if Code.ensure_loaded?(client_mod) and Code.ensure_loaded?(request_mod) and
         Code.ensure_loaded?(message_mod) do
      messages = [
        struct(message_mod, %{role: :user, content: prompt})
      ]

      request =
        struct(request_mod, %{
          provider: provider,
          model: model,
          messages: messages,
          max_tokens: 1000,
          temperature: 0.0
        })

      client = apply(client_mod, :from_env, [[]])

      case apply(client_mod, :complete, [client, request, [timeout: timeout]]) do
        {:ok, response} ->
          text = Map.get(response, :text, "")
          cost = get_in(response, [Access.key(:usage, %{}), Access.key(:cost, 0.0)]) || 0.0
          {:ok, %{text: text, cost: cost}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unified_llm_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp estimate_batch_tokens(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + ContextCompactor.estimate_tokens(msg)
    end)
  end

  defp interleave([], right), do: right
  defp interleave(left, []), do: left
  defp interleave([l | left], [r | right]), do: [l, r | interleave(left, right)]

  defp best_retention(results) do
    results
    |> Enum.filter(&is_nil(&1.error))
    |> Enum.map(& &1.retention_score)
    |> case do
      [] -> 0.0
      scores -> Enum.max(scores)
    end
  end

  defp avg_timing(results) do
    successful = Enum.filter(results, &is_nil(&1.error))

    if successful == [] do
      0
    else
      total = Enum.sum(Enum.map(successful, & &1.timing_ms))
      div(total, length(successful))
    end
  end

  defp total_cost(results) do
    results
    |> Enum.filter(&is_nil(&1.error))
    |> Enum.map(& &1.cost)
    |> Enum.sum()
    |> Float.round(6)
  end

  # ── Persistence ──────────────────────────────────────────────

  defp persist_results(model_result, tag) do
    run_id = "sum_#{sanitize(model_result.model)}_#{:erlang.unique_integer([:positive])}"

    total_duration =
      model_result.results
      |> Enum.map(& &1.timing_ms)
      |> Enum.sum()

    run_attrs = %{
      id: run_id,
      domain: "summarization",
      model: model_result.model,
      provider: model_result.provider,
      dataset: "synthetic_transcripts",
      graders: ["retention_scoring"],
      sample_count: length(model_result.results),
      duration_ms: round(total_duration),
      metrics: %{
        "best_retention" => model_result.best_retention,
        "avg_timing_ms" => model_result.avg_timing_ms,
        "total_cost" => model_result.total_cost,
        "results_count" => length(model_result.results)
      },
      config: %{
        "model" => model_result.model,
        "provider" => model_result.provider
      },
      metadata: if(tag, do: %{"tag" => tag}, else: %{}),
      status: "completed"
    }

    case persist_run(run_attrs) do
      {:ok, _} ->
        persist_eval_results(run_id, model_result.results)
        Logger.debug("[SummarizationEval] Persisted run #{run_id}")

      {:error, reason} ->
        Logger.warning("[SummarizationEval] Failed to persist run: #{inspect(reason)}")
    end
  end

  defp persist_eval_results(run_id, results) do
    result_attrs =
      Enum.map(results, fn r ->
        strategy = Map.get(r, :prompt_strategy, :narrative)
        sample_id = "#{r.transcript_type}_batch#{r.batch_size}_#{strategy}"

        %{
          id: "#{run_id}_#{sample_id}",
          run_id: run_id,
          sample_id: sample_id,
          input:
            "#{r.transcript_type} transcript, #{r.batch_size} message batch, #{strategy} prompt",
          actual: "retention: #{r.retention_score}",
          passed: is_nil(r.error) and r.retention_score >= 0.5,
          scores: %{
            "retention_score" => r.retention_score,
            "path_retention" => r.path_retention,
            "module_retention" => r.module_retention,
            "concept_retention" => r.concept_retention,
            "person_name_retention" => r.person_name_retention,
            "emotional_retention" => r.emotional_retention,
            "compression_ratio" => r.compression_ratio
          },
          duration_ms: r.timing_ms,
          tokens_generated: r.output_tokens,
          metadata: %{
            "transcript_type" => to_string(r.transcript_type),
            "batch_size" => r.batch_size,
            "prompt_strategy" => to_string(strategy),
            "input_tokens" => r.input_tokens,
            "output_tokens" => r.output_tokens,
            "cost" => r.cost,
            "error" => r.error
          }
        }
      end)

    persist_results_batch(result_attrs)
  end

  defp persist_run(attrs) do
    if Code.ensure_loaded?(Arbor.Persistence) and
         function_exported?(Arbor.Persistence, :insert_eval_run, 1) do
      apply(Arbor.Persistence, :insert_eval_run, [attrs])
    else
      {:error, :persistence_unavailable}
    end
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  defp persist_results_batch(results) do
    if Code.ensure_loaded?(Arbor.Persistence) and
         function_exported?(Arbor.Persistence, :insert_eval_results_batch, 1) do
      apply(Arbor.Persistence, :insert_eval_results_batch, [results])
    else
      {:error, :persistence_unavailable}
    end
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  defp sanitize(model_name) do
    model_name
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    |> String.slice(0, 40)
  end

  # ── Output ──────────────────────────────────────────────────

  defp print_model_results(result) do
    IO.puts("\n== #{result.model} (#{result.provider}) ==")
    IO.puts("")

    header =
      pad("Type", 10) <>
        pad("Batch", 7) <>
        pad("Strategy", 12) <>
        pad("Retain", 8) <>
        pad("Paths", 7) <>
        pad("Mods", 7) <>
        pad("People", 8) <>
        pad("Comp%", 7) <>
        pad("Time", 8) <>
        "Cost"

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    for r <- result.results do
      type_str =
        case r.transcript_type do
          :relational -> "relat"
          other -> to_string(other)
        end

      strategy_str = to_string(Map.get(r, :prompt_strategy, :narrative))

      IO.puts(
        pad(type_str, 10) <>
          pad("#{r.batch_size}", 7) <>
          pad(strategy_str, 12) <>
          pad("#{r.retention_score}", 8) <>
          pad(format_pct(r.path_retention), 7) <>
          pad(format_pct(r.module_retention), 7) <>
          pad(format_pct(r.person_name_retention), 8) <>
          pad(format_pct(r.compression_ratio), 7) <>
          pad("#{r.timing_ms}ms", 8) <>
          format_cost(r.cost)
      )
    end

    IO.puts("")
  end

  defp print_comparison(results) do
    IO.puts("\n── Comparison Summary ──\n")

    sorted = Enum.sort_by(results, & &1.best_retention, :desc)

    for {r, idx} <- Enum.with_index(sorted, 1) do
      label =
        if idx == 1,
          do: "BEST",
          else: ""

      IO.puts(
        "  #{idx}. #{pad(r.model, 45)} " <>
          "retention=#{r.best_retention}  " <>
          "avg=#{r.avg_timing_ms}ms  " <>
          "cost=$#{Float.round(r.total_cost, 4)}  " <>
          label
      )
    end

    # Best by category
    IO.puts("")

    best_overall = hd(sorted)
    IO.puts("  Best overall:  #{best_overall.model} (retention: #{best_overall.best_retention})")

    free = Enum.filter(sorted, &(&1.total_cost == 0.0))

    if free != [] do
      best_free = hd(free)
      IO.puts("  Best free:     #{best_free.model} (retention: #{best_free.best_retention})")
    end

    cheapest =
      sorted
      |> Enum.filter(&(&1.total_cost > 0.0))
      |> Enum.sort_by(& &1.total_cost)

    if cheapest != [] do
      best_budget = hd(cheapest)

      IO.puts(
        "  Best budget:   #{best_budget.model} " <>
          "(retention: #{best_budget.best_retention}, " <>
          "cost: $#{Float.round(best_budget.total_cost, 4)})"
      )
    end

    IO.puts("")
  end

  defp format_pct(val) when val == 0.0, do: "-"
  defp format_pct(val), do: "#{trunc(val * 100)}%"

  defp format_cost(cost) when cost == 0.0, do: "free"
  defp format_cost(cost) when cost < 0.001, do: "<$0.001"
  defp format_cost(cost), do: "$#{Float.round(cost, 4)}"

  defp pad(str, width) do
    str = to_string(str)
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
