defmodule Arbor.Orchestrator.Test.DotTestHelper do
  @moduledoc """
  Test helper for DOT pipeline execution testing.

  Provides utilities for loading, patching, running, and asserting on
  DOT pipeline files through Engine.run/2. Supports three testing tiers:

    - **Tier 1 (Structural)**: Parse + validate (existing in stdlib_dot_test.exs)
    - **Tier 2 (Execution)**: Run with mocks + assert paths and context
    - **Tier 3 (Equivalence)**: Compare imperative vs DOT outputs

  ## Usage

      # Load and run a stdlib DOT with all compute nodes simulated
      {:ok, result} = DotTestHelper.run_stdlib("retry-escalate.dot",
        initial_values: %{"retry.score_ok" => true}
      )

      assert DotTestHelper.visited?(result, "attempt")
      assert DotTestHelper.context_value(result, "selected_backend") == "anthropic"

      # Load any DOT file by path
      {:ok, result} = DotTestHelper.run_file("specs/pipelines/llm-routing.dot",
        initial_values: %{"tier" => "critical", "avail_anthropic" => "true"}
      )
  """

  @doc """
  Run a stdlib DOT file through the engine with optional simulated compute nodes.

  Options:
    - `:simulate_compute` — inject `simulate="true"` on all compute/codergen nodes (default: true)
    - `:initial_values` — context values to inject
    - `:parallel_branch_executor` — mock function for parallel branches
    - `:max_steps` — max engine steps (default: 100)
    - `:sleep_fn` — override Process.sleep for tests (default: no-op)
    - All other opts passed through to Engine.run/2
  """
  def run_stdlib(filename, opts \\ []) do
    path = resolve_stdlib_path(filename)
    run_dot_file(path, opts)
  end

  @doc """
  Run a DOT file from the pipeline specs directory.
  """
  def run_pipeline(filename, opts \\ []) do
    path = resolve_pipeline_path(filename)
    run_dot_file(path, opts)
  end

  @doc """
  Run a DOT file from an absolute or relative path.
  """
  def run_file(path, opts \\ []) do
    resolved = resolve_path(path)
    run_dot_file(resolved, opts)
  end

  @doc """
  Run a DOT string directly through the engine.
  """
  def run_dot(dot_string, opts \\ []) do
    execute_dot(dot_string, opts)
  end

  # -- Assertion Helpers --

  @doc "Check if a node was visited during execution."
  def visited?(%{completed_nodes: nodes}, node_id) do
    node_id in nodes
  end

  @doc "Get a context value from the execution result."
  def context_value(%{context: context}, key) do
    Map.get(context, key)
  end

  @doc "Count how many times a node was visited (for loops)."
  def visit_count(%{completed_nodes: nodes}, node_id) do
    Enum.count(nodes, &(&1 == node_id))
  end

  @doc "Get the ordered list of visited nodes."
  def execution_path(%{completed_nodes: nodes}) do
    nodes
  end

  @doc "Get node durations map."
  def durations(%{node_durations: durations}), do: durations

  @doc """
  Assert that nodes were visited in the given order (not necessarily consecutively).
  Returns true if `expected` is a subsequence of `completed_nodes`.
  """
  def visited_in_order?(%{completed_nodes: nodes}, expected) do
    subsequence?(nodes, expected)
  end

  # -- Internal --

  defp run_dot_file(path, opts) do
    case File.read(path) do
      {:ok, dot_string} ->
        execute_dot(dot_string, opts)

      {:error, reason} ->
        {:error, {:file_read, reason, path}}
    end
  end

  defp execute_dot(dot_string, opts) do
    simulate = Keyword.get(opts, :simulate_compute, true)
    skip_validation = Keyword.get(opts, :skip_validation, false)
    dot_string = if simulate, do: inject_simulate(dot_string), else: dot_string

    engine_opts =
      opts
      |> Keyword.delete(:simulate_compute)
      |> Keyword.delete(:skip_validation)
      |> Keyword.put_new(:max_steps, 100)
      |> Keyword.put_new(:sleep_fn, fn _ -> :ok end)

    if skip_validation do
      # Parse and run directly through Engine, bypassing validator.
      # Useful for DOTs with multiple terminal nodes (e.g., done + failed).
      with {:ok, graph} <- Arbor.Orchestrator.parse(dot_string) do
        graph = maybe_patch_parallel_fan_out(graph, engine_opts)
        Arbor.Orchestrator.Engine.run(graph, engine_opts)
      end
    else
      Arbor.Orchestrator.run(dot_string, engine_opts)
    end
  end

  @doc """
  Inject `simulate="true"` into all compute and codergen type nodes
  that don't already have a `simulate` attribute.
  """
  def inject_simulate(dot_string) do
    # Match node definitions with type="compute" or type="codergen"
    # and add simulate="true" if not present
    dot_string
    |> String.split("\n")
    |> Enum.map_join("\n", &maybe_inject_simulate_line/1)
  end

  defp maybe_inject_simulate_line(line) do
    trimmed = String.trim(line)

    cond do
      # Skip if already has simulate attribute
      String.contains?(trimmed, "simulate=") ->
        line

      # Match type="compute" or type="codergen" node definitions
      Regex.match?(~r/type\s*=\s*"(compute|codergen)"/, trimmed) and
          String.contains?(trimmed, "[") ->
        # Insert simulate="true" before the closing bracket
        String.replace(line, ~r/\](\s*)$/, ", simulate=\"true\"]\\1")

      true ->
        line
    end
  end

  # When a custom parallel_branch_executor is provided, set fan_out="false" on
  # parallel-type nodes. This prevents the engine's own fan-out detection from
  # conflicting with ParallelHandler's internal branch execution.
  defp maybe_patch_parallel_fan_out(graph, opts) do
    if Keyword.has_key?(opts, :parallel_branch_executor) do
      patched_nodes =
        Map.new(graph.nodes, fn {id, node} ->
          if Map.get(node.attrs, "type") == "parallel" do
            {id, %{node | attrs: Map.put(node.attrs, "fan_out", "false")}}
          else
            {id, node}
          end
        end)

      %{graph | nodes: patched_nodes}
    else
      graph
    end
  end

  # -- Path Resolution --

  defp resolve_stdlib_path(filename) do
    resolve_pipeline_path(Path.join("stdlib", filename))
  end

  defp resolve_pipeline_path(relative) do
    candidates = [
      Path.join([File.cwd!(), "specs", "pipelines", relative]),
      Path.join([File.cwd!(), "apps", "arbor_orchestrator", "specs", "pipelines", relative])
    ]

    Enum.find(candidates, List.first(candidates), &File.exists?/1)
  end

  defp resolve_path(path) do
    if Path.type(path) == :absolute do
      path
    else
      candidates = [
        Path.join(File.cwd!(), path),
        Path.join([File.cwd!(), "apps", "arbor_orchestrator", path])
      ]

      Enum.find(candidates, List.first(candidates), &File.exists?/1)
    end
  end

  defp subsequence?([], _expected), do: true
  defp subsequence?(_list, []), do: true

  defp subsequence?(list, [head | tail]) do
    case Enum.drop_while(list, &(&1 != head)) do
      [^head | rest] -> subsequence?(rest, tail)
      [] -> false
    end
  end
end
