defmodule Arbor.Dashboard.Live.EvalLive do
  @moduledoc """
  Evaluation results dashboard.

  Displays LLM eval runs, model comparison, and detailed results.
  Supports both Postgres (via Arbor.Persistence) and JSON fallback
  (via Arbor.Orchestrator.Eval.PersistenceBridge).
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  @tabs ~w(runs models)

  @domains ~w(coding chat heartbeat embedding)
  @statuses ~w(completed running failed)

  # Make lists available in templates via assigns
  defp tabs, do: @tabs
  defp domains, do: @domains
  defp statuses, do: @statuses

  @impl true
  def mount(_params, _session, socket) do
    {runs, stats, data_source} =
      if connected?(socket) do
        source = detect_data_source()
        runs = safe_list_runs([])
        {runs, compute_stats(runs), source}
      else
        {[], default_stats(), :unknown}
      end

    socket =
      socket
      |> assign(
        page_title: "Eval",
        active_tab: "runs",
        tabs: tabs(),
        domains: domains(),
        statuses: statuses(),
        selected_run: nil,
        run_detail: nil,
        filter_domain: nil,
        filter_status: nil,
        filter_model: "",
        model_data: nil,
        stats: stats,
        data_source: data_source
      )
      |> stream(:runs, runs)
      |> stream(:results, [])

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Evaluation" subtitle="LLM eval runs and model comparison">
      <:actions>
        <.badge
          label={data_source_label(@data_source)}
          color={data_source_color(@data_source)}
        />
        <button class="aw-btn aw-btn-sm" phx-click="refresh">Refresh</button>
      </:actions>
    </.dashboard_header>

    <%!-- Tab bar --%>
    <div class="aw-tab-bar">
      <button
        :for={tab <- @tabs}
        class={"aw-tab #{if @active_tab == tab, do: "aw-tab-active"}"}
        phx-click="change-tab"
        phx-value-tab={tab}
      >
        {tab_label(tab)}
      </button>
    </div>

    <%!-- Runs tab --%>
    <div :if={@active_tab == "runs" and @selected_run == nil}>
      <%!-- Stat cards --%>
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-bottom: 1.5rem;">
        <.stat_card value={@stats.total} label="Total Runs" color={:blue} />
        <.stat_card value={@stats.completed_pct} label="Completed %" color={:green} />
        <.stat_card value={@stats.avg_accuracy} label="Avg Accuracy" color={:purple} />
        <.stat_card value={@stats.avg_duration} label="Avg Duration" color={:orange} />
      </div>

      <%!-- Filters --%>
      <.filter_bar>
        <form
          phx-change="filter-change"
          style="display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap;"
        >
          <select name="domain" class="aw-select">
            <option value="" selected={@filter_domain == nil}>All Domains</option>
            <option :for={d <- @domains} value={d} selected={@filter_domain == d}>
              {String.capitalize(d)}
            </option>
          </select>

          <select name="status" class="aw-select">
            <option value="" selected={@filter_status == nil}>All Statuses</option>
            <option :for={s <- @statuses} value={s} selected={@filter_status == s}>
              {String.capitalize(s)}
            </option>
          </select>

          <input
            type="text"
            name="model"
            value={@filter_model}
            placeholder="Filter by model..."
            class="aw-input"
            phx-debounce="300"
          />

          <button
            :if={@filter_domain || @filter_status || @filter_model != ""}
            type="button"
            class="aw-btn aw-btn-sm"
            phx-click="clear-filters"
          >
            Clear
          </button>
        </form>
      </.filter_bar>

      <%!-- Runs list --%>
      <div id="runs-stream" phx-update="stream" style="margin-top: 1rem;">
        <div
          :for={{dom_id, run} <- @streams.runs}
          id={dom_id}
          class="aw-card aw-card-hover"
          style="margin-bottom: 0.5rem; cursor: pointer;"
          phx-click="select-run"
          phx-value-id={run_field(run, :id)}
        >
          <div style="display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem;">
            <.badge
              label={run_field(run, :domain) || "?"}
              color={domain_color(run_field(run, :domain))}
            />
            <div style="flex: 1; min-width: 0;">
              <div style="font-weight: 600; font-size: 0.9rem;">
                {run_field(run, :model) || "unknown"}
              </div>
              <div style="font-size: 0.75rem; opacity: 0.7;">
                {run_field(run, :provider) || ""} · {run_field(run, :dataset) || ""}
              </div>
            </div>
            <.badge
              label={run_field(run, :status) || "?"}
              color={status_color(run_field(run, :status))}
            />
            <div style="text-align: right; min-width: 80px;">
              <div style="font-size: 0.9rem; font-weight: 600;">
                {format_accuracy(run_field(run, :metrics))}
              </div>
              <div style="font-size: 0.75rem; opacity: 0.7;">
                {format_sample_count(run_field(run, :sample_count))} samples
              </div>
            </div>
            <div style="font-size: 0.75rem; opacity: 0.6; min-width: 70px; text-align: right;">
              {format_duration(run_field(run, :duration_ms))}
            </div>
            <div style="font-size: 0.7rem; opacity: 0.5; min-width: 80px; text-align: right;">
              {format_relative_time(run_field(run, :inserted_at))}
            </div>
          </div>
        </div>
      </div>

      <div :if={stream_empty?(@streams.runs)}>
        <.empty_state
          icon="📊"
          title="No eval runs found"
          hint="Run evaluations with `mix arbor.eval` to see results here."
        />
      </div>
    </div>

    <%!-- Run detail view --%>
    <div :if={@active_tab == "runs" and @selected_run != nil and @run_detail != nil}>
      <button class="aw-btn aw-btn-sm" phx-click="back-to-runs" style="margin-bottom: 1rem;">
        &larr; Back to runs
      </button>

      <.card title={"Run: #{run_field(@run_detail, :id)}"}>
        <%!-- Metadata grid --%>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 0.75rem; margin-bottom: 1.5rem;">
          <div>
            <div class="aw-label">Model</div>
            <div>{run_field(@run_detail, :model)}</div>
          </div>
          <div>
            <div class="aw-label">Provider</div>
            <div>{run_field(@run_detail, :provider)}</div>
          </div>
          <div>
            <div class="aw-label">Domain</div>
            <.badge
              label={run_field(@run_detail, :domain) || "?"}
              color={domain_color(run_field(@run_detail, :domain))}
            />
          </div>
          <div>
            <div class="aw-label">Dataset</div>
            <div>{run_field(@run_detail, :dataset)}</div>
          </div>
          <div>
            <div class="aw-label">Status</div>
            <.badge
              label={run_field(@run_detail, :status) || "?"}
              color={status_color(run_field(@run_detail, :status))}
            />
          </div>
          <div>
            <div class="aw-label">Graders</div>
            <div>{format_graders(run_field(@run_detail, :graders))}</div>
          </div>
        </div>

        <%!-- Metrics stat cards --%>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 0.75rem; margin-bottom: 1.5rem;">
          <.stat_card
            value={format_accuracy(run_field(@run_detail, :metrics))}
            label="Accuracy"
            color={:green}
          />
          <.stat_card
            value={format_mean_score(run_field(@run_detail, :metrics))}
            label="Mean Score"
            color={:purple}
          />
          <.stat_card
            value={format_sample_count(run_field(@run_detail, :sample_count))}
            label="Samples"
            color={:blue}
          />
          <.stat_card
            value={format_duration(run_field(@run_detail, :duration_ms))}
            label="Duration"
            color={:orange}
          />
        </div>

        <%!-- Error display --%>
        <div
          :if={run_field(@run_detail, :status) == "failed" and run_field(@run_detail, :error)}
          class="aw-card"
          style="background: var(--aw-error-bg, #2d1b1b); border-color: var(--aw-error-border, #5c2828); margin-bottom: 1rem;"
        >
          <div style="padding: 0.75rem;">
            <strong>Error:</strong> {run_field(@run_detail, :error)}
          </div>
        </div>
      </.card>

      <%!-- Results --%>
      <div style="margin-top: 1rem;">
        <.card title="Results">
          <div id="results-stream" phx-update="stream">
            <div
              :for={{dom_id, result} <- @streams.results}
              id={dom_id}
              class="aw-card"
              style="margin-bottom: 0.5rem;"
            >
              <div
                style="display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem; cursor: pointer;"
                phx-click="toggle-result"
                phx-value-id={run_field(result, :id)}
              >
                <span style="font-size: 1.2rem;">
                  {if run_field(result, :passed), do: "✅", else: "❌"}
                </span>
                <div style="flex: 1; font-size: 0.85rem;">
                  <strong>{run_field(result, :sample_id)}</strong>
                </div>
                <div style="font-size: 0.8rem; opacity: 0.7;">
                  {format_scores(run_field(result, :scores))}
                </div>
                <div style="font-size: 0.75rem; opacity: 0.6;">
                  {format_duration(run_field(result, :duration_ms))}
                </div>
              </div>

              <%!-- Expandable detail --%>
              <div
                :if={run_field(result, :id) in (@expanded_results || MapSet.new())}
                style="padding: 0 0.75rem 0.75rem; font-size: 0.8rem;"
              >
                <div :if={run_field(result, :input)} style="margin-bottom: 0.5rem;">
                  <div class="aw-label">Input</div>
                  <pre style="white-space: pre-wrap; opacity: 0.85; max-height: 200px; overflow: auto;"><%= run_field(result, :input) %></pre>
                </div>
                <div :if={run_field(result, :expected)} style="margin-bottom: 0.5rem;">
                  <div class="aw-label">Expected</div>
                  <pre style="white-space: pre-wrap; opacity: 0.85; max-height: 200px; overflow: auto;"><%= run_field(result, :expected) %></pre>
                </div>
                <div :if={run_field(result, :actual)} style="margin-bottom: 0.5rem;">
                  <div class="aw-label">Actual</div>
                  <pre style="white-space: pre-wrap; opacity: 0.85; max-height: 200px; overflow: auto;"><%= run_field(result, :actual) %></pre>
                </div>
              </div>
            </div>
          </div>

          <div :if={stream_empty?(@streams.results)}>
            <.empty_state
              icon="📝"
              title="No results"
              hint="This run has no individual results recorded."
            />
          </div>
        </.card>
      </div>
    </div>

    <%!-- Models tab --%>
    <div :if={@active_tab == "models"}>
      <div :if={@model_data && map_size(@model_data) > 0}>
        <%!-- Model cards --%>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem;">
          <.card :for={{model, domains} <- @model_data} title={model}>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem;">
              <div :for={{domain, info} <- domains}>
                <div style="display: flex; justify-content: space-between; align-items: center;">
                  <.badge label={domain} color={domain_color(domain)} />
                  <span style="font-weight: 600; font-size: 0.9rem;">
                    {format_pct(info.accuracy)}
                  </span>
                </div>
                <div style="font-size: 0.7rem; opacity: 0.6;">
                  {info.run_count} runs · last {format_relative_time(info.last_run)}
                </div>
              </div>
            </div>
          </.card>
        </div>
      </div>

      <div :if={@model_data == nil || @model_data == %{}}>
        <.empty_state
          icon="📊"
          title="No model data"
          hint="Complete some eval runs to see model comparison data."
        />
      </div>
    </div>
    """
  end

  # ── Events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("change-tab", %{"tab" => tab}, socket) when tab in @tabs do
    socket =
      socket
      |> assign(:active_tab, tab)
      |> assign(:selected_run, nil)
      |> assign(:run_detail, nil)

    socket =
      if tab == "models" do
        assign(socket, :model_data, load_model_data())
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("filter-change", params, socket) do
    domain = blank_to_nil(params["domain"])
    status = blank_to_nil(params["status"])
    model = params["model"] || ""

    socket =
      socket
      |> assign(filter_domain: domain, filter_status: status, filter_model: model)
      |> reload_runs()

    {:noreply, socket}
  end

  def handle_event("clear-filters", _params, socket) do
    socket =
      socket
      |> assign(filter_domain: nil, filter_status: nil, filter_model: "")
      |> reload_runs()

    {:noreply, socket}
  end

  def handle_event("select-run", %{"id" => run_id}, socket) do
    case safe_get_run(run_id) do
      nil ->
        {:noreply, socket}

      run ->
        results = extract_results(run)

        socket =
          socket
          |> assign(selected_run: run_id, run_detail: run, expanded_results: MapSet.new())
          |> stream(:results, Enum.take(results, 100), reset: true)

        {:noreply, socket}
    end
  end

  def handle_event("back-to-runs", _params, socket) do
    socket =
      socket
      |> assign(selected_run: nil, run_detail: nil, expanded_results: MapSet.new())
      |> stream(:results, [], reset: true)

    {:noreply, socket}
  end

  def handle_event("toggle-result", %{"id" => result_id}, socket) do
    expanded = socket.assigns[:expanded_results] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, result_id) do
        MapSet.delete(expanded, result_id)
      else
        MapSet.put(expanded, result_id)
      end

    {:noreply, assign(socket, :expanded_results, expanded)}
  end

  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:data_source, detect_data_source())
      |> reload_runs()

    socket =
      if socket.assigns.active_tab == "models" do
        assign(socket, :model_data, load_model_data())
      else
        socket
      end

    {:noreply, socket}
  end

  # ── Data loading ────────────────────────────────────────────────────

  defp reload_runs(socket) do
    filters = build_filters(socket.assigns)
    runs = safe_list_runs(filters)

    socket
    |> assign(:stats, compute_stats(runs))
    |> stream(:runs, runs, reset: true)
  end

  defp build_filters(assigns) do
    filters = []

    filters =
      if assigns.filter_domain, do: [{:domain, assigns.filter_domain} | filters], else: filters

    filters =
      if assigns.filter_status, do: [{:status, assigns.filter_status} | filters], else: filters

    filters
  end

  defp safe_list_runs(filters) do
    runs =
      case Arbor.Persistence.list_eval_runs(filters) do
        {:ok, runs} -> runs
        _ -> []
      end

    # Apply model text filter client-side (not supported as a DB filter)
    runs
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_get_run(run_id) do
    case Arbor.Persistence.get_eval_run(run_id) do
      {:ok, run} -> run
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp extract_results(run) do
    results = run_field(run, :results) || []

    if is_list(results) do
      results
    else
      []
    end
  end

  defp load_model_data do
    runs = safe_list_runs(status: "completed")

    runs
    |> Enum.group_by(&(run_field(&1, :model) || "unknown"))
    |> Map.new(fn {model, model_runs} ->
      domains =
        model_runs
        |> Enum.group_by(&(run_field(&1, :domain) || "unknown"))
        |> Map.new(fn {domain, domain_runs} ->
          accuracies =
            domain_runs
            |> Enum.map(fn r -> get_accuracy(run_field(r, :metrics)) end)
            |> Enum.filter(&is_number/1)

          avg_accuracy =
            if accuracies != [] do
              Enum.sum(accuracies) / length(accuracies)
            else
              nil
            end

          last_run =
            domain_runs
            |> Enum.map(&run_field(&1, :inserted_at))
            |> Enum.filter(& &1)
            |> Enum.sort(&datetime_compare_desc/2)
            |> List.first()

          {domain, %{accuracy: avg_accuracy, run_count: length(domain_runs), last_run: last_run}}
        end)

      {model, domains}
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # ── Stats ───────────────────────────────────────────────────────────

  defp compute_stats(runs) do
    total = length(runs)

    completed =
      Enum.count(runs, fn r -> run_field(r, :status) == "completed" end)

    completed_pct =
      if total > 0, do: "#{Float.round(completed / total * 100, 1)}%", else: "--"

    accuracies =
      runs
      |> Enum.filter(fn r -> run_field(r, :status) == "completed" end)
      |> Enum.map(fn r -> get_accuracy(run_field(r, :metrics)) end)
      |> Enum.filter(&is_number/1)

    avg_accuracy =
      if accuracies != [] do
        format_pct(Enum.sum(accuracies) / length(accuracies))
      else
        "--"
      end

    durations =
      runs
      |> Enum.filter(fn r -> run_field(r, :status) == "completed" end)
      |> Enum.map(fn r -> run_field(r, :duration_ms) end)
      |> Enum.filter(&is_number/1)

    avg_duration =
      if durations != [] do
        avg_ms = Enum.sum(durations) / length(durations)
        format_duration(round(avg_ms))
      else
        "--"
      end

    %{
      total: total,
      completed_pct: completed_pct,
      avg_accuracy: avg_accuracy,
      avg_duration: avg_duration
    }
  end

  defp default_stats do
    %{total: 0, completed_pct: "--", avg_accuracy: "--", avg_duration: "--"}
  end

  # ── Formatting helpers ──────────────────────────────────────────────

  defp run_field(run, key) when is_atom(key) do
    Map.get(run, key) || Map.get(run, Atom.to_string(key))
  end

  defp get_accuracy(nil), do: nil

  defp get_accuracy(metrics) when is_map(metrics) do
    metrics["accuracy"] || metrics[:accuracy]
  end

  defp get_accuracy(_), do: nil

  defp format_accuracy(nil), do: "--"

  defp format_accuracy(metrics) when is_map(metrics) do
    case get_accuracy(metrics) do
      nil -> "--"
      acc when is_number(acc) -> format_pct(acc)
      _ -> "--"
    end
  end

  defp format_accuracy(_), do: "--"

  defp format_mean_score(nil), do: "--"

  defp format_mean_score(metrics) when is_map(metrics) do
    score = metrics["mean_score"] || metrics[:mean_score]
    if is_number(score), do: Float.round(score * 1.0, 3) |> to_string(), else: "--"
  end

  defp format_mean_score(_), do: "--"

  defp format_pct(nil), do: "--"
  defp format_pct(val) when is_number(val), do: "#{Float.round(val * 100.0, 1)}%"
  defp format_pct(_), do: "--"

  defp format_sample_count(nil), do: "0"
  defp format_sample_count(n) when is_integer(n), do: Integer.to_string(n)
  defp format_sample_count(_), do: "0"

  defp format_duration(nil), do: "--"
  defp format_duration(0), do: "--"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) and ms < 60_000 do
    "#{Float.round(ms / 1000, 1)}s"
  end

  defp format_duration(ms) when is_integer(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m #{secs}s"
  end

  defp format_duration(_), do: "--"

  defp format_graders(nil), do: "--"
  defp format_graders([]), do: "--"
  defp format_graders(graders) when is_list(graders), do: Enum.join(graders, ", ")
  defp format_graders(_), do: "--"

  defp format_scores(nil), do: ""

  defp format_scores(scores) when is_map(scores) do
    scores
    |> Enum.map(fn {grader, score_data} ->
      score =
        if is_map(score_data), do: score_data["score"] || score_data[:score], else: score_data

      if is_number(score), do: "#{grader}: #{Float.round(score * 1.0, 2)}", else: nil
    end)
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp format_scores(_), do: ""

  defp format_relative_time(nil), do: ""

  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  defp format_relative_time(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> format_relative_time(dt)
      _ -> ""
    end
  end

  defp format_relative_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> format_relative_time(dt)
      _ -> str
    end
  end

  defp format_relative_time(_), do: ""

  defp datetime_compare_desc(a, b) do
    case {a, b} do
      {%DateTime{} = da, %DateTime{} = db} -> DateTime.compare(da, db) != :lt
      {%NaiveDateTime{} = na, %NaiveDateTime{} = nb} -> NaiveDateTime.compare(na, nb) != :lt
      _ -> true
    end
  end

  # ── Colors ──────────────────────────────────────────────────────────

  defp domain_color("coding"), do: :blue
  defp domain_color("chat"), do: :green
  defp domain_color("heartbeat"), do: :purple
  defp domain_color("embedding"), do: :orange
  defp domain_color(_), do: :gray

  defp status_color("completed"), do: :green
  defp status_color("running"), do: :blue
  defp status_color("failed"), do: :error
  defp status_color(_), do: :gray

  defp data_source_label(:postgres), do: "Postgres"
  defp data_source_label(:unavailable), do: "Offline"
  defp data_source_label(_), do: "Unknown"

  defp data_source_color(:postgres), do: :green
  defp data_source_color(:unavailable), do: :error
  defp data_source_color(_), do: :gray

  # ── Tab helpers ─────────────────────────────────────────────────────

  defp tab_label("runs"), do: "Runs"
  defp tab_label("models"), do: "Models"
  defp tab_label(other), do: String.capitalize(other)

  # ── Data source detection ───────────────────────────────────────────

  defp detect_data_source do
    if repo_available?(), do: :postgres, else: :unavailable
  end

  defp repo_available? do
    pid = Process.whereis(Arbor.Persistence.Repo)
    pid != nil and Process.alive?(pid)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # ── Utilities ───────────────────────────────────────────────────────

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(str), do: str

  defp stream_empty?(stream) do
    # Phoenix.LiveView.stream_empty? isn't available in older versions
    # Use the raw stream check
    Enum.empty?(stream)
  rescue
    _ -> true
  end
end
