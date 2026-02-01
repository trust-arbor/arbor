defmodule Arbor.SDLC.Processors.ConsistencyChecker do
  @moduledoc """
  Periodic health checks and INDEX.md maintenance.

  The ConsistencyChecker runs on schedule (not per-item) and performs:

  1. **Completion detection** — Scan in_progress for done items (LLM analyzes git commits)
  2. **Index refresh** — Rebuild INDEX.md from actual directory contents
  3. **Stale item detection** — Flag items stuck too long in any stage
  4. **Health check** — Verify required fields in all items

  ## Scheduling

  This processor doesn't watch for file changes. Instead, it runs on a timer
  and can be triggered manually via `run/1`.

  ## Check Types

  | Check | LLM Required | Description |
  |-------|--------------|-------------|
  | `completion_detection` | Yes (moderate) | Check if in_progress items are done |
  | `index_refresh` | No | Rebuild INDEX.md files |
  | `stale_detection` | No | Find items stuck too long |
  | `health_check` | No | Verify required fields |

  ## Usage

      # Run all checks
      {:ok, results} = ConsistencyChecker.run([])

      # Run specific checks
      {:ok, results} = ConsistencyChecker.run(checks: [:index_refresh, :health_check])

      # Dry run (don't write changes)
      {:ok, results} = ConsistencyChecker.run(dry_run: true)
  """

  @behaviour Arbor.Contracts.Flow.Processor

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events, Pipeline}

  @processor_id "sdlc_consistency_checker"

  @all_checks [:completion_detection, :index_refresh, :stale_detection, :health_check]

  @impl true
  def processor_id, do: @processor_id

  @impl true
  def can_handle?(_item) do
    # ConsistencyChecker doesn't handle individual items
    # It processes directories, not items
    false
  end

  @impl true
  def process_item(_item, _opts) do
    # ConsistencyChecker doesn't process individual items
    {:ok, :no_action}
  end

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Run consistency checks.

  ## Options

  - `:checks` - List of checks to run (default: all)
  - `:dry_run` - Don't write changes (default: false)
  - `:config` - Custom config (default: Config.new())
  - `:ai_module` - AI module for LLM checks (default: Arbor.AI)
  - `:stale_threshold_days` - Days before item is considered stale (default: 14)

  ## Returns

      {:ok, %{
        checks_run: [:index_refresh, :health_check, ...],
        issues_found: 5,
        items_flagged: ["path/to/item.md", ...],
        details: %{...}
      }}
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    config = Keyword.get(opts, :config, Config.new())
    checks = Keyword.get(opts, :checks, @all_checks)
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("Running consistency checks", checks: checks, dry_run: dry_run)

    start_time = System.monotonic_time(:millisecond)

    results =
      checks
      |> Enum.map(fn check ->
        {check, run_check(check, config, opts)}
      end)
      |> Map.new()

    duration_ms = System.monotonic_time(:millisecond) - start_time

    summary = summarize_results(results, checks)

    Events.emit_consistency_check_completed(summary, duration_ms: duration_ms)

    Logger.info("Consistency checks complete",
      checks_run: length(checks),
      issues_found: summary.issues_found,
      duration_ms: duration_ms
    )

    {:ok, Map.put(summary, :details, results)}
  end

  @doc """
  List available checks.
  """
  @spec available_checks() :: [atom()]
  def available_checks, do: @all_checks

  # =============================================================================
  # Individual Checks
  # =============================================================================

  defp run_check(:completion_detection, config, opts) do
    Logger.debug("Running completion detection check")

    ai_module = Keyword.get(opts, :ai_module, config.ai_module)
    dry_run = Keyword.get(opts, :dry_run, false)

    in_progress_dir = Pipeline.stage_path(:in_progress, config.roadmap_root)

    case File.ls(in_progress_dir) do
      {:ok, files} ->
        detect_completed_items(files, in_progress_dir, ai_module, dry_run, config)

      {:error, :enoent} ->
        %{status: :ok, items_checked: 0, completed_detected: 0, moved: 0, items: []}

      {:error, reason} ->
        %{status: :error, reason: reason}
    end
  end

  defp run_check(:index_refresh, config, opts) do
    Logger.debug("Running index refresh check")

    dry_run = Keyword.get(opts, :dry_run, false)
    roadmap_root = config.roadmap_root

    stages = Pipeline.stages()

    results =
      stages
      |> Enum.map(fn stage ->
        stage_path = Pipeline.stage_path(stage, roadmap_root)
        {stage, refresh_index(stage_path, dry_run)}
      end)
      |> Map.new()

    updated_count = Enum.count(results, fn {_, result} -> result.updated end)

    %{
      status: :ok,
      stages_checked: length(stages),
      indexes_updated: updated_count,
      results: results
    }
  end

  defp run_check(:stale_detection, config, opts) do
    Logger.debug("Running stale detection check")

    threshold_days = Keyword.get(opts, :stale_threshold_days, 14)
    roadmap_root = config.roadmap_root

    stale_items =
      [:inbox, :brainstorming, :in_progress]
      |> Enum.flat_map(fn stage ->
        stage_path = Pipeline.stage_path(stage, roadmap_root)
        find_stale_items(stage_path, threshold_days)
      end)

    %{
      status: :ok,
      threshold_days: threshold_days,
      stale_count: length(stale_items),
      items: stale_items
    }
  end

  defp run_check(:health_check, config, _opts) do
    Logger.debug("Running health check")

    roadmap_root = config.roadmap_root

    issues =
      Pipeline.stages()
      |> Enum.flat_map(fn stage ->
        stage_path = Pipeline.stage_path(stage, roadmap_root)
        check_stage_health(stage_path, stage)
      end)

    %{
      status: :ok,
      issues_found: length(issues),
      issues: issues
    }
  end

  defp run_check(unknown_check, _config, _opts) do
    %{status: :error, reason: {:unknown_check, unknown_check}}
  end

  defp detect_completed_items(files, in_progress_dir, ai_module, dry_run, config) do
    md_files = Enum.filter(files, &String.ends_with?(&1, ".md"))

    completed_items =
      md_files
      |> Enum.map(fn file -> Path.join(in_progress_dir, file) end)
      |> Enum.filter(&item_looks_complete?(&1, ai_module))

    if not dry_run do
      Enum.each(completed_items, fn path ->
        move_to_completed(path, config)
      end)
    end

    %{
      status: :ok,
      items_checked: length(md_files),
      completed_detected: length(completed_items),
      moved: if(dry_run, do: 0, else: length(completed_items)),
      items: completed_items
    }
  end

  # =============================================================================
  # Completion Detection Helpers
  # =============================================================================

  defp item_looks_complete?(path, ai_module) do
    case File.read(path) do
      {:ok, content} -> check_item_completion(content, ai_module)
      {:error, _} -> false
    end
  end

  defp check_item_completion(content, ai_module) do
    item_map = ItemParser.parse(content)

    case Item.new(Keyword.new(item_map)) do
      {:ok, item} ->
        all_criteria_done = Item.all_criteria_completed?(item) and Item.all_done_completed?(item)
        all_criteria_done or analyze_completion_with_llm(item, ai_module)

      {:error, _} ->
        false
    end
  end

  defp analyze_completion_with_llm(item, ai_module) do
    prompt = """
    # Item Analysis

    ## Title
    #{item.title}

    ## Summary
    #{item.summary || "No summary"}

    ## Acceptance Criteria
    #{format_criteria_with_status(item.acceptance_criteria)}

    ## Definition of Done
    #{format_criteria_with_status(item.definition_of_done)}

    # Question

    Based on the acceptance criteria and definition of done, does this item
    appear to be complete? Consider:
    - Are most criteria marked as done?
    - Does the summary suggest completion?
    - Are there any obvious blockers?

    Respond with ONLY "yes" or "no".
    """

    ai_backend = Config.new().ai_backend

    case ai_module.generate_text(prompt, max_tokens: 10, temperature: 0.1, backend: ai_backend) do
      {:ok, response} ->
        String.downcase(response.text) |> String.contains?("yes")

      {:error, _} ->
        false
    end
  end

  defp format_criteria_with_status(criteria) when is_list(criteria) do
    criteria
    |> Enum.map(fn
      %{text: text, completed: true} -> "- [x] #{text}"
      %{text: text, completed: false} -> "- [ ] #{text}"
      %{text: text} -> "- [ ] #{text}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> case do
      "" -> "None specified"
      text -> text
    end
  end

  defp format_criteria_with_status(_), do: "None specified"

  defp move_to_completed(path, config) do
    filename = Path.basename(path)
    dest_dir = Pipeline.stage_path(:completed, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    File.mkdir_p!(dest_dir)

    case File.rename(path, dest_path) do
      :ok ->
        Logger.info("Moved completed item", from: path, to: dest_path)

      {:error, reason} ->
        Logger.warning("Failed to move completed item", path: path, reason: inspect(reason))
    end
  end

  # =============================================================================
  # Index Refresh Helpers
  # =============================================================================

  defp refresh_index(stage_path, dry_run) do
    case File.ls(stage_path) do
      {:ok, files} ->
        build_and_write_index(stage_path, files, dry_run)

      {:error, :enoent} ->
        %{updated: false, would_update: false, items_count: 0}

      {:error, reason} ->
        %{updated: false, error: reason}
    end
  end

  defp build_and_write_index(stage_path, files, dry_run) do
    index_path = Path.join(stage_path, "INDEX.md")

    md_files =
      files
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.reject(&(&1 == "INDEX.md"))

    items = Enum.flat_map(md_files, &read_item_file(stage_path, &1))

    new_index = generate_stage_index(items, stage_path)

    old_index =
      case File.read(index_path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    needs_update = new_index != old_index

    if needs_update and not dry_run do
      File.write!(index_path, new_index)
    end

    %{
      updated: needs_update and not dry_run,
      would_update: needs_update,
      items_count: length(items)
    }
  end

  defp read_item_file(stage_path, file) do
    full_path = Path.join(stage_path, file)

    case File.read(full_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        [Map.put(item_map, :path, full_path)]

      {:error, _} ->
        []
    end
  end

  defp generate_stage_index(items, stage_path) do
    stage_name = Path.basename(stage_path)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    item_lines =
      items
      |> Enum.sort_by(fn item -> item[:priority] || :medium end, &priority_order/2)
      |> Enum.map(fn item ->
        title = item[:title] || "Untitled"
        filename = Path.basename(item[:path] || "")
        priority = item[:priority]

        if priority do
          "- [#{title}](#{filename}) - Priority: #{priority}"
        else
          "- [#{title}](#{filename})"
        end
      end)

    content =
      if Enum.empty?(item_lines) do
        "_No items_"
      else
        Enum.join(item_lines, "\n")
      end

    """
    # #{stage_name} Index

    _Last updated: #{now}_

    ## Items

    #{content}
    """
  end

  defp priority_order(a, b) do
    order = %{critical: 0, high: 1, medium: 2, low: 3, someday: 4}
    Map.get(order, a, 2) <= Map.get(order, b, 2)
  end

  # =============================================================================
  # Stale Detection Helpers
  # =============================================================================

  defp find_stale_items(stage_path, threshold_days) do
    threshold_seconds = threshold_days * 24 * 60 * 60

    case File.ls(stage_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 == "INDEX.md"))
        |> Enum.filter(&file_older_than?(stage_path, &1, threshold_seconds))
        |> Enum.map(fn file -> Path.join(stage_path, file) end)

      {:error, _} ->
        []
    end
  end

  defp file_older_than?(stage_path, file, threshold_seconds) do
    full_path = Path.join(stage_path, file)

    case File.stat(full_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        now = System.os_time(:second)
        now - mtime > threshold_seconds

      {:error, _} ->
        false
    end
  end

  # =============================================================================
  # Health Check Helpers
  # =============================================================================

  defp check_stage_health(stage_path, stage) do
    case File.ls(stage_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 == "INDEX.md"))
        |> Enum.flat_map(fn file ->
          full_path = Path.join(stage_path, file)
          check_item_health(full_path, stage)
        end)

      {:error, _} ->
        []
    end
  end

  defp check_item_health(path, stage) do
    case File.read(path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        validate_item(path, item_map, stage)

      {:error, reason} ->
        [{path, :file_read_error, reason}]
    end
  end

  defp validate_item(path, item_map, stage) do
    issues = []

    # Check for required fields based on stage
    issues =
      if item_map[:title] in [nil, ""] do
        [{path, :missing_title, nil} | issues]
      else
        issues
      end

    # Brainstorming and later should have priority/category
    issues =
      if stage in [:brainstorming, :planned, :in_progress] do
        issues =
          if item_map[:priority] == nil do
            [{path, :missing_priority, nil} | issues]
          else
            issues
          end

        if item_map[:category] == nil do
          [{path, :missing_category, nil} | issues]
        else
          issues
        end
      else
        issues
      end

    # Planned and in_progress should have acceptance criteria
    issues =
      if stage in [:planned, :in_progress] do
        if item_map[:acceptance_criteria] in [nil, []] do
          [{path, :missing_acceptance_criteria, nil} | issues]
        else
          issues
        end
      else
        issues
      end

    issues
  end

  # =============================================================================
  # Results Summary
  # =============================================================================

  defp summarize_results(results, checks) do
    issues_found =
      results
      |> Enum.map(fn
        {_, %{issues_found: n}} -> n
        {_, %{stale_count: n}} -> n
        {_, %{completed_detected: n}} -> n
        {_, %{indexes_updated: n}} -> n
        _ -> 0
      end)
      |> Enum.sum()

    items_flagged =
      results
      |> Enum.flat_map(fn
        {_, %{items: items}} when is_list(items) ->
          items

        {_, %{issues: issues}} when is_list(issues) ->
          Enum.map(issues, fn {path, _, _} -> path end)

        _ ->
          []
      end)
      |> Enum.uniq()

    %{
      checks_run: checks,
      issues_found: issues_found,
      items_flagged: items_flagged
    }
  end
end
