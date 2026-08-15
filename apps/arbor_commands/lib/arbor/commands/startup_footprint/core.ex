defmodule Arbor.Commands.StartupFootprint.Core do
  @moduledoc """
  Pure K3B startup-footprint admit, normalize, and budget comparison.

  Runtime samples are compared against numeric ceilings, not byte identity.
  """

  alias Arbor.Commands.StartupFootprint.Encode

  @policy_schema "arbor.packaging.startup_footprint.policy.v1"
  @evidence_schema "arbor.packaging.startup_footprint.evidence.v1"
  @report_schema "arbor.packaging.startup_footprint.report.v1"
  @policy_version "k3b.v1"
  @scenarios ["baseline", "proposed_gated", "proposed_eager"]
  @delta_metrics [
    "process_count",
    "ets_table_count",
    "ets_memory_words",
    "beam_memory_bytes"
  ]
  @non_monotonic_gauges ["ets_memory_words", "beam_memory_bytes"]
  @compared_metrics [
    "process_count_delta",
    "supervisor_children",
    "ets_table_count_delta",
    "ets_memory_words_delta",
    "beam_memory_bytes_delta",
    "boot_time_us",
    "logger_filter_count",
    "telemetry_handler_count"
  ]
  @max_failures 50
  @max_raw_errors 20
  @decision_pairs [
    {"candidate", "measure_only"},
    {"accepted", "eager_startup"},
    {"accepted", "nested_child_gates"},
    {"accepted", "split_passive_protocols"}
  ]

  @spec policy_schema() :: String.t()
  def policy_schema, do: @policy_schema

  @spec evidence_schema() :: String.t()
  def evidence_schema, do: @evidence_schema

  @spec report_schema() :: String.t()
  def report_schema, do: @report_schema

  @spec policy_version() :: String.t()
  def policy_version, do: @policy_version

  @spec scenarios() :: [String.t()]
  def scenarios, do: @scenarios

  @spec compared_metrics() :: [String.t()]
  def compared_metrics, do: @compared_metrics

  @spec admit_policy(map()) :: {:ok, map()} | {:error, term()}
  def admit_policy(raw) when is_map(raw) do
    with :ok <- exact_schema(raw, @policy_schema, :malformed_policy),
         :ok <- exact_version(raw, :malformed_policy),
         :ok <- exact_policy_version(raw, :malformed_policy),
         {:ok, decision} <- admit_decision(raw["decision"]),
         :ok <- exact_scenarios(raw["scenarios"], :malformed_policy),
         {:ok, budgets} <- admit_budgets(raw["budgets"]) do
      {:ok,
       %{
         "schema" => @policy_schema,
         "version" => 1,
         "policy_version" => @policy_version,
         "decision" => Encode.order_decision(decision),
         "scenarios" => @scenarios,
         "budgets" => budgets
       }}
    end
  end

  def admit_policy(_), do: {:error, :malformed_policy}

  @spec admit_evidence(map()) :: {:ok, map()} | {:error, term()}
  def admit_evidence(raw) when is_map(raw) do
    with :ok <- exact_schema(raw, @evidence_schema, :malformed_evidence),
         :ok <- exact_version(raw, :malformed_evidence),
         :ok <- exact_policy_version(raw, :malformed_evidence),
         {:ok, samples} <- admit_samples(raw["samples"]) do
      {:ok,
       %{
         "schema" => @evidence_schema,
         "version" => 1,
         "policy_version" => @policy_version,
         "samples" => samples
       }}
    end
  end

  def admit_evidence(_), do: {:error, :malformed_evidence}

  @spec admit_raw_sample(map()) :: {:ok, map()} | {:error, term()}
  def admit_raw_sample(raw) when is_map(raw) do
    scenario = raw["scenario"]

    cond do
      scenario not in @scenarios ->
        {:error, {:invalid_scenario, scenario}}

      not pos_int?(raw["os_pid"]) ->
        {:error, {:invalid_os_pid, scenario}}

      not non_neg_int?(raw["boot_time_us"]) ->
        {:error, {:invalid_boot_time, scenario}}

      not non_neg_int?(raw["supervisor_children"]) ->
        {:error, {:invalid_supervisor_children, scenario}}

      not non_neg_int?(raw["logger_filter_count"]) ->
        {:error, {:invalid_logger_filter_count, scenario}}

      not non_neg_int?(raw["telemetry_handler_count"]) ->
        {:error, {:invalid_telemetry_handler_count, scenario}}

      true ->
        with {:ok, before} <- admit_snapshot(raw["before"], scenario, "before"),
             {:ok, after_snap} <- admit_snapshot(raw["after"], scenario, "after"),
             {:ok, started} <- admit_started_owner_apps(raw["started_owner_apps"], scenario),
             {:ok, runtime} <- admit_started_runtime_apps(raw["started_runtime_apps"], scenario) do
          {:ok,
           %{
             "scenario" => scenario,
             "os_pid" => raw["os_pid"],
             "before" => before,
             "after" => after_snap,
             "boot_time_us" => raw["boot_time_us"],
             "supervisor_children" => raw["supervisor_children"],
             "logger_filter_count" => raw["logger_filter_count"],
             "telemetry_handler_count" => raw["telemetry_handler_count"],
             "started_owner_apps" => started,
             "started_runtime_apps" => runtime
           }}
        end
    end
  end

  def admit_raw_sample(_), do: {:error, :malformed_sample}

  @spec normalize_sample(map()) :: {:ok, map()} | {:error, term()}
  def normalize_sample(raw) when is_map(raw) do
    with {:ok, admitted} <- admit_raw_sample(raw) do
      {deltas, errors} = normalize_deltas(admitted["before"], admitted["after"])

      sample =
        Encode.order_sample(%{
          "scenario" => admitted["scenario"],
          "os_pid" => admitted["os_pid"],
          "process_count_delta" => deltas["process_count_delta"],
          "supervisor_children" => admitted["supervisor_children"],
          "ets_table_count_delta" => deltas["ets_table_count_delta"],
          "ets_memory_words_delta" => deltas["ets_memory_words_delta"],
          "beam_memory_bytes_delta" => deltas["beam_memory_bytes_delta"],
          "boot_time_us" => admitted["boot_time_us"],
          "logger_filter_count" => admitted["logger_filter_count"],
          "telemetry_handler_count" => admitted["telemetry_handler_count"],
          "started_owner_apps" => admitted["started_owner_apps"],
          "started_runtime_apps" => admitted["started_runtime_apps"],
          "raw_errors" => Enum.take(errors, @max_raw_errors)
        })

      {:ok, sample}
    end
  end

  def normalize_sample(_), do: {:error, :malformed_sample}

  @spec admit_normalized_sample(map()) :: {:ok, map()} | {:error, term()}
  def admit_normalized_sample(raw) when is_map(raw) do
    scenario = raw["scenario"]

    cond do
      scenario not in @scenarios ->
        {:error, {:invalid_scenario, scenario}}

      not pos_int?(raw["os_pid"]) ->
        {:error, {:invalid_os_pid, scenario}}

      missing_compared?(raw) ->
        {:error, {:missing_metric, scenario}}

      not Enum.all?(@compared_metrics, &non_neg_int?(raw[&1])) ->
        {:error, {:invalid_metric, scenario}}

      not Map.has_key?(raw, "raw_errors") or not valid_raw_errors?(raw["raw_errors"]) ->
        {:error, {:invalid_raw_errors, scenario}}

      true ->
        with {:ok, started} <- admit_started_owner_apps(raw["started_owner_apps"], scenario),
             {:ok, runtime} <- admit_started_runtime_apps(raw["started_runtime_apps"], scenario) do
          {:ok,
           Encode.order_sample(
             raw
             |> Map.put("started_owner_apps", started)
             |> Map.put("started_runtime_apps", runtime)
             |> Map.put("raw_errors", raw["raw_errors"])
           )}
        end
    end
  end

  def admit_normalized_sample(_), do: {:error, :malformed_sample}

  @spec compare(map(), map()) :: {:ok, map()} | {:error, term()}
  def compare(policy, evidence) when is_map(policy) and is_map(evidence) do
    with {:ok, admitted_policy} <- admit_policy(policy),
         {:ok, admitted_evidence} <- admit_evidence(evidence) do
      samples = admitted_evidence["samples"]

      failures =
        []
        |> isolation_failures(samples)
        |> raw_error_failures(samples)
        |> baseline_zero_owner_callbacks(samples)
        |> runtime_union_failures(samples)
        |> budget_failures(admitted_policy["budgets"], samples)

      finish_failures(failures)
    end
  end

  def compare(_, _), do: {:error, :invalid_compare}

  @spec show(map(), map(), map()) :: map()
  def show(policy, evidence, extras) when is_map(policy) and is_map(evidence) do
    extras = extras || %{}
    compare = extras["comparison"] || %{"status" => "ok", "failures" => [], "failure_count" => 0}
    mode = extras["mode"] || "report"
    status = if compare["status"] == "failed", do: "failed", else: "ok"

    %{
      "schema" => @report_schema,
      "version" => 1,
      "mode" => mode,
      "status" => status,
      "output" => extras["output"] || "human",
      "policy_version" => @policy_version,
      "decision" => Encode.order_decision(policy["decision"] || %{}),
      "samples" => evidence["samples"] || %{},
      "comparison" => compare,
      "errors" => extras["errors"] || []
    }
  end

  def show(_, _, _), do: %{"schema" => @report_schema, "status" => "failed"}

  defp admit_decision(decision) when is_map(decision) do
    status = decision["status"]
    choice = decision["choice"]
    rationale = decision["rationale"]
    reversible = decision["reversible"]

    cond do
      {status, choice} not in @decision_pairs ->
        {:error, :malformed_decision}

      not is_binary(rationale) or String.trim(rationale) == "" ->
        {:error, :malformed_decision}

      reversible != true ->
        {:error, :decision_must_be_reversible}

      true ->
        {:ok,
         %{
           "status" => status,
           "choice" => choice,
           "rationale" => rationale,
           "reversible" => true
         }}
    end
  end

  defp admit_decision(_), do: {:error, :malformed_decision}

  defp admit_budgets(budgets) when is_map(budgets) do
    Enum.reduce_while(@scenarios, {:ok, %{}}, fn scenario, {:ok, acc} ->
      case admit_budget(Map.get(budgets, scenario), scenario) do
        {:ok, budget} -> {:cont, {:ok, Map.put(acc, scenario, budget)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp admit_budgets(_), do: {:error, :malformed_budgets}

  defp admit_budget(budget, scenario) when is_map(budget) do
    Enum.reduce_while(@compared_metrics, {:ok, %{}}, fn metric, {:ok, acc} ->
      case admit_bound(Map.get(budget, metric), scenario, metric) do
        {:ok, bound} -> {:cont, {:ok, Map.put(acc, metric, bound)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp admit_budget(_, scenario), do: {:error, {:missing_budget, scenario}}

  defp admit_bound(bound, _scenario, _metric) when is_map(bound) do
    min = Map.get(bound, "min", 0)
    max = Map.get(bound, "max")

    cond do
      not non_neg_int?(min) ->
        {:error, :malformed_budget_bound}

      not non_neg_int?(max) ->
        {:error, :malformed_budget_bound}

      min > max ->
        {:error, :malformed_budget_bound}

      true ->
        {:ok, %{"min" => min, "max" => max}}
    end
  end

  defp admit_bound(_, scenario, metric), do: {:error, {:missing_budget_metric, scenario, metric}}

  defp admit_samples(samples) when is_map(samples) do
    Enum.reduce_while(@scenarios, {:ok, %{}}, fn scenario, {:ok, acc} ->
      case admit_normalized_sample(Map.get(samples, scenario)) do
        {:ok, sample} ->
          if sample["scenario"] == scenario do
            {:cont, {:ok, Map.put(acc, scenario, sample)}}
          else
            {:halt, {:error, {:scenario_mismatch, scenario, sample["scenario"]}}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp admit_samples(_), do: {:error, :malformed_evidence}

  defp admit_snapshot(snap, scenario, label) when is_map(snap) do
    missing =
      Enum.reject(@delta_metrics, fn key ->
        Map.has_key?(snap, key) and is_integer(snap[key])
      end)

    if missing == [] do
      {:ok, Map.take(snap, @delta_metrics)}
    else
      {:error, {:invalid_snapshot, scenario, label, missing}}
    end
  end

  defp admit_snapshot(_, scenario, label), do: {:error, {:invalid_snapshot, scenario, label, []}}

  @owner_app_names ["arbor_kernel_runtime"]

  defp admit_started_owner_apps(list, scenario) when is_list(list) do
    if Enum.all?(list, &(&1 in @owner_app_names)) and length(list) == length(Enum.uniq(list)) do
      {:ok, Enum.sort(list)}
    else
      {:error, {:invalid_started_owner_apps, scenario}}
    end
  end

  defp admit_started_owner_apps(_, scenario),
    do: {:error, {:invalid_started_owner_apps, scenario}}

  defp admit_started_runtime_apps(list, scenario) when is_list(list) do
    if Enum.all?(list, &is_binary/1) and length(list) == length(Enum.uniq(list)) do
      {:ok, Enum.sort(list)}
    else
      {:error, {:invalid_started_runtime_apps, scenario}}
    end
  end

  defp admit_started_runtime_apps(_, scenario) do
    {:error, {:invalid_started_runtime_apps, scenario}}
  end

  defp normalize_deltas(before, after_snap) do
    Enum.reduce(@delta_metrics, {%{}, []}, fn metric, {deltas, errors} ->
      raw = after_snap[metric] - before[metric]
      key = metric <> "_delta"

      cond do
        raw >= 0 ->
          {Map.put(deltas, key, raw), errors}

        metric in @non_monotonic_gauges ->
          {Map.put(deltas, key, 0), errors}

        true ->
          {Map.put(deltas, key, 0),
           [
             %{"reason" => "negative_delta", "metric" => metric, "raw" => raw}
             | errors
           ]}
      end
    end)
    |> then(fn {deltas, errors} -> {deltas, Enum.reverse(errors)} end)
  end

  defp raw_error_failures(failures, samples) do
    Enum.reduce(@scenarios, failures, fn scenario, acc ->
      case samples[scenario]["raw_errors"] do
        [] ->
          acc

        errors when is_list(errors) ->
          [
            %{
              "reason" => "raw_errors_present",
              "detail" => "#{scenario} has #{length(errors)} raw_errors"
            }
            | acc
          ]

        _other ->
          [
            %{
              "reason" => "raw_errors_present",
              "detail" => "#{scenario} has invalid raw_errors"
            }
            | acc
          ]
      end
    end)
  end

  defp isolation_failures(failures, samples) do
    pids = Enum.map(@scenarios, &samples[&1]["os_pid"])

    cond do
      Enum.any?(pids, &(&1 == 0)) ->
        [
          %{"reason" => "missing_os_pid", "detail" => "os_pid must be a positive child pid"}
          | failures
        ]

      length(Enum.uniq(pids)) != length(pids) ->
        [
          %{
            "reason" => "shared_os_pid",
            "detail" => "scenarios must run in distinct OS processes"
          }
          | failures
        ]

      true ->
        failures
    end
  end

  defp baseline_zero_owner_callbacks(failures, samples) do
    baseline = samples["baseline"] || %{}
    started = baseline["started_owner_apps"] || []

    failures
    |> maybe_owner_app_failure(started)
    |> maybe_callback_failure(baseline, "logger_filter_count")
    |> maybe_callback_failure(baseline, "telemetry_handler_count")
  end

  defp maybe_owner_app_failure(failures, []), do: failures

  defp maybe_owner_app_failure(failures, started) do
    [
      %{
        "reason" => "baseline_owner_apps_started",
        "detail" => Enum.join(started, ",")
      }
      | failures
    ]
  end

  defp runtime_union_failures(failures, samples) do
    baseline_runtime = samples["baseline"]["started_runtime_apps"] || []

    failures =
      if "os_mon" in baseline_runtime do
        [
          %{
            "reason" => "baseline_widened_runtime",
            "detail" => "baseline.started_runtime_apps includes os_mon"
          }
          | failures
        ]
      else
        failures
      end

    Enum.reduce(["proposed_gated", "proposed_eager"], failures, fn scenario, acc ->
      runtime = samples[scenario]["started_runtime_apps"] || []

      if "os_mon" in runtime do
        acc
      else
        [
          %{
            "reason" => "proposed_missing_runtime",
            "detail" => "#{scenario}.started_runtime_apps missing os_mon"
          }
          | acc
        ]
      end
    end)
  end

  defp maybe_callback_failure(failures, sample, metric) do
    case sample[metric] do
      0 ->
        failures

      value ->
        [
          %{
            "reason" => "baseline_owner_callback",
            "detail" => "baseline.#{metric}=#{value}"
          }
          | failures
        ]
    end
  end

  defp budget_failures(failures, budgets, samples) do
    Enum.reduce(@scenarios, failures, fn scenario, acc ->
      sample = samples[scenario]
      budget = budgets[scenario]

      Enum.reduce(@compared_metrics, acc, fn metric, inner ->
        value = sample[metric]
        min = budget[metric]["min"]
        max = budget[metric]["max"]

        cond do
          value < min ->
            [
              %{
                "reason" => "below_budget",
                "detail" => "#{scenario}.#{metric}=#{value} min=#{min}"
              }
              | inner
            ]

          value > max ->
            [
              %{
                "reason" => "above_budget",
                "detail" => "#{scenario}.#{metric}=#{value} max=#{max}"
              }
              | inner
            ]

          true ->
            inner
        end
      end)
    end)
  end

  defp finish_failures(failures) do
    sorted = Enum.sort_by(failures, &{&1["reason"], &1["detail"]})
    bounded = Enum.take(sorted, @max_failures)
    count = length(failures)
    status = if count == 0, do: "ok", else: "failed"

    {:ok,
     %{
       "status" => status,
       "failures" => bounded,
       "failure_count" => count,
       "truncated" => count > @max_failures
     }}
  end

  defp exact_schema(%{"schema" => schema}, schema, _error), do: :ok
  defp exact_schema(_, _, error), do: {:error, error}

  defp exact_version(%{"version" => 1}, _error), do: :ok
  defp exact_version(_, error), do: {:error, error}

  defp exact_policy_version(%{"policy_version" => @policy_version}, _error), do: :ok
  defp exact_policy_version(_, error), do: {:error, error}

  defp exact_scenarios(scenarios, _error) when scenarios == @scenarios, do: :ok
  defp exact_scenarios(_, error), do: {:error, error}

  defp missing_compared?(sample) do
    Enum.any?(@compared_metrics, &(not Map.has_key?(sample, &1)))
  end

  defp valid_raw_errors?(errors) when is_list(errors) do
    length(errors) <= @max_raw_errors and
      Enum.all?(errors, fn
        %{"reason" => reason, "metric" => metric, "raw" => raw}
        when is_binary(reason) and is_binary(metric) and is_integer(raw) ->
          true

        _ ->
          false
      end)
  end

  defp valid_raw_errors?(_), do: false

  defp non_neg_int?(n) when is_integer(n) and n >= 0, do: true
  defp non_neg_int?(_), do: false

  defp pos_int?(n) when is_integer(n) and n > 0, do: true
  defp pos_int?(_), do: false
end
