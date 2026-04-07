defmodule Arbor.Dashboard.Cores.EvalCore do
  @moduledoc """
  Pure display formatters and stats computations for the eval dashboard.

  eval_live had ~32 inline helpers — the highest density of any LiveView
  in Arbor. This module owns all of them so the dashboard, future API
  endpoints, and tests see the same shapes.

  ## Structure

  - **Convert per item**: `show_run/1`, `show_run_summary/1`
  - **Stats**: `compute_stats/1`, `default_stats/0`
  - **Field accessors**: `run_field/2`, `get_accuracy/1`
  - **Formatters**: `format_accuracy/1`, `format_pct/1`, `format_duration/1`,
    `format_relative_time/1`, etc.
  - **Color helpers**: `domain_color/1`, `status_color/1`, `data_source_color/1`
  - **Labels**: `tab_label/1`, `data_source_label/1`

  All formatters tolerate `nil`, missing fields, and mixed atom/string keys.
  """

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc """
  Format a single eval run for display in the runs table.

  Returns a map with id, status, status_color, domain, domain_color, model,
  duration_label, accuracy_label, mean_score_label, sample_count, graders_label,
  scores_label, and a relative time label.
  """
  @spec show_run(map()) :: map()
  def show_run(run) when is_map(run) do
    status = run_field(run, :status)
    domain = run_field(run, :domain)
    metrics = run_field(run, :metrics)

    %{
      id: run_field(run, :id),
      status: status,
      status_color: status_color(status),
      domain: domain,
      domain_color: domain_color(domain),
      model: run_field(run, :model),
      duration_ms: run_field(run, :duration_ms),
      duration_label: format_duration(run_field(run, :duration_ms)),
      sample_count: run_field(run, :sample_count) || 0,
      sample_count_label: format_sample_count(run_field(run, :sample_count)),
      accuracy_label: format_accuracy(metrics),
      mean_score_label: format_mean_score(metrics),
      graders_label: format_graders(run_field(run, :graders)),
      scores_label: format_scores(run_field(run, :scores)),
      started_at: run_field(run, :started_at) || run_field(run, :inserted_at),
      time_relative:
        format_relative_time(run_field(run, :started_at) || run_field(run, :inserted_at))
    }
  end

  @doc "Format a list of runs for the runs table."
  @spec show_runs([map()] | nil) :: [map()]
  def show_runs(nil), do: []
  def show_runs([]), do: []
  def show_runs(runs) when is_list(runs), do: Enum.map(runs, &show_run/1)

  @doc """
  Compute summary stats from a list of runs.

  Returns `{total, completed_pct, avg_accuracy, avg_duration}` shaped as
  `%{total, completed_pct, avg_accuracy, avg_duration}`. All numeric
  computations only consider completed runs. Returns default zeros for
  empty input.
  """
  @spec compute_stats([map()] | nil) :: map()
  def compute_stats(nil), do: default_stats()
  def compute_stats([]), do: default_stats()

  def compute_stats(runs) when is_list(runs) do
    total = length(runs)

    completed_runs = Enum.filter(runs, fn r -> run_field(r, :status) == "completed" end)
    completed = length(completed_runs)

    completed_pct =
      if total > 0, do: "#{Float.round(completed / total * 100, 1)}%", else: "--"

    accuracies =
      completed_runs
      |> Enum.map(fn r -> get_accuracy(run_field(r, :metrics)) end)
      |> Enum.filter(&is_number/1)

    avg_accuracy =
      if accuracies != [] do
        format_pct(Enum.sum(accuracies) / length(accuracies))
      else
        "--"
      end

    durations =
      completed_runs
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

  @doc "Default stats map (used when there are no runs)."
  @spec default_stats() :: map()
  def default_stats do
    %{total: 0, completed_pct: "--", avg_accuracy: "--", avg_duration: "--"}
  end

  # ===========================================================================
  # Field accessors
  # ===========================================================================

  @doc """
  Read a field from a run map, tolerating both atom and string keys.
  """
  @spec run_field(map(), atom()) :: term()
  def run_field(run, key) when is_atom(key) do
    Map.get(run, key) || Map.get(run, Atom.to_string(key))
  end

  @doc "Extract the accuracy value from a metrics map."
  @spec get_accuracy(map() | nil) :: number() | nil
  def get_accuracy(nil), do: nil

  def get_accuracy(metrics) when is_map(metrics) do
    metrics["accuracy"] || metrics[:accuracy]
  end

  def get_accuracy(_), do: nil

  # ===========================================================================
  # Formatters
  # ===========================================================================

  @doc "Format an accuracy value (or metrics map) as a percentage string."
  @spec format_accuracy(map() | nil | term()) :: String.t()
  def format_accuracy(nil), do: "--"

  def format_accuracy(metrics) when is_map(metrics) do
    case get_accuracy(metrics) do
      nil -> "--"
      acc when is_number(acc) -> format_pct(acc)
      _ -> "--"
    end
  end

  def format_accuracy(_), do: "--"

  @doc "Format a mean_score from a metrics map."
  @spec format_mean_score(map() | nil | term()) :: String.t()
  def format_mean_score(nil), do: "--"

  def format_mean_score(metrics) when is_map(metrics) do
    score = metrics["mean_score"] || metrics[:mean_score]
    if is_number(score), do: Float.round(score * 1.0, 3) |> to_string(), else: "--"
  end

  def format_mean_score(_), do: "--"

  @doc "Format a number 0..1 as a percentage with one decimal."
  @spec format_pct(number() | nil) :: String.t()
  def format_pct(nil), do: "--"
  def format_pct(val) when is_number(val), do: "#{Float.round(val * 100.0, 1)}%"
  def format_pct(_), do: "--"

  @doc "Format a sample count integer as a string, defaulting to '0'."
  @spec format_sample_count(integer() | nil | term()) :: String.t()
  def format_sample_count(nil), do: "0"
  def format_sample_count(n) when is_integer(n), do: Integer.to_string(n)
  def format_sample_count(_), do: "0"

  @doc """
  Format a duration in milliseconds as a human-readable string.

  Tiers: <1s → "Nms", <1min → "Ns", >=1min → "Nm Ns".
  """
  @spec format_duration(integer() | nil | term()) :: String.t()
  def format_duration(nil), do: "--"
  def format_duration(0), do: "--"
  def format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  def format_duration(ms) when is_integer(ms) and ms < 60_000 do
    "#{Float.round(ms / 1000, 1)}s"
  end

  def format_duration(ms) when is_integer(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m #{secs}s"
  end

  def format_duration(_), do: "--"

  @doc "Format a list of grader names as a comma-separated string."
  @spec format_graders([String.t()] | nil | term()) :: String.t()
  def format_graders(nil), do: "--"
  def format_graders([]), do: "--"
  def format_graders(graders) when is_list(graders), do: Enum.join(graders, ", ")
  def format_graders(_), do: "--"

  @doc """
  Format a scores map as 'grader: 0.92 · grader2: 0.85'.

  Each entry can be either a number or a map with a `score` key.
  """
  @spec format_scores(map() | nil | term()) :: String.t()
  def format_scores(nil), do: ""

  def format_scores(scores) when is_map(scores) do
    scores
    |> Enum.map(fn {grader, score_data} ->
      score =
        if is_map(score_data), do: score_data["score"] || score_data[:score], else: score_data

      if is_number(score), do: "#{grader}: #{Float.round(score * 1.0, 2)}", else: nil
    end)
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def format_scores(_), do: ""

  @doc "Format a DateTime/NaiveDateTime/ISO string as a 'just now / Nm ago' label."
  @spec format_relative_time(term()) :: String.t()
  def format_relative_time(nil), do: ""

  def format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  def format_relative_time(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> format_relative_time(dt)
      _ -> ""
    end
  end

  def format_relative_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> format_relative_time(dt)
      _ -> str
    end
  end

  def format_relative_time(_), do: ""

  @doc "Compare two timestamps in descending order (newest first)."
  @spec datetime_compare_desc(term(), term()) :: boolean()
  def datetime_compare_desc(a, b) do
    case {a, b} do
      {%DateTime{} = da, %DateTime{} = db} -> DateTime.compare(da, db) != :lt
      {%NaiveDateTime{} = na, %NaiveDateTime{} = nb} -> NaiveDateTime.compare(na, nb) != :lt
      _ -> true
    end
  end

  # ===========================================================================
  # Colors and labels
  # ===========================================================================

  @doc "Color atom for an eval domain badge."
  @spec domain_color(String.t() | nil) :: atom()
  def domain_color("coding"), do: :blue
  def domain_color("chat"), do: :green
  def domain_color("heartbeat"), do: :purple
  def domain_color("embedding"), do: :orange
  def domain_color("advisory_consultation"), do: :yellow
  def domain_color("llm_judge"), do: :red
  def domain_color(_), do: :gray

  @doc "Color atom for an eval run status badge."
  @spec status_color(String.t() | nil) :: atom()
  def status_color("completed"), do: :green
  def status_color("running"), do: :blue
  def status_color("failed"), do: :error
  def status_color(_), do: :gray

  @doc "Display label for the data source backend."
  @spec data_source_label(atom()) :: String.t()
  def data_source_label(:postgres), do: "Postgres"
  def data_source_label(:unavailable), do: "Offline"
  def data_source_label(_), do: "Unknown"

  @doc "Color atom for the data source badge."
  @spec data_source_color(atom()) :: atom()
  def data_source_color(:postgres), do: :green
  def data_source_color(:unavailable), do: :error
  def data_source_color(_), do: :gray

  @doc "Tab label for the runs/models tabs."
  @spec tab_label(String.t()) :: String.t()
  def tab_label("runs"), do: "Runs"
  def tab_label("models"), do: "Models"
  def tab_label(other), do: String.capitalize(other)

  # ===========================================================================
  # Misc helpers
  # ===========================================================================

  @doc "Convert empty strings to nil (useful for optional form fields)."
  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(nil), do: nil
  def blank_to_nil(str), do: str
end
