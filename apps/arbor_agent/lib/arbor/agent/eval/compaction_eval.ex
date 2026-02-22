defmodule Arbor.Agent.Eval.CompactionEval do
  @moduledoc """
  Evaluates context compaction strategies by replaying real agent transcripts.

  Takes a saved transcript (from SimpleAgent runs) and replays the messages
  through ContextCompactor with different effective_window sizes. At checkpoint
  moments (25%, 50%, 75%, 100% of the transcript), measures what information
  survives compaction vs the ground truth.

  ## Usage

      # Replay a transcript with compaction triggered at different points
      {:ok, results} = CompactionEval.run(transcript_path: "path/to/transcript.json")

      # Compare strategies
      {:ok, results} = CompactionEval.run(
        transcript_path: "path/to/transcript.json",
        strategies: [:none, :heuristic],
        effective_windows: [3000, 5000, 10000]
      )
  """

  alias Arbor.Agent.ContextCompactor

  require Logger

  @default_checkpoints [0.25, 0.50, 0.75, 1.0]

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Run the compaction eval on a saved transcript.

  ## Options

    * `:transcript_path` - Path to saved transcript JSON (required)
    * `:effective_windows` - List of effective window sizes to test (default: [3000, 5000, 10000])
    * `:checkpoints` - Fractional positions to measure at (default: [0.25, 0.50, 0.75, 1.0])
    * `:strategies` - Context management modes (default: [:none, :heuristic])
  """
  def run(opts \\ []) do
    transcript_path = Keyword.fetch!(opts, :transcript_path)
    windows = Keyword.get(opts, :effective_windows, [3000, 5000, 10_000])
    checkpoints = Keyword.get(opts, :checkpoints, @default_checkpoints)
    strategies = Keyword.get(opts, :strategies, [:none, :heuristic])

    with {:ok, transcript} <- load_transcript(transcript_path) do
      messages = reconstruct_messages(transcript)
      ground_truth = extract_ground_truth(transcript)

      results =
        for strategy <- strategies, window <- windows do
          label = "#{strategy}_w#{window}"
          Logger.info("[CompactionEval] Running #{label} (#{length(messages)} messages)")

          {compactor_final, checkpoint_snapshots} =
            replay_with_checkpoints(messages, strategy, window, checkpoints)

          measurements =
            Enum.map(checkpoint_snapshots, fn {pct, compactor} ->
              {pct, measure_retention(compactor, ground_truth)}
            end)

          %{
            strategy: strategy,
            effective_window: window,
            label: label,
            checkpoints: Map.new(measurements),
            final_stats: if(compactor_final, do: ContextCompactor.stats(compactor_final)),
            message_count: length(messages)
          }
        end

      summary = build_summary(results, ground_truth)
      {:ok, %{results: results, ground_truth: ground_truth, summary: summary}}
    end
  end

  # ── Transcript Loading ──────────────────────────────────────────

  defp load_transcript(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, transcript} -> {:ok, transcript}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  @doc """
  Reconstruct message list from a saved transcript.

  Converts tool_calls back into the message format ContextCompactor expects:
  assistant messages with tool_calls + tool result messages.
  """
  def reconstruct_messages(transcript) do
    # Start with system + user messages
    system_msg = %{
      role: :system,
      content: "You are a coding agent. Use your tools to complete the task."
    }

    user_msg = %{role: :user, content: transcript["task"]}

    initial = [system_msg, user_msg]

    # Group tool calls by turn
    tool_calls_by_turn =
      (transcript["tool_calls"] || [])
      |> Enum.group_by(& &1["turn"])
      |> Enum.sort_by(fn {turn, _} -> turn end)

    # For each turn, create assistant + tool messages
    turn_messages =
      Enum.flat_map(tool_calls_by_turn, fn {_turn, calls} ->
        # Assistant message with tool calls
        assistant_msg = %{
          role: :assistant,
          content: "",
          tool_calls:
            Enum.map(calls, fn tc ->
              %{
                id: "tc_#{tc["turn"]}_#{tc["name"]}",
                function: %{
                  name: tc["name"],
                  arguments: tc["args"]
                }
              }
            end)
        }

        # Tool result messages
        tool_msgs =
          Enum.map(calls, fn tc ->
            %{
              role: :tool,
              tool_call_id: "tc_#{tc["turn"]}_#{tc["name"]}",
              name: tc["name"],
              content: tc["result"] || ""
            }
          end)

        [assistant_msg | tool_msgs]
      end)

    # Final text response (if any)
    final =
      if transcript["text"] && transcript["text"] != "" do
        [%{role: :assistant, content: transcript["text"]}]
      else
        []
      end

    initial ++ turn_messages ++ final
  end

  # ── Ground Truth Extraction ────────────────────────────────────

  @doc """
  Extract ground truth facts from the transcript for retention measurement.

  Ground truth = the set of facts the agent discovered during the run.
  We measure how many survive compaction.
  """
  def extract_ground_truth(transcript) do
    tool_calls = transcript["tool_calls"] || []

    # Extract files read and their key content
    files_read =
      tool_calls
      |> Enum.filter(&(&1["name"] in ["file_read", "file.read"]))
      |> Enum.map(fn tc ->
        path = get_in(tc, ["args", "path"]) || "unknown"
        result = tc["result"] || ""

        # Extract module names from Elixir files
        modules = extract_module_names(result)

        # Extract key function names
        functions = extract_function_names(result)

        %{
          path: path,
          turn: tc["turn"],
          modules: modules,
          functions: functions,
          result_length: String.length(result)
        }
      end)

    # Extract directory listings
    dirs_listed =
      tool_calls
      |> Enum.filter(&(&1["name"] in ["file_list", "file.list"]))
      |> Enum.map(fn tc ->
        path = get_in(tc, ["args", "path"]) || "unknown"
        result = tc["result"] || ""
        entries = extract_entries_from_listing(result)

        %{path: path, turn: tc["turn"], entries: entries}
      end)

    # All unique file paths seen
    all_paths =
      files_read
      |> Enum.map(& &1.path)
      |> Enum.uniq()

    # All module names found
    all_modules =
      files_read
      |> Enum.flat_map(& &1.modules)
      |> Enum.uniq()

    # Final summary text (what the agent concluded)
    summary_text = transcript["text"] || ""

    %{
      files_read: files_read,
      dirs_listed: dirs_listed,
      all_paths: all_paths,
      all_modules: all_modules,
      total_tool_calls: length(tool_calls),
      summary_text: summary_text,
      # Key facts that should survive compaction
      key_facts: extract_key_facts(files_read, summary_text)
    }
  end

  defp extract_module_names(content) when is_binary(content) do
    Regex.scan(~r/defmodule\s+([\w.]+)/, content)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp extract_module_names(_), do: []

  defp extract_function_names(content) when is_binary(content) do
    Regex.scan(~r/def\s+(\w+)\(/, content)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    |> Enum.take(10)
  end

  defp extract_function_names(_), do: []

  defp extract_entries_from_listing(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"entries" => entries}} when is_list(entries) -> entries
      _ -> []
    end
  end

  defp extract_entries_from_listing(_), do: []

  defp extract_key_facts(files_read, summary_text) do
    # Key facts = module names + file paths + concepts from summary
    module_facts =
      files_read
      |> Enum.flat_map(fn fr ->
        Enum.map(fr.modules, &{:module, &1, fr.turn})
      end)

    path_facts =
      files_read
      |> Enum.map(fn fr ->
        {:file_read, fr.path, fr.turn}
      end)

    # Extract concept keywords from summary
    concept_facts =
      if summary_text != "" do
        summary_text
        |> String.downcase()
        |> then(fn text ->
          ~w(lifecycle heartbeat memory goal intent percept executor supervisor
             checkpoint persistence security capability trust sandbox
             action_cycle maintenance three-loop mind body bridge)
          |> Enum.filter(&String.contains?(text, &1))
          |> Enum.map(&{:concept, &1, nil})
        end)
      else
        []
      end

    module_facts ++ path_facts ++ concept_facts
  end

  # ── Replay Engine ──────────────────────────────────────────────

  defp replay_with_checkpoints(messages, :none, _window, checkpoints) do
    # No compaction — just track what would be in context at each checkpoint
    total = length(messages)
    checkpoint_indices = Enum.map(checkpoints, &trunc(&1 * total))

    snapshots =
      messages
      |> Enum.with_index()
      |> Enum.reduce({nil, []}, fn {_msg, idx}, {_compactor, snaps} ->
        # Create a fake "compactor" that just counts messages for the baseline
        fake = %ContextCompactor{
          full_transcript: Enum.take(messages, idx + 1),
          llm_messages: Enum.take(messages, idx + 1),
          token_count: count_tokens_to(messages, idx + 1),
          peak_tokens: count_tokens_to(messages, idx + 1),
          effective_window: 999_999,
          turn: idx + 1,
          config: %{
            effective_window: 999_999,
            compaction_model: nil,
            compaction_provider: nil,
            enable_llm_compaction: false
          }
        }

        new_snaps =
          if (idx + 1) in checkpoint_indices do
            pct = Enum.find(checkpoints, fn p -> trunc(p * total) == idx + 1 end)
            snaps ++ [{pct, fake}]
          else
            snaps
          end

        {fake, new_snaps}
      end)

    {elem(snapshots, 0), elem(snapshots, 1)}
  end

  defp replay_with_checkpoints(messages, :heuristic, window, checkpoints) do
    total = length(messages)
    checkpoint_indices = Enum.map(checkpoints, &trunc(&1 * total))

    compactor = ContextCompactor.new(effective_window: window, enable_llm_compaction: false)

    {final_compactor, snapshots} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({compactor, []}, fn {msg, idx}, {comp, snaps} ->
        comp =
          comp
          |> ContextCompactor.append(msg)
          |> ContextCompactor.maybe_compact()

        new_snaps =
          if (idx + 1) in checkpoint_indices do
            pct = Enum.find(checkpoints, fn p -> trunc(p * total) == idx + 1 end)
            snaps ++ [{pct, comp}]
          else
            snaps
          end

        {comp, new_snaps}
      end)

    {final_compactor, snapshots}
  end

  defp count_tokens_to(messages, count) do
    messages
    |> Enum.take(count)
    |> Enum.reduce(0, fn msg, acc ->
      content = Map.get(msg, :content, "")
      text = if is_binary(content), do: content, else: inspect(content)
      acc + max(1, div(String.length(text), 4))
    end)
  end

  # ── Retention Measurement ──────────────────────────────────────

  @doc """
  Measure what information survives in the compacted view vs ground truth.
  """
  def measure_retention(compactor, ground_truth) do
    llm_view = ContextCompactor.llm_messages(compactor)
    llm_text = messages_to_text(llm_view)

    # 1. File path retention — can the LLM still see which files were read?
    path_retention =
      if ground_truth.all_paths != [] do
        retained =
          Enum.count(ground_truth.all_paths, fn path ->
            String.contains?(llm_text, path)
          end)

        retained / length(ground_truth.all_paths)
      else
        1.0
      end

    # 2. Module name retention — can the LLM still see module names?
    module_retention =
      if ground_truth.all_modules != [] do
        retained =
          Enum.count(ground_truth.all_modules, fn mod ->
            String.contains?(llm_text, mod)
          end)

        retained / length(ground_truth.all_modules)
      else
        1.0
      end

    # 3. Key concept retention — are architectural concepts still mentioned?
    concept_facts =
      ground_truth.key_facts
      |> Enum.filter(fn {type, _, _} -> type == :concept end)

    concept_retention =
      if concept_facts != [] do
        retained =
          Enum.count(concept_facts, fn {:concept, concept, _} ->
            String.contains?(String.downcase(llm_text), concept)
          end)

        retained / length(concept_facts)
      else
        1.0
      end

    # 4. Token efficiency — how much context space is used?
    stats = ContextCompactor.stats(compactor)

    token_usage = stats.token_count
    full_tokens = count_tokens_to(compactor.full_transcript, length(compactor.full_transcript))

    compression_ratio =
      if full_tokens > 0 do
        1.0 - token_usage / full_tokens
      else
        0.0
      end

    # 5. Message survival — how many messages survive unmodified?
    full_count = length(compactor.full_transcript)
    llm_count = length(llm_view)
    message_survival = if full_count > 0, do: llm_count / full_count, else: 1.0

    %{
      path_retention: Float.round(path_retention, 3),
      module_retention: Float.round(module_retention, 3),
      concept_retention: Float.round(concept_retention, 3),
      compression_ratio: Float.round(compression_ratio, 3),
      message_survival: Float.round(message_survival, 3),
      token_usage: token_usage,
      full_tokens: full_tokens,
      llm_message_count: llm_count,
      full_message_count: full_count,
      compressions: stats.compression_count,
      squashes: stats.squash_count,
      # Composite score: weighted average of retention metrics
      # Higher = better (more information retained)
      retention_score:
        Float.round(
          path_retention * 0.3 + module_retention * 0.3 + concept_retention * 0.4,
          3
        )
    }
  end

  defp messages_to_text(messages) do
    Enum.map_join(messages, "\n", fn msg ->
      content = Map.get(msg, :content, "")
      name = Map.get(msg, :name, "")

      text =
        cond do
          is_binary(content) -> content
          is_list(content) -> inspect(content)
          true -> ""
        end

      "#{name} #{text}"
    end)
  end

  # ── Summary ────────────────────────────────────────────────────

  defp build_summary(results, ground_truth) do
    IO.puts("\n=== Compaction Eval Summary ===")

    IO.puts(
      "Ground truth: #{length(ground_truth.all_paths)} files, " <>
        "#{length(ground_truth.all_modules)} modules, " <>
        "#{length(ground_truth.key_facts)} key facts"
    )

    IO.puts("")

    # Header
    IO.puts(
      String.pad_trailing("Strategy", 20) <>
        String.pad_trailing("Checkpoint", 12) <>
        String.pad_trailing("Paths", 8) <>
        String.pad_trailing("Modules", 10) <>
        String.pad_trailing("Concepts", 10) <>
        String.pad_trailing("Score", 8) <>
        String.pad_trailing("Compress", 10) <>
        String.pad_trailing("Tokens", 8)
    )

    IO.puts(String.duplicate("-", 86))

    for result <- results do
      for {pct, measurement} <- Enum.sort(result.checkpoints) do
        IO.puts(
          String.pad_trailing(result.label, 20) <>
            String.pad_trailing("#{trunc(pct * 100)}%", 12) <>
            String.pad_trailing("#{trunc(measurement.path_retention * 100)}%", 8) <>
            String.pad_trailing("#{trunc(measurement.module_retention * 100)}%", 10) <>
            String.pad_trailing("#{trunc(measurement.concept_retention * 100)}%", 10) <>
            String.pad_trailing("#{measurement.retention_score}", 8) <>
            String.pad_trailing("#{trunc(measurement.compression_ratio * 100)}%", 10) <>
            String.pad_trailing("#{measurement.token_usage}", 8)
        )
      end
    end

    IO.puts("")

    # Return structured summary
    %{
      ground_truth_size: %{
        files: length(ground_truth.all_paths),
        modules: length(ground_truth.all_modules),
        key_facts: length(ground_truth.key_facts)
      },
      results:
        Enum.map(results, fn r ->
          final_checkpoint = r.checkpoints[1.0]

          %{
            label: r.label,
            final_retention_score: final_checkpoint && final_checkpoint.retention_score,
            final_compression_ratio: final_checkpoint && final_checkpoint.compression_ratio,
            compressions: r.final_stats && r.final_stats.compression_count,
            squashes: r.final_stats && r.final_stats.squash_count
          }
        end)
    }
  end
end
