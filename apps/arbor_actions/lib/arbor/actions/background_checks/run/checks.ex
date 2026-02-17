defmodule Arbor.Actions.BackgroundChecks.Run.Checks do
  @moduledoc """
  Individual health check implementations for BackgroundChecks.Run.

  Contains 6 diagnostic checks, their helpers, result manipulation functions,
  and markdown formatting. Extracted from BackgroundChecks.Run to reduce module
  size and improve testability.
  """

  require Logger

  # ============================================================================
  # Thresholds
  # ============================================================================

  @self_knowledge_critical_hours 72
  @self_knowledge_info_hours 24
  @self_knowledge_bloat_threshold 150
  @relationship_stale_hours 168
  @journal_stale_hours 48
  @journal_gap_days 3
  @journal_lookback_entries 30
  @memory_md_full_lines 200
  @memory_md_warning_lines 190
  @memory_md_stale_hours 48
  @read_write_ratio_threshold 20
  @inbox_stale_hours 168
  @wip_stale_hours 120
  @max_tool_lines_per_file 2000

  # ============================================================================
  # Check: Memory Freshness
  # ============================================================================

  @spec check_memory_freshness(String.t()) :: map()
  def check_memory_freshness(personal_dir) do
    now = DateTime.utc_now()
    sk_path = Path.join([personal_dir, "memory", "self_knowledge.json"])
    result = empty_result()

    result =
      case File.stat(sk_path, time: :posix) do
        {:ok, %{mtime: mtime}} ->
          hours = hours_since_posix(mtime, now)
          result = check_self_knowledge_age(result, hours)
          check_self_knowledge_bloat(result, sk_path)

        {:error, _} ->
          add_warning(
            result,
            :self_knowledge_missing,
            "self_knowledge.json not found",
            :critical,
            %{
              path: sk_path
            }
          )
      end

    # Check relationship files
    rel_files = Path.wildcard(Path.join([personal_dir, "memory", "rel_*.json"]))

    Enum.reduce(rel_files, result, fn path, acc ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} ->
          hours = hours_since_posix(mtime, now)

          if hours > @relationship_stale_hours do
            add_suggestion(
              acc,
              :stale_relationship,
              "Relationship file #{Path.basename(path)} not updated in #{Float.round(hours / 24, 1)} days",
              0.6
            )
          else
            acc
          end

        {:error, _} ->
          acc
      end
    end)
  end

  defp check_self_knowledge_age(result, hours) when hours > @self_knowledge_critical_hours do
    add_warning(
      result,
      :self_knowledge_stale,
      "Self-knowledge stale (#{Float.round(hours / 24, 1)} days old)",
      :warning,
      %{
        hours: Float.round(hours, 1)
      }
    )
  end

  defp check_self_knowledge_age(result, hours) when hours > @self_knowledge_info_hours do
    add_warning(
      result,
      :self_knowledge_not_recent,
      "Self-knowledge not updated today (#{Float.round(hours, 1)}h ago)",
      :info,
      %{
        hours: Float.round(hours, 1)
      }
    )
  end

  defp check_self_knowledge_age(result, _hours), do: result

  defp check_self_knowledge_bloat(result, path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        case File.read(path) do
          {:ok, content} ->
            try do
              data = Jason.decode!(content)
              learnings = get_in(data, ["learnings"]) || get_in(data, [:learnings]) || []
              count = if is_list(learnings), do: length(learnings), else: 0

              if count > @self_knowledge_bloat_threshold do
                add_warning(
                  result,
                  :self_knowledge_bloat,
                  "Self-knowledge has #{count} learnings (threshold: #{@self_knowledge_bloat_threshold}), consider pruning",
                  :warning,
                  %{
                    count: count,
                    threshold: @self_knowledge_bloat_threshold
                  }
                )
              else
                result
              end
            rescue
              _ -> result
            end

          {:error, _} ->
            result
        end

      _ ->
        result
    end
  end

  # ============================================================================
  # Check: Journal Continuity
  # ============================================================================

  @spec check_journal_continuity(String.t()) :: map()
  def check_journal_continuity(personal_dir) do
    now = DateTime.utc_now()
    journal_dir = Path.join(personal_dir, "journal")
    entries = Path.wildcard(Path.join(journal_dir, "*.md"))
    result = empty_result()

    if entries == [] do
      add_warning(result, :no_journal_entries, "No journal entries found", :warning, %{
        path: journal_dir
      })
    else
      # Sort by extracted date, newest first
      # Can't use Enum.sort_by with :desc — Date >= uses structural comparison, not Date.compare
      sorted =
        entries
        |> Enum.sort(fn a, b ->
          da = extract_date_from_filename(a)
          db = extract_date_from_filename(b)

          case {da, db} do
            {nil, nil} -> a >= b
            {nil, _} -> false
            {_, nil} -> true
            {da, db} -> Date.compare(da, db) != :lt
          end
        end)

      most_recent = hd(sorted)

      result =
        case File.stat(most_recent, time: :posix) do
          {:ok, %{mtime: mtime}} ->
            hours = hours_since_posix(mtime, now)

            if hours > @journal_stale_hours do
              add_warning(
                result,
                :journal_stale,
                "Last journal entry was #{Float.round(hours / 24, 1)} days ago (#{Path.basename(most_recent)})",
                :info,
                %{
                  hours: Float.round(hours, 1),
                  last_entry: Path.basename(most_recent)
                }
              )
            else
              result
            end

          {:error, _} ->
            result
        end

      # Detect date gaps in recent entries
      recent = Enum.take(sorted, @journal_lookback_entries)

      dates =
        recent
        |> Enum.map(&extract_date_from_filename/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(Date)

      gaps = detect_gaps(dates, @journal_gap_days)

      Enum.reduce(gaps, result, fn {from, to, days}, acc ->
        add_suggestion(
          acc,
          :journal_gap,
          "#{days}-day journal gap from #{Date.to_iso8601(from)} to #{Date.to_iso8601(to)}",
          0.5
        )
      end)
    end
  end

  # ============================================================================
  # Check: MEMORY.md Health
  # ============================================================================

  @spec check_memory_md_health(String.t()) :: map()
  def check_memory_md_health(session_dir) do
    now = DateTime.utc_now()
    memory_md_path = Path.join([session_dir, "memory", "MEMORY.md"])
    result = empty_result()

    case File.stat(memory_md_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} when size > 0 ->
        hours = hours_since_posix(mtime, now)

        result =
          if hours > @memory_md_stale_hours do
            add_warning(
              result,
              :memory_md_stale,
              "MEMORY.md not updated in #{Float.round(hours, 1)}h",
              :info,
              %{
                hours: Float.round(hours, 1)
              }
            )
          else
            result
          end

        case File.read(memory_md_path) do
          {:ok, content} ->
            lines = String.split(content, "\n")
            line_count = length(lines)
            section_count = Enum.count(lines, &String.starts_with?(&1, "## "))

            result =
              cond do
                line_count >= @memory_md_full_lines ->
                  result
                  |> add_warning(
                    :memory_md_full,
                    "MEMORY.md has #{line_count} lines (limit ~200), needs pruning",
                    :warning,
                    %{
                      lines: line_count,
                      sections: section_count
                    }
                  )
                  |> add_action(
                    :prune_memory_md,
                    "Prune MEMORY.md (#{line_count} lines, limit ~200)",
                    :medium,
                    %{
                      lines: line_count,
                      sections: section_count
                    }
                  )

                line_count >= @memory_md_warning_lines ->
                  add_suggestion(
                    result,
                    :memory_md_approaching_limit,
                    "MEMORY.md approaching limit (#{line_count}/200 lines, #{section_count} sections)",
                    0.7
                  )

                true ->
                  result
              end

            add_suggestion(
              result,
              :memory_md_stats,
              "MEMORY.md: #{line_count} lines, #{section_count} sections",
              0.3
            )

          {:error, _} ->
            result
        end

      {:ok, %{size: 0}} ->
        add_warning(result, :memory_md_empty, "MEMORY.md is empty", :warning, %{
          path: memory_md_path
        })

      {:error, _} ->
        add_warning(
          result,
          :memory_md_missing,
          "MEMORY.md not found at #{memory_md_path}",
          :warning,
          %{
            path: memory_md_path
          }
        )
    end
  end

  # ============================================================================
  # Check: Session Patterns
  # ============================================================================

  @spec check_session_patterns(String.t(), non_neg_integer()) :: map()
  def check_session_patterns(session_dir, max_sessions) do
    result = empty_result()

    jsonl_files = Path.wildcard(Path.join(session_dir, "*.jsonl"))

    if jsonl_files == [] do
      add_warning(result, :no_sessions, "No session JSONL files found", :info, %{
        path: session_dir
      })
    else
      # Sort by mtime descending, take most recent N
      recent_files =
        jsonl_files
        |> Enum.map(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} -> {path, mtime}
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
        |> Enum.take(max_sessions)
        |> Enum.map(fn {path, _mtime} -> path end)

      # Extract tool names from recent sessions
      tool_counts =
        recent_files
        |> Enum.flat_map(&extract_tool_names/1)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_name, count} -> count end, :desc)

      if tool_counts == [] do
        result
      else
        top_5 = Enum.take(tool_counts, 5)
        total = Enum.reduce(tool_counts, 0, fn {_name, count}, acc -> acc + count end)

        result =
          add_suggestion(
            result,
            :tool_usage,
            "Tool usage (#{max_sessions} sessions, #{total} calls): #{format_tool_counts(top_5)}",
            0.4
          )

        # Check read/write ratio
        read_count = Map.get(Enum.into(tool_counts, %{}), "Read", 0)
        write_count = Map.get(Enum.into(tool_counts, %{}), "Write", 0)
        edit_count = Map.get(Enum.into(tool_counts, %{}), "Edit", 0)
        write_total = write_count + edit_count

        if write_total > 0 and read_count / write_total > @read_write_ratio_threshold do
          add_suggestion(
            result,
            :high_read_ratio,
            "High read/write ratio: #{read_count} reads vs #{write_total} writes — may indicate exploratory patterns",
            0.5
          )
        else
          result
        end
      end
    end
  end

  # ============================================================================
  # Check: Roadmap Staleness
  # ============================================================================

  @spec check_roadmap_staleness(String.t()) :: map()
  def check_roadmap_staleness(project_dir) do
    now = DateTime.utc_now()
    roadmap_dir = Path.join(project_dir, ".arbor/roadmap")
    result = empty_result()

    stages = ["0-inbox", "1-brainstorming", "2-planned", "3-in-progress", "5-completed"]

    stage_counts =
      Enum.map(stages, fn stage ->
        dir = Path.join(roadmap_dir, stage)

        case File.ls(dir) do
          {:ok, files} ->
            # Filter out hidden files
            items = Enum.reject(files, &String.starts_with?(&1, "."))
            {stage, length(items)}

          {:error, _} ->
            {stage, 0}
        end
      end)

    result =
      if Enum.any?(stage_counts, fn {_, count} -> count > 0 end) do
        summary =
          Enum.map_join(stage_counts, ", ", fn {stage, count} -> "#{stage}: #{count}" end)

        add_suggestion(result, :roadmap_summary, "Roadmap: #{summary}", 0.3)
      else
        result
      end

    # Check inbox staleness
    inbox_dir = Path.join(roadmap_dir, "0-inbox")

    result =
      check_dir_staleness(
        result,
        inbox_dir,
        now,
        @inbox_stale_hours,
        :stale_inbox,
        "Inbox item"
      )

    # Check in-progress staleness
    wip_dir = Path.join(roadmap_dir, "3-in-progress")
    check_dir_staleness(result, wip_dir, now, @wip_stale_hours, :stale_wip, "In-progress item")
  end

  # ============================================================================
  # Check: System Health
  # ============================================================================

  @spec check_system_health() :: map()
  def check_system_health do
    result = empty_result()

    # Check Agent Registry
    result =
      case bridge_call(Arbor.Agent.Registry, :list, []) do
        {:ok, {:ok, agents}} when is_list(agents) ->
          add_suggestion(result, :agent_count, "#{length(agents)} agent(s) registered", 0.3)

        {:ok, agents} when is_list(agents) ->
          add_suggestion(result, :agent_count, "#{length(agents)} agent(s) registered", 0.3)

        {:error, _} ->
          result
      end

    # Check Signal Bus health
    result =
      case bridge_call(Arbor.Signals, :healthy?, []) do
        {:ok, true} ->
          result

        {:ok, false} ->
          add_warning(
            result,
            :signal_bus_unhealthy,
            "Signal bus reports unhealthy state",
            :warning,
            %{}
          )

        {:error, _} ->
          result
      end

    # Check if arbor runtime is available at all
    arbor_loaded =
      Code.ensure_loaded?(Arbor.Agent.Registry) or
        Code.ensure_loaded?(Arbor.Signals)

    if arbor_loaded do
      result
    else
      add_suggestion(
        result,
        :no_runtime,
        "Arbor runtime not detected (modules not loaded)",
        0.5
      )
    end
  end

  # ============================================================================
  # Result Helpers
  # ============================================================================

  @doc "Create an empty result map with actions, warnings, and suggestions."
  @spec empty_result() :: map()
  def empty_result, do: %{actions: [], warnings: [], suggestions: []}

  @doc "Add a warning to a result map."
  @spec add_warning(map(), atom(), String.t(), atom(), map()) :: map()
  def add_warning(result, type, message, severity, data) do
    warning = %{type: type, message: message, severity: severity, data: data}
    %{result | warnings: result.warnings ++ [warning]}
  end

  @doc "Add a suggestion to a result map."
  @spec add_suggestion(map(), atom(), String.t(), float()) :: map()
  def add_suggestion(result, type, content, confidence) do
    suggestion = %{type: type, content: content, confidence: confidence}
    %{result | suggestions: result.suggestions ++ [suggestion]}
  end

  @doc "Add an action to a result map."
  @spec add_action(map(), atom(), String.t(), atom(), map()) :: map()
  def add_action(result, type, description, priority, data) do
    action = %{type: type, description: description, priority: priority, data: data}
    %{result | actions: result.actions ++ [action]}
  end

  @doc "Merge a list of result maps into a single result."
  @spec merge_results([map()]) :: map()
  def merge_results(results) do
    Enum.reduce(results, empty_result(), fn result, acc ->
      %{
        actions: acc.actions ++ result.actions,
        warnings: acc.warnings ++ result.warnings,
        suggestions: acc.suggestions ++ result.suggestions
      }
    end)
  end

  # ============================================================================
  # Time Helpers
  # ============================================================================

  @doc false
  def hours_since_posix(posix_mtime, %DateTime{} = now) do
    case DateTime.from_unix(posix_mtime) do
      {:ok, mtime_dt} ->
        DateTime.diff(now, mtime_dt, :second) / 3600.0

      {:error, _} ->
        0.0
    end
  end

  # ============================================================================
  # File Helpers
  # ============================================================================

  @doc false
  def extract_date_from_filename(path) do
    basename = Path.basename(path)

    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})/, basename) do
      [_, date_str] ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> date
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  @doc false
  def detect_gaps([], _min_gap_days), do: []
  def detect_gaps([_], _min_gap_days), do: []

  def detect_gaps(sorted_dates, min_gap_days) do
    sorted_dates
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      days = Date.diff(b, a)

      if days >= min_gap_days do
        [{a, b, days}]
      else
        []
      end
    end)
  end

  defp extract_tool_names(jsonl_path) do
    jsonl_path
    |> File.stream!([], :line)
    |> Stream.filter(&String.contains?(&1, "tool_use"))
    |> Stream.take(@max_tool_lines_per_file)
    |> Stream.flat_map(fn line ->
      try do
        case Jason.decode(line) do
          {:ok, %{"message" => %{"content" => content}}} when is_list(content) ->
            content
            |> Enum.filter(fn
              %{"type" => "tool_use", "name" => name} when is_binary(name) -> true
              _ -> false
            end)
            |> Enum.map(fn %{"name" => name} -> name end)

          _ ->
            []
        end
      rescue
        _ -> []
      end
    end)
    |> Enum.to_list()
  rescue
    _ -> []
  end

  defp format_tool_counts(top_n) do
    Enum.map_join(top_n, ", ", fn {name, count} -> "#{name}(#{count})" end)
  end

  # ============================================================================
  # Directory Staleness Helper
  # ============================================================================

  defp check_dir_staleness(result, dir, now, threshold_hours, type, label) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reduce(result, fn file, acc ->
          path = Path.join(dir, file)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} ->
              hours = hours_since_posix(mtime, now)

              if hours > threshold_hours do
                severity = if type == :stale_wip, do: :warning, else: :info

                add_warning(
                  acc,
                  type,
                  "#{label} '#{file}' untouched for #{Float.round(hours / 24, 1)} days",
                  severity,
                  %{
                    file: file,
                    hours: Float.round(hours, 1)
                  }
                )
              else
                acc
              end

            {:error, _} ->
              acc
          end
        end)

      {:error, _} ->
        result
    end
  end

  # ============================================================================
  # Runtime Bridge
  # ============================================================================

  defp bridge_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      try do
        result = apply(module, function, args)
        {:ok, result}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    else
      {:error, :module_not_loaded}
    end
  end

  # ============================================================================
  # Markdown Formatting
  # ============================================================================

  @doc "Format merged results and named check results into a markdown report."
  @spec format_markdown(map(), list(), integer()) :: String.t()
  def format_markdown(merged, _named_results, duration_ms) do
    action_count = length(merged.actions)
    warning_count = length(merged.warnings)
    suggestion_count = length(merged.suggestions)

    sections = [
      "# Background Check Report\n",
      "_#{action_count} actions, #{warning_count} warnings, #{suggestion_count} suggestions (#{duration_ms}ms)_\n"
    ]

    sections =
      if merged.actions != [] do
        action_lines =
          Enum.map(merged.actions, fn a ->
            "- **[#{a.priority}]** #{a.description}"
          end)

        sections ++ ["\n## Actions Required\n" | action_lines]
      else
        sections
      end

    sections =
      if merged.warnings != [] do
        warning_lines =
          Enum.map(merged.warnings, fn w ->
            icon = severity_icon(w.severity)
            "- #{icon} #{w.message}"
          end)

        sections ++ ["\n## Warnings\n" | warning_lines]
      else
        sections
      end

    sections =
      if merged.suggestions != [] do
        suggestion_lines =
          Enum.map(merged.suggestions, fn s ->
            "- #{s.content}"
          end)

        sections ++ ["\n## Suggestions\n" | suggestion_lines]
      else
        sections
      end

    Enum.join(sections, "\n")
  end

  defp severity_icon(:critical), do: "[!!!]"
  defp severity_icon(:warning), do: "[!!]"
  defp severity_icon(:info), do: "[i]"
  defp severity_icon(_), do: "[?]"
end
