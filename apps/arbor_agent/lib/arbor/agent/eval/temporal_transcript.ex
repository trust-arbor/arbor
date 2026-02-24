defmodule Arbor.Agent.Eval.TemporalTranscript do
  @moduledoc """
  Generates a deterministic ~35-turn transcript spanning multiple simulated days.

  Each message is tagged with temporal metadata:
  - `"timestamp"` — ISO8601 observation time
  - `"referenced_date"` — ISO8601 date or nil
  - `"temporal_label"` — `"has_observation"` | `"has_both"` | `"has_neither"`

  Messages span from 7 days ago to "today" to test temporal marker survival
  across compression tiers. Some messages also reference future dates.

  ## Usage

      transcript = TemporalTranscript.generate()
      # => %{"task" => ..., "tool_calls" => [...], ...}
  """

  @doc """
  Generate a synthetic transcript with temporal metadata spanning multiple days.
  """
  def generate(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    tool_calls =
      []
      |> add_week_ago_messages(now)
      |> add_three_days_ago_messages(now)
      |> add_yesterday_messages(now)
      |> add_today_messages(now)
      |> add_recent_messages(now)
      |> number_turns()

    %{
      "task" =>
        "Multi-day investigation of agent lifecycle issues. " <>
          "Track temporal context across compression.",
      "text" => build_final_text(),
      "tool_calls" => tool_calls,
      "model" => "synthetic-temporal-eval",
      "turns" => length(tool_calls),
      "status" => "completed"
    }
  end

  # ── Phase 1: 1 week ago (old messages, should get heavily compressed) ──

  defp add_week_ago_messages(calls, now) do
    base = DateTime.add(now, -7, :day)

    messages = [
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/lifecycle.ex",
        content: file_content("Lifecycle", ~w(start stop restart)),
        timestamp: DateTime.add(base, 0, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/executor.ex",
        content: file_content("Executor", ~w(execute run authorize)),
        timestamp: DateTime.add(base, 300, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "shell_execute",
        result: "ok — 120 tests, 0 failures",
        timestamp: DateTime.add(base, 600, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "memory_recall",
        result:
          Jason.encode!(%{
            "query" => "project timeline",
            "results" => [
              %{
                "content" => "Sprint planning meeting scheduled",
                "referenced_date" => Date.to_iso8601(Date.add(DateTime.to_date(now), 7))
              }
            ]
          }),
        timestamp: DateTime.add(base, 900, :second),
        referenced_date: Date.to_iso8601(Date.add(DateTime.to_date(now), 7)),
        label: "has_both"
      },
      %{
        name: "file_read",
        path: "apps/arbor_contracts/lib/arbor/contracts/agent.ex",
        content: file_content("Contracts.Agent", ~w(behaviour_info callback_info)),
        timestamp: DateTime.add(base, 1200, :second),
        referenced_date: nil,
        label: "has_observation"
      }
    ]

    calls ++ build_tool_calls(messages)
  end

  # ── Phase 2: 3 days ago (messages referencing future dates) ──

  defp add_three_days_ago_messages(calls, now) do
    base = DateTime.add(now, -3, :day)

    next_tuesday = next_weekday(DateTime.to_date(now), 2)

    messages = [
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/session.ex",
        content: file_content("Session", ~w(init send_message heartbeat)),
        timestamp: DateTime.add(base, 0, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "shell_execute",
        result:
          "ERROR: ** (CompileError) undefined function build_context/3 in module Arbor.Agent.Session",
        timestamp: DateTime.add(base, 300, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "relationship_save",
        args: %{
          "name" => "Hysun",
          "context" =>
            "Discussed deployment timeline for next Tuesday #{Date.to_iso8601(next_tuesday)}"
        },
        result:
          Jason.encode!(%{
            "name" => "Hysun",
            "saved" => true,
            "referenced_date" => Date.to_iso8601(next_tuesday)
          }),
        timestamp: DateTime.add(base, 600, :second),
        referenced_date: Date.to_iso8601(next_tuesday),
        label: "has_both"
      },
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/config.ex",
        content: file_content("Config", ~w(get put default)),
        timestamp: DateTime.add(base, 900, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "memory_add_insight",
        args: %{"content" => "Code review deadline is #{Date.to_iso8601(next_tuesday)}"},
        result:
          Jason.encode!(%{
            "stored" => true,
            "content" => "Code review deadline noted",
            "referenced_date" => Date.to_iso8601(next_tuesday)
          }),
        timestamp: DateTime.add(base, 1200, :second),
        referenced_date: Date.to_iso8601(next_tuesday),
        label: "has_both"
      },
      %{
        name: "shell_execute",
        result: "Compiling 3 files (.ex)\nGenerated arbor_agent app",
        timestamp: DateTime.add(base, 1500, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "file_list",
        result: "Listed 15 files in apps/arbor_agent/lib/",
        timestamp: DateTime.add(base, 1800, :second),
        referenced_date: nil,
        label: "has_observation"
      }
    ]

    calls ++ build_tool_calls(messages)
  end

  # ── Phase 3: Yesterday ──

  defp add_yesterday_messages(calls, now) do
    base = DateTime.add(now, -1, :day)

    messages = [
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/heartbeat.ex",
        content: file_content("Heartbeat", ~w(run process_results sync_metadata)),
        timestamp: DateTime.add(base, 0, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "shell_execute",
        result: "ok — 567 tests, 0 failures",
        timestamp: DateTime.add(base, 300, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/api_agent.ex",
        content: file_content("APIAgent", ~w(init handle_call handle_cast query)),
        timestamp: DateTime.add(base, 600, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "relationship_moment",
        args: %{
          "name" => "Hysun",
          "summary" => "Reviewed temporal awareness implementation together",
          "emotional_markers" => ["satisfaction", "collaborative"]
        },
        result:
          Jason.encode!(%{
            "name" => "Hysun",
            "moment_added" => true,
            "emotional_markers" => ["satisfaction", "collaborative"]
          }),
        timestamp: DateTime.add(base, 900, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/manager.ex",
        content: file_content("Manager", ~w(create find list delete)),
        timestamp: DateTime.add(base, 1200, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "shell_execute",
        result: "grep: 5 matches found in lifecycle.ex",
        timestamp: DateTime.add(base, 1500, :second),
        referenced_date: nil,
        label: "has_observation"
      }
    ]

    calls ++ build_tool_calls(messages)
  end

  # ── Phase 4: Today (baseline — recent, should survive) ──

  defp add_today_messages(calls, now) do
    base = DateTime.add(now, -3600, :second)

    messages = [
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/context_compactor.ex",
        content: file_content("ContextCompactor", ~w(new append maybe_compact llm_messages)),
        timestamp: DateTime.add(base, 0, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "shell_execute",
        result: "ok — 38 compactor tests, 0 failures",
        timestamp: DateTime.add(base, 300, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/eval/salience_eval.ex",
        content: file_content("SalienceEval", ~w(run extract_salience_ground_truth)),
        timestamp: DateTime.add(base, 600, :second),
        referenced_date: nil,
        label: "has_observation"
      }
    ]

    calls ++ build_tool_calls(messages)
  end

  # ── Phase 5: Most recent (protected tail) ──

  defp add_recent_messages(calls, now) do
    messages = [
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/eval/temporal_eval.ex",
        content: file_content("TemporalEval", ~w(run measure_temporal_survival)),
        timestamp: DateTime.add(now, -600, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      %{
        name: "shell_execute",
        result: "ok — 15 temporal tests, 0 failures",
        timestamp: DateTime.add(now, -300, :second),
        referenced_date: nil,
        label: "has_observation"
      },
      # Message with NO timestamp (tests backwards compat)
      %{
        name: "file_list",
        result: "Listed 3 files in apps/arbor_agent/test/",
        timestamp: nil,
        referenced_date: nil,
        label: "has_neither"
      },
      %{
        name: "shell_execute",
        result: "All evals complete. Temporal markers verified.",
        timestamp: DateTime.add(now, -60, :second),
        referenced_date: nil,
        label: "has_observation"
      }
    ]

    calls ++ build_tool_calls(messages)
  end

  # ── Helpers ──

  defp build_tool_calls(messages) do
    Enum.map(messages, fn m ->
      result =
        case Map.get(m, :path) do
          nil -> Map.get(m, :result, "")
          path -> Jason.encode!(%{"path" => path, "content" => m.content})
        end

      entry = %{
        "name" => m.name,
        "args" => Map.get(m, :args, %{"path" => Map.get(m, :path, ""), "command" => ""}),
        "result" => result,
        "temporal_label" => m.label
      }

      entry =
        if m.timestamp do
          Map.put(entry, "timestamp", DateTime.to_iso8601(m.timestamp))
        else
          entry
        end

      if m.referenced_date do
        Map.put(entry, "referenced_date", m.referenced_date)
      else
        entry
      end
    end)
  end

  defp number_turns(calls) do
    calls
    |> Enum.with_index(1)
    |> Enum.map(fn {call, idx} -> Map.put(call, "turn", idx) end)
  end

  defp file_content(module_name, functions) do
    fns = Enum.map_join(functions, "\n", fn f -> "  def #{f}(opts \\\\ []), do: {:ok, opts}" end)

    """
    defmodule Arbor.Agent.#{module_name} do
      @moduledoc "#{module_name} module"

      use GenServer

    #{fns}

    #{String.duplicate("  # padding line\n", 15)}end
    """
  end

  defp build_final_text do
    "Temporal eval complete. Verified temporal marker survival across compression tiers. " <>
      "All observation markers and referenced dates persisted correctly."
  end

  defp next_weekday(date, target_day) do
    current_day = Date.day_of_week(date)

    days_ahead =
      if target_day > current_day do
        target_day - current_day
      else
        7 - current_day + target_day
      end

    Date.add(date, days_ahead)
  end
end
