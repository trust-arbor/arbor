defmodule Arbor.Dashboard.Cores.MonitorCore do
  @moduledoc """
  Pure business logic for the BEAM runtime monitor dashboard.

  Follows the Construct-Reduce-Convert pattern. All functions are pure
  and side-effect free — no GenServer calls, no atom-to-display logic
  scattered across the LiveView template.

  ## Pipeline

      MonitorCore.new(metrics, anomalies, status)
      |> MonitorCore.select_skill(:memory)
      |> MonitorCore.append_history(metrics)
      |> MonitorCore.show_dashboard()

  ## Why this exists

  monitor_live previously had ~40 lines of inline display formatting
  (extract_primary_value/2, skill_summary/2, skill_icon/1, format_status/1)
  that mixed domain knowledge (which metric is the "primary" one for a skill)
  with view rendering. Moving this into a Convert function makes the
  LiveView a thin renderer and lets tests/CLI/API consume the same shape.
  """

  @history_limit 20

  @type metrics :: %{atom() => map()}
  @type anomaly :: map()
  @type status :: %{
          required(:status) => atom(),
          required(:anomaly_count) => non_neg_integer(),
          required(:skills) => [atom()],
          optional(:metrics_available) => [atom()]
        }

  @type state :: %{
          metrics: metrics(),
          anomalies: [anomaly()],
          status: status(),
          selected_skill: atom() | nil,
          history: %{atom() => [term()]}
        }

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Build initial dashboard state from raw monitor data.
  """
  @spec new(metrics(), [anomaly()], status()) :: state()
  def new(metrics, anomalies, status) do
    %{
      metrics: metrics || %{},
      anomalies: anomalies || [],
      status: normalize_status(status),
      selected_skill: nil,
      history: %{}
    }
  end

  defp normalize_status(nil),
    do: %{status: :unknown, anomaly_count: 0, skills: [], metrics_available: []}

  defp normalize_status(s) when is_map(s) do
    %{
      status: Map.get(s, :status, :unknown),
      anomaly_count: Map.get(s, :anomaly_count, 0),
      skills: Map.get(s, :skills, []),
      metrics_available: Map.get(s, :metrics_available, [])
    }
  end

  # ===========================================================================
  # Reduce
  # ===========================================================================

  @doc """
  Toggle skill selection. Selecting the same skill twice deselects.
  """
  @spec select_skill(state(), atom() | nil) :: state()
  def select_skill(state, nil), do: %{state | selected_skill: nil}

  def select_skill(state, skill) do
    if state.selected_skill == skill do
      %{state | selected_skill: nil}
    else
      %{state | selected_skill: skill}
    end
  end

  @doc """
  Replace metrics, anomalies, and status while preserving history and selection.
  """
  @spec update_data(state(), metrics(), [anomaly()], status()) :: state()
  def update_data(state, metrics, anomalies, status) do
    %{
      state
      | metrics: metrics || %{},
        anomalies: anomalies || [],
        status: normalize_status(status)
    }
    |> append_history(metrics)
  end

  @doc """
  Append a sample of each skill's primary value to the history buffer.
  Bounded to `@history_limit` per skill.
  """
  @spec append_history(state(), metrics()) :: state()
  def append_history(state, metrics) when is_map(metrics) do
    new_history =
      Enum.reduce(metrics, state.history, fn {skill, data}, acc ->
        value = primary_value(skill, data)
        existing = Map.get(acc, skill, [])
        updated = [value | existing] |> Enum.take(@history_limit)
        Map.put(acc, skill, updated)
      end)

    %{state | history: new_history}
  end

  def append_history(state, _), do: state

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc """
  Format the full dashboard state for rendering.

  Returns one map with `:status_card`, `:skill_cards`, and `:anomaly_cards`
  pre-shaped so the LiveView template just iterates and renders.
  """
  @spec show_dashboard(state()) :: map()
  def show_dashboard(state) do
    %{
      status_card: show_status(state.status),
      skill_cards: show_skill_cards(state),
      anomaly_cards: Enum.map(state.anomalies, &show_anomaly/1),
      selected_skill_detail: show_selected_skill_detail(state)
    }
  end

  @doc "Format the status header card."
  @spec show_status(status()) :: map()
  def show_status(status) do
    %{
      status_code: status.status,
      status_label: format_status(status.status),
      anomaly_count: status.anomaly_count,
      skill_count: length(status.skills)
    }
  end

  @doc "Format the per-skill cards (one per skill in status.skills)."
  @spec show_skill_cards(state()) :: [map()]
  def show_skill_cards(state) do
    Enum.map(state.status.skills, fn skill ->
      data = Map.get(state.metrics, skill, %{})

      %{
        key: skill,
        icon: skill_icon(skill),
        name: format_skill_name(skill),
        summary: skill_summary(skill, data),
        primary_value: primary_value(skill, data),
        selected: state.selected_skill == skill
      }
    end)
  end

  @doc "Format a single anomaly for display."
  @spec show_anomaly(anomaly()) :: map()
  def show_anomaly(anomaly) do
    severity = Map.get(anomaly, :severity, :info)

    %{
      severity: severity,
      severity_icon: severity_icon(severity),
      metric: Map.get(anomaly, :metric, "unknown"),
      value: format_value(Map.get(anomaly, :value)),
      baseline: format_value(Map.get(anomaly, :baseline)),
      deviation: format_deviation(Map.get(anomaly, :deviation)),
      detected_at: Map.get(anomaly, :detected_at) || Map.get(anomaly, :timestamp)
    }
  end

  @doc """
  Format the selected skill's detail view (raw metrics + history).
  Returns nil when nothing is selected.
  """
  @spec show_selected_skill_detail(state()) :: map() | nil
  def show_selected_skill_detail(%{selected_skill: nil}), do: nil

  def show_selected_skill_detail(state) do
    skill = state.selected_skill
    data = Map.get(state.metrics, skill, %{})

    %{
      key: skill,
      name: format_skill_name(skill),
      data: data,
      flat_metrics: flatten_metrics(data),
      history: Map.get(state.history, skill, []) |> Enum.take(10) |> Enum.map(&format_value/1)
    }
  end

  # ===========================================================================
  # Pure Helpers (visible for testing and reuse)
  # ===========================================================================

  @doc "Extract the canonical 'primary' metric value for a skill."
  @spec primary_value(atom(), map() | nil) :: term()
  def primary_value(:memory, data), do: data[:total_mb]
  def primary_value(:processes, data), do: data[:count]
  def primary_value(:ets, data), do: data[:table_count]
  def primary_value(:scheduler, data), do: data[:total_utilization]
  def primary_value(:gc, data), do: data[:total_collections]
  def primary_value(_skill, data) when is_map(data), do: map_size(data)
  def primary_value(_skill, _data), do: nil

  @doc "Display label for a status atom."
  @spec format_status(atom()) :: String.t()
  def format_status(:healthy), do: "Healthy"
  def format_status(:warning), do: "Warning"
  def format_status(:critical), do: "Critical"
  def format_status(:emergency), do: "Emergency"
  def format_status(_), do: "Unknown"

  @doc "Emoji icon for a skill."
  @spec skill_icon(atom()) :: String.t()
  def skill_icon(:beam), do: "🔮"
  def skill_icon(:memory), do: "💾"
  def skill_icon(:ets), do: "📊"
  def skill_icon(:processes), do: "⚙️"
  def skill_icon(:supervisor), do: "👁️"
  def skill_icon(:system), do: "🖥️"
  def skill_icon(:gc), do: "🗑️"
  def skill_icon(:allocator), do: "📦"
  def skill_icon(:ports), do: "🔌"
  def skill_icon(:scheduler), do: "📅"
  def skill_icon(_), do: "📈"

  @doc "Title-case display name for a skill atom."
  @spec format_skill_name(atom() | String.t()) :: String.t()
  def format_skill_name(skill) when is_atom(skill) do
    skill
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def format_skill_name(skill), do: to_string(skill)

  @doc "One-line summary string for a skill card."
  @spec skill_summary(atom(), map() | nil) :: String.t()
  def skill_summary(:memory, data), do: "#{data[:total_mb] || "?"}MB used"
  def skill_summary(:processes, data), do: "#{data[:count] || "?"} procs"
  def skill_summary(:ets, data), do: "#{data[:table_count] || "?"} tables"
  def skill_summary(:scheduler, data), do: "#{data[:total_utilization] || "?"}% util"
  def skill_summary(:gc, data), do: "#{data[:total_collections] || "?"} GCs"
  def skill_summary(:ports, data), do: "#{data[:count] || "?"} ports"
  def skill_summary(:system, data), do: "OTP #{data[:otp_release] || "?"}"
  def skill_summary(:beam, data), do: "v#{data[:version] || "?"}"

  def skill_summary(_skill, data) when is_map(data) and map_size(data) > 0 do
    "#{map_size(data)} metrics"
  end

  def skill_summary(_skill, _data), do: "no data"

  @doc "Severity icon for an anomaly."
  @spec severity_icon(atom()) :: String.t()
  def severity_icon(:critical), do: "🔴"
  def severity_icon(:warning), do: "⚠️"
  def severity_icon(:info), do: "ℹ️"
  def severity_icon(_), do: "•"

  @doc "Format a numeric value for display, handling nil/floats/integers."
  @spec format_value(term()) :: String.t()
  def format_value(nil), do: "—"
  def format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  def format_value(v) when is_integer(v), do: Integer.to_string(v)
  def format_value(v), do: inspect(v)

  defp format_deviation(nil), do: nil

  defp format_deviation(d) when is_number(d) do
    "#{Float.round(d * 1.0, 1)} stddev"
  end

  defp format_deviation(_), do: nil

  @doc "Flatten a nested metrics map into [{key_path, value}] tuples."
  @spec flatten_metrics(map()) :: [{String.t(), term()}]
  def flatten_metrics(map) when is_map(map) do
    map
    |> Enum.flat_map(&do_flatten_metric/1)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  def flatten_metrics(_), do: []

  defp do_flatten_metric({key, value}) when is_map(value) do
    base = to_string(key)

    value
    |> Enum.flat_map(&do_flatten_metric/1)
    |> Enum.map(fn {k, v} -> {"#{base}.#{k}", v} end)
  end

  defp do_flatten_metric({key, value}), do: [{to_string(key), value}]
end
