defmodule Mix.Tasks.Arbor.Readiness do
  use Boundary, classify_to: Arbor.KernelRuntime.DevTools

  @moduledoc """
  Pure readiness helpers for Arbor lifecycle mix tasks.

  Node reachability (`:net_adm.ping`) and umbrella application readiness are
  distinct states. A reachable node may still be mid-boot while applications
  start sequentially; treating ping alone as success is a false positive.

  These helpers are pure decision seams so tests can cover expected-set
  derivation, observation classification, and absolute-deadline polling without
  starting a live Arbor server.
  """

  @type app_name :: atom()
  @type which_applications :: [{app_name(), charlist() | String.t(), charlist() | String.t()}]
  @type observation ::
          {:ok, which_applications()}
          | {:error, term()}

  @type readiness_result ::
          :ready
          | {:partial, missing :: [app_name()], present :: [app_name()]}
          | {:stalled_start, app_name(), missing :: [app_name()], present :: [app_name()]}
          | {:observation_unavailable, reason :: term()}

  @type poll_decision ::
          :done_ready
          | {:done_timeout, readiness_result() | :unreachable | :no_observation}
          | {:done_failed, readiness_result()}
          | {:continue, remaining_ms :: non_neg_integer()}

  @doc """
  Derives the expected umbrella application atoms from `Mix.Project.apps_paths/0`.

  Accepts the apps_paths map (or `nil` for a non-umbrella project) so callers and
  tests inject the Mix project view without hard-coding app lists.
  """
  @spec expected_umbrella_apps(map() | nil) :: [app_name()]
  def expected_umbrella_apps(nil), do: []

  def expected_umbrella_apps(apps_paths) when is_map(apps_paths) do
    apps_paths
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Extracts started application names from `:application.which_applications/0` shape.
  """
  @spec started_application_names(which_applications() | term()) :: MapSet.t(app_name())
  def started_application_names(which_applications) when is_list(which_applications) do
    which_applications
    |> Enum.flat_map(fn
      {name, _desc, _vsn} when is_atom(name) -> [name]
      _other -> []
    end)
    |> MapSet.new()
  end

  def started_application_names(_), do: MapSet.new()

  @doc """
  Classifies a remote application observation against the expected umbrella set.

  - `:ready` — every expected app is present in the observation
  - `{:partial, missing, present}` — observation succeeded but apps are incomplete
  - `{:observation_unavailable, reason}` — RPC failed or returned unusable data

  An empty expected set with a successful observation is treated as `:ready`
  (non-umbrella projects have no umbrella apps to wait for).
  """
  @spec classify_observation([app_name()], observation()) :: readiness_result()
  def classify_observation(expected, {:ok, which_applications})
      when is_list(expected) and is_list(which_applications) do
    started = started_application_names(which_applications)
    present = Enum.filter(expected, &MapSet.member?(started, &1))
    missing = Enum.reject(expected, &MapSet.member?(started, &1))

    if missing == [] do
      :ready
    else
      {:partial, missing, present}
    end
  end

  def classify_observation(_expected, {:ok, _invalid}) do
    {:observation_unavailable, :invalid_which_applications}
  end

  def classify_observation(_expected, {:error, reason}) do
    {:observation_unavailable, reason}
  end

  @doc """
  Application names the remote application controller still lists as
  `starting`, from the `:application.info/0` shape.
  """
  @spec starting_application_names(term()) :: [app_name()]
  def starting_application_names(info) when is_list(info) do
    case List.keyfind(info, :starting, 0) do
      {:starting, entries} when is_list(entries) ->
        for entry <- entries,
            is_tuple(entry) and tuple_size(entry) > 0 and is_atom(elem(entry, 0)),
            do: elem(entry, 0)

      _other ->
        []
    end
  end

  def starting_application_names(_info), do: []

  @doc """
  Detects a start that can never finish.

  On OTP 28 an application master that exits before its `start/2` callback
  returns never casts `application_started`; the application controller drops
  the master's exit and keeps the application in `starting` forever, so the
  node stays up with a partial application set. `dead_starts` are the
  `starting` applications that had no live master in one observation. An
  application dead in two consecutive observations is reported, which skips
  the instant between the controller admitting a start and the master
  registering itself.
  """
  @spec stalled_start([app_name()], [app_name()]) :: app_name() | nil
  def stalled_start(previous_dead_starts, dead_starts)
      when is_list(previous_dead_starts) and is_list(dead_starts) do
    Enum.find(dead_starts, &(&1 in previous_dead_starts))
  end

  @failure_excerpt_max_lines 25
  @failure_excerpt_max_line_bytes 600

  @doc """
  Pulls the first boot failure out of a daemon log for start diagnostics.

  Prefers Mix's `Could not start application` line (the daemon halts after
  it); otherwise the first `[error]` entry with its continuation lines, which
  is where a crash report lands when a start stalls instead of failing.
  Bounded to #{@failure_excerpt_max_lines} lines.
  """
  @spec failure_excerpt(String.t()) :: {:ok, String.t()} | :none
  def failure_excerpt(log_contents) when is_binary(log_contents) do
    lines = String.split(log_contents, ["\r\n", "\n"])

    case Enum.find_index(lines, &String.contains?(&1, "Could not start application")) do
      nil ->
        case Enum.find_index(lines, &String.contains?(&1, "[error]")) do
          nil -> :none
          index -> {:ok, excerpt_from(lines, index, &(String.trim(&1) != ""))}
        end

      # Mix's line is followed by unrelated shutdown chatter; keep only its
      # own indented continuation lines.
      index ->
        {:ok, excerpt_from(lines, index, &String.match?(&1, ~r/^\s+\S/))}
    end
  end

  def failure_excerpt(_log_contents), do: :none

  defp excerpt_from(lines, index, continuation?) do
    [first | rest] = Enum.drop(lines, index)

    [first | Enum.take_while(rest, continuation?)]
    |> Enum.take(@failure_excerpt_max_lines)
    |> Enum.map_join("\n", &truncate_line/1)
  end

  defp truncate_line(line) when byte_size(line) <= @failure_excerpt_max_line_bytes, do: line

  defp truncate_line(line) do
    String.slice(line, 0, @failure_excerpt_max_line_bytes) <> " ..."
  end

  @doc """
  Remaining milliseconds until an absolute monotonic deadline (never negative).
  """
  @spec remaining_ms(integer(), integer()) :: non_neg_integer()
  def remaining_ms(deadline_mono_ms, now_mono_ms)
      when is_integer(deadline_mono_ms) and is_integer(now_mono_ms) do
    max(deadline_mono_ms - now_mono_ms, 0)
  end

  @doc """
  Bounds a single RPC timeout by the remaining phase budget and a per-call ceiling.

  Returns `0` when the phase budget is exhausted so callers can skip the RPC.
  """
  @spec rpc_timeout_ms(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def rpc_timeout_ms(remaining_ms, max_rpc_ms)
      when is_integer(remaining_ms) and remaining_ms >= 0 and is_integer(max_rpc_ms) and
             max_rpc_ms > 0 do
    min(remaining_ms, max_rpc_ms)
  end

  @doc """
  Decides whether a readiness poll loop should succeed, fail, time out, or continue.

  `last_result` is the most recent classification (or `:unreachable` / `:no_observation`
  before any successful observation). Absolute deadlines are caller-owned; this
  helper interprets remaining time vs the last known state. A node lost during
  application startup fails immediately; an RPC timeout still uses the phase budget.
  """
  @spec poll_decision(integer(), integer(), readiness_result() | :unreachable | :no_observation) ::
          poll_decision()
  def poll_decision(deadline_mono_ms, now_mono_ms, last_result)
      when is_integer(deadline_mono_ms) and is_integer(now_mono_ms) do
    remaining = remaining_ms(deadline_mono_ms, now_mono_ms)

    cond do
      last_result == :ready ->
        :done_ready

      match?({:observation_unavailable, {:badrpc, :nodedown}}, last_result) ->
        {:done_failed, last_result}

      match?({:stalled_start, _app, _missing, _present}, last_result) ->
        {:done_failed, last_result}

      remaining <= 0 ->
        {:done_timeout, last_result}

      true ->
        {:continue, remaining}
    end
  end

  @doc """
  Sleep duration for the next poll, never exceeding the remaining budget.
  """
  @spec sleep_ms(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def sleep_ms(remaining_ms, poll_interval_ms)
      when is_integer(remaining_ms) and remaining_ms >= 0 and is_integer(poll_interval_ms) and
             poll_interval_ms > 0 do
    min(remaining_ms, poll_interval_ms)
  end

  @doc """
  Human-readable timeout diagnostic for `mix arbor.start` failure paths.
  """
  @spec timeout_diagnostic(
          :node_unreachable
          | readiness_result()
          | :unreachable
          | :no_observation,
          [app_name()],
          pos_integer()
        ) :: String.t()
  def timeout_diagnostic(:node_unreachable, _expected, node_timeout_ms) do
    seconds = div(node_timeout_ms, 1000)

    """
    Arbor server node did not become reachable within #{seconds} seconds \
    (distribution ping).
    """
    |> String.trim()
  end

  def timeout_diagnostic(:unreachable, expected, app_timeout_ms) do
    timeout_diagnostic({:observation_unavailable, :node_unreachable}, expected, app_timeout_ms)
  end

  def timeout_diagnostic(:no_observation, expected, app_timeout_ms) do
    timeout_diagnostic({:observation_unavailable, :no_observation}, expected, app_timeout_ms)
  end

  def timeout_diagnostic(:ready, _expected, _app_timeout_ms) do
    "Arbor applications are ready."
  end

  def timeout_diagnostic({:partial, missing, present}, expected, app_timeout_ms) do
    seconds = div(app_timeout_ms, 1000)

    """
    Arbor node is reachable, but applications did not all start within #{seconds} seconds.
      Expected apps: #{length(expected)}
      Started:       #{length(present)}/#{length(expected)}
      Missing:       #{format_app_list(missing)}
    """
    |> String.trim()
  end

  def timeout_diagnostic({:stalled_start, app, missing, present}, expected, _app_timeout_ms) do
    """
    Arbor application #{app} is stuck starting and will never finish: its OTP
    application master exited before #{app}'s start/2 returned, so the
    application controller waits forever (the node stays up, half-booted).
      Started:       #{length(present)}/#{length(expected)}
      Missing:       #{format_app_list(missing)}
    The exit reason is the first crash report in the daemon log (excerpt below).
    """
    |> String.trim()
  end

  def timeout_diagnostic(
        {:observation_unavailable, {:badrpc, :nodedown}},
        expected,
        _app_timeout_ms
      ) do
    """
    Arbor node became unreachable during application startup (RPC reported :nodedown).
      Expected apps: #{format_app_list(expected)}
      OS process state is not inferred from this RPC result.
    """
    |> String.trim()
  end

  def timeout_diagnostic({:observation_unavailable, reason}, expected, app_timeout_ms) do
    seconds = div(app_timeout_ms, 1000)

    """
    Arbor node is reachable, but application readiness could not be observed \
    within #{seconds} seconds (RPC observation unavailable: #{inspect(reason)}).
      Expected apps: #{format_app_list(expected)}
    """
    |> String.trim()
  end

  @doc false
  @spec format_app_list([app_name()]) :: String.t()
  def format_app_list([]), do: "(none)"
  def format_app_list(apps), do: Enum.map_join(apps, ", ", &to_string/1)

  @doc """
  Status label for a reachable node given a readiness classification.

  Distinguishes fully ready from partially started / unobservable so
  `mix arbor.status` does not label a mid-boot node as fully running.
  """
  @spec status_label(readiness_result()) :: String.t()
  def status_label(:ready), do: "running (applications ready)"

  def status_label({:stalled_start, app, _missing, _present}) do
    "reachable (stuck: #{app} can never finish starting)"
  end

  def status_label({:partial, missing, _present}) do
    "reachable (applications starting; missing: #{format_app_list(missing)})"
  end

  def status_label({:observation_unavailable, reason}) do
    "reachable (application observation unavailable: #{inspect(reason)})"
  end

  @doc """
  Formats the `Missing:` field for `mix arbor.status`.

  - `:ready` → `"none"` (every expected app is present)
  - `{:partial, missing, _}` → comma-separated missing app names, or `"none"` if empty
  - `{:observation_unavailable, _}` → `"unknown"` (observation failed; do not imply
    that no applications are missing)

  Pure decision seam so unavailable readiness cannot be mislabeled as an empty
  missing set.
  """
  @spec status_missing_label(readiness_result()) :: String.t()
  def status_missing_label(:ready), do: "none"

  def status_missing_label({:stalled_start, _app, missing, present}),
    do: status_missing_label({:partial, missing, present})

  def status_missing_label({:partial, missing, _present}) when is_list(missing) do
    case missing do
      [] -> "none"
      apps -> Enum.map_join(apps, ", ", &to_string/1)
    end
  end

  def status_missing_label({:observation_unavailable, _reason}), do: "unknown"
end
