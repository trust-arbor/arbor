defmodule Arbor.Actions.Coding.SecurityRegression.Core do
  @moduledoc """
  Pure input, result-schema, and two-revision verdict logic for security regressions.

  The imperative runner supplies plain leg/result maps. This module decides
  whether the candidate proved the regression without performing filesystem,
  process, clock, random, or registry operations.
  """

  @default_timeout 300_000
  @minimum_timeout 1_000
  # Derived from Shell spawn-capable ceiling so action limits cannot exceed admission.
  @maximum_timeout Arbor.Shell.spawn_capable_max_timeout_ms()
  @allowed_param_keys [:review_attestation_id, :timeout]
  @allowed_param_string_keys Enum.map(@allowed_param_keys, &Atom.to_string/1)

  @artifact_tag :arbor_security_regression_ex_unit
  @artifact_version 1
  @artifact_keys [
    :excluded,
    :executed,
    :invalid,
    :max_failures_reached,
    :passed,
    :setup_failures,
    :skipped,
    :suite_completed,
    :suite_started,
    :test_failures,
    :total
  ]

  @typedoc "A normalized, side-effect-free action input."
  @type input :: %{
          review_attestation_id: String.t(),
          timeout: pos_integer()
        }

  @doc false
  def default_timeout, do: @default_timeout

  @doc false
  def maximum_timeout, do: @maximum_timeout

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, review_attestation_id} <-
           validate_review_attestation_id(param(params, :review_attestation_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)) do
      {:ok,
       %{
         review_attestation_id: review_attestation_id,
         timeout: timeout
       }}
    end
  end

  def new(_params), do: {:error, :invalid_parameters}

  @doc "Validate and normalize the exact trusted formatter artifact schema."
  @spec validate_artifact(term()) :: {:ok, map()} | {:error, :invalid_result_artifact}
  def validate_artifact({@artifact_tag, @artifact_version, counts}) when is_map(counts) do
    with true <- Enum.sort(Map.keys(counts)) == @artifact_keys,
         true <- boolean?(counts.suite_started),
         true <- boolean?(counts.suite_completed),
         true <- boolean?(counts.max_failures_reached),
         true <- count_fields_valid?(counts),
         true <- counts.executed == counts.passed + counts.test_failures,
         true <-
           counts.total ==
             counts.executed + counts.skipped + counts.excluded + counts.invalid do
      {:ok,
       %{
         "excluded" => counts.excluded,
         "executed" => counts.executed,
         "invalid" => counts.invalid,
         "max_failures_reached" => counts.max_failures_reached,
         "passed" => counts.passed,
         "setup_failures" => counts.setup_failures,
         "skipped" => counts.skipped,
         "suite_completed" => counts.suite_completed,
         "suite_started" => counts.suite_started,
         "test_failures" => counts.test_failures,
         "total" => counts.total
       }}
    else
      _ -> {:error, :invalid_result_artifact}
    end
  end

  def validate_artifact(_artifact), do: {:error, :invalid_result_artifact}

  @doc "Build a completed execution leg from validated formatter counts."
  @spec completed_leg(integer(), boolean(), map(), map()) :: map()
  def completed_leg(exit_code, timed_out, counts, diagnostic)
      when is_integer(exit_code) and is_boolean(timed_out) and is_map(counts) and
             is_map(diagnostic) do
    %{
      status: :completed,
      exit_code: exit_code,
      timed_out: timed_out,
      counts: counts,
      diagnostic: diagnostic
    }
  end

  @doc "Build a non-completed execution leg with a stable status."
  @spec incomplete_leg(atom(), map(), integer() | nil, boolean()) :: map()
  def incomplete_leg(status, diagnostic \\ %{}, exit_code \\ nil, timed_out \\ false)
      when is_atom(status) and is_map(diagnostic) and
             (is_integer(exit_code) or is_nil(exit_code)) and is_boolean(timed_out) do
    %{
      status: status,
      exit_code: exit_code,
      timed_out: timed_out,
      counts: empty_counts(),
      diagnostic: diagnostic
    }
  end

  @doc "Return a placeholder for a leg intentionally not executed."
  @spec not_run_leg() :: map()
  def not_run_leg, do: incomplete_leg(:not_run)

  @doc "Decide whether a candidate leg is strong enough to justify running the base leg."
  @spec candidate_gate(map()) :: :ok | {:error, String.t()}
  def candidate_gate(leg) when is_map(leg) do
    counts = Map.get(leg, :counts, empty_counts())

    cond do
      Map.get(leg, :status) == :source_changed ->
        {:error, "candidate_source_changed"}

      Map.get(leg, :timed_out) == true ->
        {:error, "candidate_timeout"}

      Map.get(leg, :status) != :completed ->
        {:error, candidate_incomplete_reason(Map.get(leg, :status))}

      counts["suite_started"] != true or counts["suite_completed"] != true ->
        {:error, "candidate_suite_incomplete"}

      counts["max_failures_reached"] == true ->
        {:error, "candidate_suite_incomplete"}

      counts["setup_failures"] > 0 or counts["invalid"] > 0 ->
        {:error, "candidate_setup_failed"}

      counts["executed"] < 1 ->
        {:error, "candidate_zero_tests"}

      counts["test_failures"] > 0 ->
        {:error, "candidate_tests_failed"}

      Map.get(leg, :exit_code) != 0 ->
        {:error, "candidate_exit_nonzero"}

      true ->
        :ok
    end
  end

  @doc "Produce the final two-revision verdict."
  @spec verdict(map(), map()) :: %{passed: boolean(), reason: String.t()}
  def verdict(candidate, base) when is_map(candidate) and is_map(base) do
    case candidate_gate(candidate) do
      :ok -> base_verdict(base)
      {:error, reason} -> %{passed: false, reason: reason}
    end
  end

  @doc "Convert a verdict and execution facts into bounded deterministic evidence."
  @spec show(map()) :: map()
  def show(%{
        base_commit: base_commit,
        candidate_fingerprint: candidate_fingerprint,
        sources: sources,
        candidate: candidate,
        base: base
      }) do
    verdict = verdict(candidate, base)
    sources = Enum.sort_by(sources, & &1.path)

    %{
      passed: verdict.passed,
      reason: verdict.reason,
      base_commit: base_commit,
      candidate_fingerprint: candidate_fingerprint,
      test_paths: Enum.map(sources, & &1.path),
      source_hashes:
        Enum.map(sources, fn source ->
          %{path: source.path, sha256: source.sha256}
        end),
      candidate: leg_counts(candidate),
      base: leg_counts(base),
      diagnostics: %{
        candidate: Map.get(candidate, :diagnostic, %{}),
        base: Map.get(base, :diagnostic, %{})
      }
    }
  end

  @doc false
  def artifact_tag, do: @artifact_tag

  @doc false
  def artifact_version, do: @artifact_version

  defp validate_param_keys(params) do
    valid? =
      Enum.all?(Map.keys(params), fn key ->
        key in @allowed_param_keys or key in @allowed_param_string_keys
      end)

    if valid?, do: :ok, else: {:error, :unsupported_parameter}
  end

  defp validate_review_attestation_id(value)
       when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      {:error, :invalid_review_attestation_id}
    end
  end

  defp validate_review_attestation_id(_value), do: {:error, :invalid_review_attestation_id}

  defp validate_timeout(nil), do: {:ok, @default_timeout}

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout >= @minimum_timeout and timeout <= @maximum_timeout,
       do: {:ok, timeout}

  defp validate_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} ->
        if Integer.to_string(parsed) == timeout,
          do: validate_timeout(parsed),
          else: {:error, :invalid_timeout}

      _other ->
        {:error, :invalid_timeout}
    end
  end

  defp validate_timeout(_timeout), do: {:error, :invalid_timeout}

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp boolean?(value), do: is_boolean(value)

  defp count_fields_valid?(counts) do
    Enum.all?(
      [
        counts.excluded,
        counts.executed,
        counts.invalid,
        counts.passed,
        counts.setup_failures,
        counts.skipped,
        counts.test_failures,
        counts.total
      ],
      &(is_integer(&1) and &1 >= 0)
    )
  end

  defp base_verdict(base) do
    counts = Map.get(base, :counts, empty_counts())

    cond do
      Map.get(base, :timed_out) == true ->
        %{passed: false, reason: "base_timeout"}

      Map.get(base, :status) != :completed ->
        %{passed: false, reason: base_incomplete_reason(Map.get(base, :status))}

      counts["suite_started"] != true or counts["suite_completed"] != true ->
        %{passed: false, reason: "base_suite_incomplete"}

      counts["max_failures_reached"] == true ->
        %{passed: false, reason: "base_suite_incomplete"}

      counts["setup_failures"] > 0 or counts["invalid"] > 0 ->
        %{passed: false, reason: "base_setup_failed"}

      counts["executed"] < 1 ->
        %{passed: false, reason: "base_zero_tests"}

      counts["test_failures"] < 1 and Map.get(base, :exit_code) == 0 ->
        %{passed: false, reason: "base_tests_passed"}

      counts["test_failures"] < 1 ->
        %{passed: false, reason: "base_non_test_failure"}

      Map.get(base, :exit_code) == 0 ->
        %{passed: false, reason: "base_exit_zero"}

      true ->
        %{passed: true, reason: "security_regression_validated"}
    end
  end

  defp candidate_incomplete_reason(:artifact_invalid), do: "candidate_artifact_invalid"
  defp candidate_incomplete_reason(:helper_missing), do: "candidate_helper_missing"
  defp candidate_incomplete_reason(:execution_failed), do: "candidate_execution_failed"
  defp candidate_incomplete_reason(_status), do: "candidate_suite_incomplete"

  defp base_incomplete_reason(:artifact_invalid), do: "base_artifact_invalid"
  defp base_incomplete_reason(:helper_missing), do: "base_helper_missing"
  defp base_incomplete_reason(:snapshot_failed), do: "base_snapshot_failed"
  defp base_incomplete_reason(:overlay_failed), do: "base_overlay_failed"
  defp base_incomplete_reason(:execution_failed), do: "base_execution_failed"
  defp base_incomplete_reason(:not_run), do: "base_not_run"
  defp base_incomplete_reason(_status), do: "base_suite_incomplete"

  defp leg_counts(leg) do
    counts = Map.get(leg, :counts, empty_counts())

    %{
      completed: Map.get(leg, :status) == :completed,
      status: leg |> Map.get(:status, :unknown) |> Atom.to_string(),
      exit_code: Map.get(leg, :exit_code),
      timed_out: Map.get(leg, :timed_out, false),
      executed: counts["executed"],
      passed: counts["passed"],
      test_failures: counts["test_failures"],
      setup_failures: counts["setup_failures"],
      skipped: counts["skipped"],
      excluded: counts["excluded"],
      invalid: counts["invalid"]
    }
  end

  defp empty_counts do
    %{
      "excluded" => 0,
      "executed" => 0,
      "invalid" => 0,
      "max_failures_reached" => false,
      "passed" => 0,
      "setup_failures" => 0,
      "skipped" => 0,
      "suite_completed" => false,
      "suite_started" => false,
      "test_failures" => 0,
      "total" => 0
    }
  end
end
