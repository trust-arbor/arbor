defmodule Arbor.Commands.StartupFootprint.Encode do
  @moduledoc """
  Canonical JSON for the K3B startup-footprint policy and report.

  Sample values are compared by numeric budgets, not byte identity.
  """

  @report_key_order [
    "schema",
    "version",
    "mode",
    "status",
    "output",
    "policy_version",
    "decision",
    "samples",
    "comparison",
    "errors"
  ]

  @decision_key_order ["status", "choice", "rationale", "reversible"]

  @sample_key_order [
    "scenario",
    "os_pid",
    "process_count_delta",
    "supervisor_children",
    "ets_table_count_delta",
    "ets_memory_words_delta",
    "beam_memory_bytes_delta",
    "boot_time_us",
    "logger_filter_count",
    "telemetry_handler_count",
    "started_owner_apps",
    "started_runtime_apps",
    "raw_errors"
  ]

  @comparison_key_order ["status", "failures", "failure_count", "truncated"]
  @failure_key_order ["reason", "detail"]
  @raw_error_key_order ["reason", "metric", "raw"]

  @spec report_key_order() :: [String.t()]
  def report_key_order, do: @report_key_order

  @spec sample_key_order() :: [String.t()]
  def sample_key_order, do: @sample_key_order

  @spec encode_report(map()) :: {:ok, binary()} | {:error, term()}
  def encode_report(report) when is_map(report) do
    encode_ordered(normative_report(report), @report_key_order)
  end

  def encode_report(_), do: {:error, :invalid_report}

  @spec normative_report(map()) :: map()
  def normative_report(report) when is_map(report) do
    Map.take(report, @report_key_order)
  end

  def normative_report(_), do: %{}

  @spec order_sample(map()) :: map()
  def order_sample(sample) when is_map(sample) do
    take_present(sample, @sample_key_order)
  end

  def order_sample(_), do: %{}

  @spec order_decision(map()) :: map()
  def order_decision(decision) when is_map(decision) do
    take_present(decision, @decision_key_order)
  end

  def order_decision(_), do: %{}

  defp encode_ordered(map, key_order) do
    ordered =
      Jason.OrderedObject.new(
        Enum.map(key_order, fn key ->
          {key, canonicalize(Map.get(map, key))}
        end)
      )

    {:ok, Jason.encode!(ordered)}
  rescue
    _ -> {:error, :encode_failed}
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    order = key_order_for(map)

    order
    |> Enum.filter(&Map.has_key?(map, &1))
    |> Enum.map(fn key -> {key, canonicalize(Map.get(map, key))} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(%Jason.OrderedObject{} = object), do: object
  defp canonicalize(other), do: other

  defp key_order_for(map) do
    cond do
      Map.has_key?(map, "process_count_delta") and Map.has_key?(map, "scenario") ->
        @sample_key_order

      Map.has_key?(map, "failure_count") and Map.has_key?(map, "failures") ->
        @comparison_key_order

      Map.has_key?(map, "reason") and Map.has_key?(map, "detail") ->
        @failure_key_order

      Map.has_key?(map, "reason") and Map.has_key?(map, "metric") ->
        @raw_error_key_order

      Map.has_key?(map, "choice") and Map.has_key?(map, "reversible") ->
        @decision_key_order

      Map.has_key?(map, "schema") ->
        @report_key_order

      true ->
        map
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()
    end
  end

  defp take_present(entry, order) do
    Enum.reduce(order, %{}, fn key, acc ->
      case Map.fetch(entry, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
