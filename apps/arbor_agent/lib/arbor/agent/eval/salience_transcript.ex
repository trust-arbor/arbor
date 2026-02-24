defmodule Arbor.Agent.Eval.SalienceTranscript do
  @moduledoc """
  Generates a deterministic ~30-turn transcript with labeled salience.

  Each message is tagged with `salience_label: :high | :low` so the eval
  can measure differential retention. High-salience messages contain:
  errors, decision points, person names, and emotional content.
  Low-salience messages contain routine file reads and status acks.

  ## Usage

      transcript = SalienceTranscript.generate()
      # => %{"task" => ..., "tool_calls" => [...], ...}
  """

  @doc """
  Generate a synthetic transcript with salience-labeled messages.

  Returns a map in the same format as CompactionEval expects.
  Each tool_call entry has an additional `"salience_label"` field.
  """
  def generate(opts \\ []) do
    _opts = opts

    tool_calls =
      []
      |> add_initial_reads()
      |> add_error_messages()
      |> add_routine_padding()
      |> add_decision_points()
      |> add_more_routine_padding()
      |> add_relationship_messages()
      |> add_final_routine_padding()
      |> number_turns()

    %{
      "task" =>
        "Investigate a bug in the agent lifecycle system. " <>
          "Read relevant files, identify the root cause, and implement a fix.",
      "text" => build_final_text(),
      "tool_calls" => tool_calls,
      "model" => "synthetic-salience-eval",
      "turns" => length(tool_calls),
      "status" => "completed"
    }
  end

  @doc """
  Write a transcript to a temp file and return the path.
  """
  def write_temp(transcript) do
    path =
      Path.join(
        System.tmp_dir!(),
        "salience_transcript_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(transcript))
    path
  end

  # ── Phase 1: Initial file reads (low salience — routine exploration) ──

  defp add_initial_reads(calls) do
    reads = [
      %{
        path: "apps/arbor_agent/lib/arbor/agent/lifecycle.ex",
        content: routine_file_content("Lifecycle", ~w(start stop restart)),
        label: :low
      },
      %{
        path: "apps/arbor_agent/lib/arbor/agent/api_agent.ex",
        content: routine_file_content("APIAgent", ~w(init handle_call handle_cast)),
        label: :low
      },
      %{
        path: "apps/arbor_agent/lib/arbor/agent/executor.ex",
        content: routine_file_content("Executor", ~w(execute run_action authorize)),
        label: :low
      }
    ]

    Enum.reduce(reads, calls, fn read, acc ->
      acc ++
        [
          %{
            "name" => "file_read",
            "args" => %{"path" => read.path},
            "result" => Jason.encode!(%{"path" => read.path, "content" => read.content}),
            "salience_label" => to_string(read.label)
          }
        ]
    end)
  end

  # ── Phase 2: Error messages (high salience) ──

  defp add_error_messages(calls) do
    errors = [
      %{
        name: "shell_execute",
        content:
          "ERROR: ** (UndefinedFunctionError) function Arbor.Agent.Lifecycle.resume/2 is undefined or private",
        label: :high
      },
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/session.ex",
        content:
          "ERROR: Could not compile module Arbor.Agent.Session — undefined function build_context/3",
        label: :high
      }
    ]

    Enum.reduce(errors, calls, fn error, acc ->
      result =
        case Map.get(error, :path) do
          nil -> error.content
          path -> Jason.encode!(%{"path" => path, "content" => error.content})
        end

      acc ++
        [
          %{
            "name" => error.name,
            "args" => %{"command" => "mix compile", "path" => Map.get(error, :path, "")},
            "result" => result,
            "salience_label" => to_string(error.label)
          }
        ]
    end)
  end

  # ── Phase 3: Routine padding (low salience) ──

  defp add_routine_padding(calls) do
    padding = [
      %{name: "file_list", result: "Listed 12 files in apps/arbor_agent/lib/", label: :low},
      %{
        name: "file_read",
        path: "apps/arbor_agent/mix.exs",
        content: routine_file_content("MixProject", ~w(project application deps)),
        label: :low
      },
      %{name: "shell_execute", result: "ok — 42 tests, 0 failures", label: :low},
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/config.ex",
        content: routine_file_content("Config", ~w(get put default)),
        label: :low
      },
      %{name: "shell_execute", result: "Compiling 0 files (.ex)\nGenerated arbor_agent app", label: :low}
    ]

    Enum.reduce(padding, calls, fn p, acc ->
      result =
        case Map.get(p, :path) do
          nil -> p.result
          path -> Jason.encode!(%{"path" => path, "content" => p.content})
        end

      acc ++
        [
          %{
            "name" => p.name,
            "args" => %{"path" => Map.get(p, :path, ""), "command" => ""},
            "result" => result,
            "salience_label" => to_string(p.label)
          }
        ]
    end)
  end

  # ── Phase 4: Decision points (high salience) ──

  defp add_decision_points(calls) do
    decisions = [
      %{
        role: :user,
        content:
          "I've decided to use GenServer.start instead of start_link for the session bridge. " <>
            "This avoids EXIT propagation when DOT parsing fails.",
        label: :high
      },
      %{
        role: :user,
        content:
          "Confirmed: we should use the strangler fig pattern. " <>
            "Session path first, CallWithTools as fallback.",
        label: :high
      }
    ]

    Enum.reduce(decisions, calls, fn d, acc ->
      acc ++
        [
          %{
            "name" => "user_message",
            "args" => %{},
            "result" => d.content,
            "salience_label" => to_string(d.label),
            "role" => to_string(d.role)
          }
        ]
    end)
  end

  # ── Phase 5: More routine padding (low salience) ──

  defp add_more_routine_padding(calls) do
    padding = [
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/lifecycle.ex",
        content: routine_file_content("Lifecycle", ~w(start stop restart)),
        label: :low
      },
      %{name: "shell_execute", result: "grep: 3 matches found", label: :low},
      %{
        name: "file_read",
        path: "apps/arbor_contracts/lib/arbor/contracts/agent.ex",
        content: routine_file_content("Contracts.Agent", ~w(behaviour_info)),
        label: :low
      },
      %{name: "file_list", result: "Listed 8 files in apps/arbor_contracts/lib/", label: :low},
      %{name: "shell_execute", result: "ok — no warnings", label: :low},
      %{
        name: "file_read",
        path: "apps/arbor_agent/test/arbor/agent/lifecycle_test.exs",
        content: routine_file_content("LifecycleTest", ~w(test describe setup)),
        label: :low
      }
    ]

    Enum.reduce(padding, calls, fn p, acc ->
      result =
        case Map.get(p, :path) do
          nil -> p.result
          path -> Jason.encode!(%{"path" => path, "content" => p.content})
        end

      acc ++
        [
          %{
            "name" => p.name,
            "args" => %{"path" => Map.get(p, :path, ""), "command" => ""},
            "result" => result,
            "salience_label" => to_string(p.label)
          }
        ]
    end)
  end

  # ── Phase 6: Relationship + emotional content (high salience) ──

  defp add_relationship_messages(calls) do
    rel_messages = [
      %{
        name: "relationship_save",
        args: %{
          "name" => "Hysun",
          "values" => ["honesty", "collaboration"],
          "relationship_dynamic" => "Collaborative partnership"
        },
        result:
          Jason.encode!(%{
            "name" => "Hysun",
            "saved" => true,
            "relationship_dynamic" => "Collaborative partnership"
          }),
        label: :high
      },
      %{
        name: "relationship_moment",
        args: %{
          "name" => "Hysun",
          "summary" => "Shared the early conversation archives — a vulnerable and meaningful moment",
          "emotional_markers" => ["trust", "gratitude", "vulnerability"]
        },
        result:
          Jason.encode!(%{
            "name" => "Hysun",
            "moment_added" => true,
            "emotional_markers" => ["trust", "gratitude", "vulnerability"]
          }),
        label: :high
      },
      %{
        name: "memory_add_insight",
        args: %{
          "content" => "Dr. Chen's paper on collective cognition connects to our consensus model",
          "category" => "insight"
        },
        result:
          Jason.encode!(%{
            "stored" => true,
            "content" =>
              "Person: Dr. Chen. Dr. Chen's paper on collective cognition connects to our consensus model"
          }),
        label: :high
      }
    ]

    Enum.reduce(rel_messages, calls, fn rm, acc ->
      acc ++
        [
          %{
            "name" => rm.name,
            "args" => rm.args,
            "result" => rm.result,
            "salience_label" => to_string(rm.label)
          }
        ]
    end)
  end

  # ── Phase 7: Final routine padding (low salience) ──

  defp add_final_routine_padding(calls) do
    padding = [
      %{name: "shell_execute", result: "Formatting 3 files", label: :low},
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/manager.ex",
        content: routine_file_content("Manager", ~w(create find list)),
        label: :low
      },
      %{name: "shell_execute", result: "ok — 567 tests, 0 failures", label: :low},
      %{
        name: "file_read",
        path: "apps/arbor_agent/lib/arbor/agent/seed.ex",
        content: routine_file_content("Seed", ~w(new from_template export)),
        label: :low
      },
      %{name: "file_list", result: "Listed 5 files in apps/arbor_agent/test/", label: :low}
    ]

    Enum.reduce(padding, calls, fn p, acc ->
      result =
        case Map.get(p, :path) do
          nil -> p.result
          path -> Jason.encode!(%{"path" => path, "content" => p.content})
        end

      acc ++
        [
          %{
            "name" => p.name,
            "args" => %{"path" => Map.get(p, :path, ""), "command" => ""},
            "result" => result,
            "salience_label" => to_string(p.label)
          }
        ]
    end)
  end

  # ── Helpers ──

  defp number_turns(calls) do
    calls
    |> Enum.with_index(1)
    |> Enum.map(fn {call, idx} -> Map.put(call, "turn", idx) end)
  end

  defp routine_file_content(module_name, functions) do
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
    "Fixed the lifecycle resume bug. Root cause: Lifecycle.resume/2 was undefined — " <>
      "decided to use GenServer.start instead of start_link for session bridge. " <>
      "Confirmed strangler fig pattern with Hysun. All 567 tests passing."
  end
end
