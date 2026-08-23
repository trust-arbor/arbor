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
  # Exactly two sequential revisions (candidate then base); never multiplies Shell ceilings.
  @sequential_revisions 2
  @maximum_stage_timeout @sequential_revisions * @maximum_timeout
  @allowed_param_keys [:review_attestation_id, :timeout, :stage_timeout]
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

  @capacity_termination %{
    "timed_out" => true,
    "killed" => false,
    "output_limit_exceeded" => false,
    "cancelled" => false
  }

  @empty_output_sha256 Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @diagnostic_keys ~w(exit_code timed_out output_bytes output_sha256 untrusted_diagnostic_output)
  # Bound diagnostic output_bytes to the Shell output ceiling (public facade).
  @max_output_bytes Arbor.Shell.max_output_bytes_limit()
  @untrusted_diagnostic_output_limit 2_048
  @untrusted_omission_marker "\n...[omitted]...\n"
  # Max incomplete UTF-8 sequence; interior windows inspect only this many extra bytes.
  @utf8_boundary_allowance 3
  # Local fork of Arbor.Actions.Coding.CrossApp.Core's three-window policy:
  # this path additionally sanitizes arbitrary bytes and lets explicit process
  # failure select the anchor window. Keep shared UTF-8/ceiling behavior aligned.
  # Head and tail each take one eighth of the post-marker content budget.
  @excerpt_head_share 8
  @excerpt_anchor_lookback 64
  # Byte-level anchors: ExUnit numbered failure, Mix compilation banner, or
  # uncaught BEAM/Mix exception heading. Erlang :re is PCRE in byte mode.
  @diagnostic_anchor_pattern ~r/  [0-9]+\) [^\n]+\([A-Z][A-Za-z0-9_.]*\)|== Compilation error|\*\* \([A-Z][A-Za-z0-9_.]*\)/
  @schema_project_mix_file "apps/arbor_persistence/mix.exs"
  @schema_bootstrap_repo "Arbor.Persistence.Repo"
  @schema_bootstrap_tasks ["ecto.create", "ecto.migrate"]
  @schema_bootstrap_args ["-r", @schema_bootstrap_repo, "--quiet"]
  @schema_home_dir "~/.arbor"

  @typedoc "A normalized, side-effect-free action input."
  @type input :: %{
          review_attestation_id: String.t(),
          timeout: pos_integer(),
          stage_timeout: pos_integer() | nil
        }

  @doc false
  def default_timeout, do: @default_timeout

  @doc false
  def maximum_timeout, do: @maximum_timeout

  @doc false
  def maximum_stage_timeout, do: @maximum_stage_timeout

  @doc false
  def capacity_termination, do: @capacity_termination

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, review_attestation_id} <-
           validate_review_attestation_id(param(params, :review_attestation_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)),
         {:ok, stage_timeout} <- validate_stage_timeout(param(params, :stage_timeout)) do
      {:ok,
       %{
         review_attestation_id: review_attestation_id,
         timeout: timeout,
         stage_timeout: stage_timeout
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

  @doc """
  Pre-child residual / pure owner stage stop with closed capacity diagnostic.

  Empty diagnostics are forbidden on capacity legs; this constructor always
  emits a non-empty diagnostic with `timed_out: true`.
  """
  @spec stage_timeout_leg() :: map()
  def stage_timeout_leg do
    incomplete_leg(:stage_timeout, owner_stage_diagnostic(), nil, true)
  end

  @doc """
  Force capacity on an existing Mix leg without dropping counts/status.

  Synchronizes `leg.timed_out` and `diagnostic["timed_out"]` so post-child
  stage deadline crossings remain verification-admissible.

  Only structurally complete owner legs with an exact closed diagnostic whose
  `exit_code` and `timed_out` already match the leg are admitted. Malformed or
  non-map legs fail closed as ordinary incomplete evidence — never synthesize a
  valid capacity leg from garbage or open diagnostic maps.
  """
  @spec mark_capacity_leg(term()) :: map()
  def mark_capacity_leg(leg) when is_map(leg) and not is_struct(leg) do
    if capacity_source_leg?(leg) do
      exit_code = Map.get(leg, :exit_code)

      diagnostic =
        leg
        |> Map.fetch!(:diagnostic)
        |> closed_capacity_diagnostic(exit_code)

      %{leg | timed_out: true, diagnostic: diagnostic}
    else
      incomplete_leg(:suite_incomplete)
    end
  end

  def mark_capacity_leg(_leg), do: incomplete_leg(:suite_incomplete)

  @doc "Decide whether a candidate leg is strong enough to justify running the base leg."
  @spec candidate_gate(map()) :: :ok | {:error, String.t()}
  def candidate_gate(leg) when is_map(leg) do
    counts = Map.get(leg, :counts, empty_counts())

    cond do
      Map.get(leg, :status) == :source_changed ->
        {:error, "candidate_source_changed"}

      capacity_leg?(leg) ->
        {:error, "validation_capacity_exceeded"}

      Map.get(leg, :status) != :completed ->
        {:error, candidate_incomplete_reason(Map.get(leg, :status))}

      # Setup/bootstrap failures outrank suite-incomplete so a written
      # setup_failures artifact is not misread as an unfinished suite.
      counts["setup_failures"] > 0 or counts["invalid"] > 0 ->
        {:error, "candidate_setup_failed"}

      counts["suite_started"] != true or counts["suite_completed"] != true ->
        {:error, "candidate_suite_incomplete"}

      counts["max_failures_reached"] == true ->
        {:error, "candidate_suite_incomplete"}

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
    cond do
      capacity_leg?(candidate) or capacity_leg?(base) ->
        %{passed: false, reason: "validation_capacity_exceeded"}

      true ->
        case candidate_gate(candidate) do
          :ok -> base_verdict(base)
          {:error, reason} -> %{passed: false, reason: reason}
        end
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
      },
      # Closed capacity envelope when timed_out; nil for ordinary domain verdicts.
      termination:
        if(verdict.reason == "validation_capacity_exceeded",
          do: @capacity_termination,
          else: nil
        )
    }
  end

  @doc false
  def artifact_tag, do: @artifact_tag

  @doc false
  def artifact_version, do: @artifact_version

  @doc false
  def schema_project_mix_file, do: @schema_project_mix_file

  @doc false
  def schema_bootstrap_repo, do: @schema_bootstrap_repo

  @doc false
  def schema_bootstrap_tasks, do: @schema_bootstrap_tasks

  @doc false
  def schema_bootstrap_args, do: @schema_bootstrap_args

  @doc false
  def schema_home_dir, do: @schema_home_dir

  @doc false
  def untrusted_diagnostic_output_limit, do: @untrusted_diagnostic_output_limit

  @doc false
  def untrusted_diagnostic_field, do: "untrusted_diagnostic_output"

  @doc false
  def untrusted_omission_marker, do: @untrusted_omission_marker

  @doc """
  Closed child diagnostic. `output_bytes` / `output_sha256` cover the complete
  path-normalized binary unchanged. Only `untrusted_diagnostic_output` is
  sanitized and byte-bounded.

  Sanitize first, then bound. For a truncated child, every outcome other than
  the exact success pair (`exit_code == 0` and `timed_out == false`) may keep a
  small startup head, the first stable structural diagnostic anchor, and a
  small final tail. This includes a missing exit code. Exact success and
  failure output without an anchor keep the uniform head/tail excerpt. Exit
  code and `timed_out` are the only success/failure authorities; output prose
  is not.
  """
  @spec child_diagnostic(integer() | nil, boolean(), binary()) :: map()
  def child_diagnostic(exit_code, timed_out, path_normalized)
      when (is_integer(exit_code) or is_nil(exit_code)) and is_boolean(timed_out) and
             is_binary(path_normalized) do
    sanitized = sanitize_untrusted_output(path_normalized)

    %{
      "exit_code" => exit_code,
      "timed_out" => timed_out,
      "output_bytes" => byte_size(path_normalized),
      "output_sha256" => sha256(path_normalized),
      "untrusted_diagnostic_output" => bound_untrusted_output(sanitized, exit_code, timed_out)
    }
  end

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

  defp validate_stage_timeout(nil), do: {:ok, nil}

  defp validate_stage_timeout(stage_timeout)
       when is_integer(stage_timeout) and stage_timeout > 0 and
              stage_timeout <= @maximum_stage_timeout,
       do: {:ok, stage_timeout}

  defp validate_stage_timeout(stage_timeout) when is_binary(stage_timeout) do
    case Integer.parse(stage_timeout) do
      {parsed, ""} ->
        if Integer.to_string(parsed) == stage_timeout,
          do: validate_stage_timeout(parsed),
          else: {:error, :invalid_stage_timeout}

      _other ->
        {:error, :invalid_stage_timeout}
    end
  end

  defp validate_stage_timeout(_stage_timeout), do: {:error, :invalid_stage_timeout}

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

  # Trusted capacity signal is the leg timed_out flag. Constructors always keep
  # diagnostic["timed_out"] synchronized; verification re-checks consistency.
  defp capacity_leg?(leg) when is_map(leg), do: Map.get(leg, :timed_out) == true
  defp capacity_leg?(_leg), do: false

  # Admit only structurally complete owner legs with an exact closed diagnostic
  # whose exit_code and timed_out already match the leg. Malformed diagnostics
  # never become capacity sources (no synthetic rebuild from open maps).
  defp capacity_source_leg?(leg) when is_map(leg) and not is_struct(leg) do
    status = Map.get(leg, :status)
    exit_code = Map.get(leg, :exit_code)
    timed_out = Map.get(leg, :timed_out)
    counts = Map.get(leg, :counts)
    diagnostic = Map.get(leg, :diagnostic)

    is_atom(status) and is_boolean(timed_out) and is_map(counts) and not is_struct(counts) and
      (is_integer(exit_code) or is_nil(exit_code)) and
      closed_diagnostic_matching_leg?(diagnostic, exit_code, timed_out)
  end

  defp capacity_source_leg?(_leg), do: false

  defp closed_diagnostic_matching_leg?(diagnostic, exit_code, timed_out)
       when is_map(diagnostic) and not is_struct(diagnostic) and is_boolean(timed_out) do
    keys = Map.keys(diagnostic)

    map_size(diagnostic) == length(@diagnostic_keys) and
      MapSet.new(keys) == MapSet.new(@diagnostic_keys) and
      Map.get(diagnostic, "exit_code") == exit_code and
      Map.get(diagnostic, "timed_out") == timed_out and
      valid_output_bytes?(Map.get(diagnostic, "output_bytes")) and
      valid_output_sha256?(Map.get(diagnostic, "output_sha256")) and
      valid_untrusted_excerpt?(Map.get(diagnostic, "untrusted_diagnostic_output"))
  end

  defp closed_diagnostic_matching_leg?(_diagnostic, _exit_code, _timed_out), do: false

  defp valid_output_bytes?(bytes)
       when is_integer(bytes) and bytes >= 0 and bytes <= @max_output_bytes,
       do: true

  defp valid_output_bytes?(_bytes), do: false

  defp valid_output_sha256?(hash) when is_binary(hash) and byte_size(hash) == 64 do
    String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_output_sha256?(_hash), do: false

  defp valid_untrusted_excerpt?(excerpt)
       when is_binary(excerpt) and byte_size(excerpt) <= @untrusted_diagnostic_output_limit do
    String.valid?(excerpt) and not String.contains?(excerpt, <<0>>) and
      not unsafe_control_bytes?(excerpt)
  end

  defp valid_untrusted_excerpt?(_excerpt), do: false

  defp unsafe_control_bytes?(binary) when is_binary(binary) do
    unsafe_control_bytes?(binary, false)
  end

  defp unsafe_control_bytes?(<<>>, acc), do: acc

  defp unsafe_control_bytes?(<<byte, rest::binary>>, acc)
       when byte == 9 or byte == 10 or byte >= 32 do
    unsafe_control_bytes?(rest, acc)
  end

  defp unsafe_control_bytes?(<<_byte, _rest::binary>>, _acc), do: true

  defp owner_stage_diagnostic do
    %{
      "exit_code" => nil,
      "timed_out" => true,
      "output_bytes" => 0,
      "output_sha256" => @empty_output_sha256,
      "untrusted_diagnostic_output" => ""
    }
  end

  # Capacity mark only rewrites timed_out on an already-closed diagnostic that
  # matched the leg. Preserve bounded output fields; force timed_out true.
  defp closed_capacity_diagnostic(diagnostic, exit_code) when is_map(diagnostic) do
    %{
      "exit_code" => exit_code,
      "timed_out" => true,
      "output_bytes" => Map.fetch!(diagnostic, "output_bytes"),
      "output_sha256" => Map.fetch!(diagnostic, "output_sha256"),
      "untrusted_diagnostic_output" => Map.fetch!(diagnostic, "untrusted_diagnostic_output")
    }
  end

  defp sanitize_untrusted_output(binary) when is_binary(binary) do
    binary
    |> :binary.replace(<<13, 10>>, <<10>>, [:global])
    |> :binary.replace(<<13>>, <<10>>, [:global])
    |> drop_unsafe_controls()
    |> keep_valid_utf8()
  end

  defp drop_unsafe_controls(binary) when is_binary(binary) do
    for <<byte <- binary>>, byte == 9 or byte == 10 or byte >= 32, into: <<>>, do: <<byte>>
  end

  # Exit code and timed_out are the only authorities for the failure-aware
  # path; never infer success or failure from output prose.
  defp bound_untrusted_output(binary, exit_code, timed_out)
       when is_binary(binary) and (is_integer(exit_code) or is_nil(exit_code)) and
              is_boolean(timed_out) do
    size = byte_size(binary)

    cond do
      size <= @untrusted_diagnostic_output_limit ->
        binary

      not failure_aware_child?(exit_code, timed_out) ->
        bound_head_tail_output(binary)

      true ->
        case find_first_diagnostic_anchor(binary) do
          {:ok, anchor_start} ->
            bound_failure_aware_output(binary, min(anchor_start, size))

          :none ->
            bound_head_tail_output(binary)
        end
    end
  end

  defp failure_aware_child?(_exit_code, true), do: true
  defp failure_aware_child?(0, false), do: false
  defp failure_aware_child?(_exit_code, false), do: true

  defp bound_head_tail_output(binary) when is_binary(binary) do
    size = byte_size(binary)

    if size <= @untrusted_diagnostic_output_limit do
      binary
    else
      marker = @untrusted_omission_marker
      available = @untrusted_diagnostic_output_limit - byte_size(marker)
      head_length = div(available, 2)
      tail_length = available - head_length

      head = take_valid_utf8_prefix(binary_part(binary, 0, head_length))
      tail = take_valid_utf8_suffix(binary_part(binary, size - tail_length, tail_length))
      head <> marker <> tail
    end
  end

  defp find_first_diagnostic_anchor(binary) when is_binary(binary) do
    case Regex.run(@diagnostic_anchor_pattern, binary, return: :index) do
      [{offset, _length} | _] -> {:ok, offset}
      _other -> :none
    end
  end

  defp bound_failure_aware_output(binary, anchor_start)
       when is_binary(binary) and is_integer(anchor_start) and anchor_start >= 0 do
    size = byte_size(binary)

    if size <= @untrusted_diagnostic_output_limit do
      binary
    else
      build_failure_centered_excerpt(binary, size, min(anchor_start, size))
    end
  end

  defp build_failure_centered_excerpt(binary, size, anchor_start)
       when is_binary(binary) and is_integer(size) and is_integer(anchor_start) do
    marker = @untrusted_omission_marker
    marker_bytes = byte_size(marker)
    content_budget = @untrusted_diagnostic_output_limit - 2 * marker_bytes

    head_budget = div(content_budget, @excerpt_head_share)
    tail_budget = div(content_budget, @excerpt_head_share)
    middle_budget = content_budget - head_budget - tail_budget

    lookback = min(@excerpt_anchor_lookback, div(middle_budget, @excerpt_head_share))
    raw_middle_start = max(0, anchor_start - lookback)
    middle_end = min(size, raw_middle_start + middle_budget)

    middle_start =
      if middle_end - raw_middle_start < middle_budget and raw_middle_start > 0 do
        max(0, middle_end - middle_budget)
      else
        raw_middle_start
      end

    head_end = min(head_budget, middle_start)
    tail_start = max(middle_end, size - tail_budget)

    head_text =
      if head_end > 0 do
        nonempty_window(take_valid_utf8_prefix(binary_part(binary, 0, head_end)))
      else
        nil
      end

    middle_text =
      nonempty_window(
        repair_sanitized_interior_window(binary, middle_start, middle_end - middle_start)
      )

    tail_text =
      if tail_start < size do
        nonempty_window(
          take_valid_utf8_suffix(binary_part(binary, tail_start, size - tail_start))
        )
      else
        nil
      end

    head_gap? = head_text != nil and middle_text != nil and middle_start > head_end
    tail_gap? = tail_text != nil and middle_text != nil and tail_start > middle_end

    parts = []
    parts = if head_text != nil, do: [head_text | parts], else: parts
    parts = if head_gap?, do: [marker | parts], else: parts
    parts = if middle_text != nil, do: [middle_text | parts], else: parts
    parts = if tail_gap?, do: [marker | parts], else: parts
    parts = if tail_text != nil, do: [tail_text | parts], else: parts

    parts
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp nonempty_window(<<>>), do: nil
  defp nonempty_window(text) when is_binary(text), do: text

  # Leading and trailing partials are dropped independently: suffix's
  # whole-slice String.valid?/1 walk can erase an interior diagnostic when
  # both window edges split multibyte codepoints.
  defp repair_sanitized_interior_window(_binary, _start_offset, length_budget)
       when is_integer(length_budget) and length_budget <= 0 do
    ""
  end

  defp repair_sanitized_interior_window(binary, start_offset, length_budget)
       when is_binary(binary) and is_integer(start_offset) and start_offset >= 0 and
              is_integer(length_budget) and length_budget > 0 do
    size = byte_size(binary)
    start = min(start_offset, size)
    available = size - start

    if available <= 0 do
      ""
    else
      take = min(available, length_budget + @utf8_boundary_allowance)

      binary
      |> binary_part(start, take)
      |> drop_leading_incomplete_utf8()
      |> take_valid_utf8_prefix()
      |> take_bounded_utf8_prefix(length_budget)
    end
  end

  defp repair_sanitized_interior_window(_binary, _start_offset, _length_budget), do: ""

  defp drop_leading_incomplete_utf8(binary) when is_binary(binary) do
    drop_leading_incomplete_utf8(binary, 0)
  end

  defp drop_leading_incomplete_utf8(<<>>, _skipped), do: <<>>

  defp drop_leading_incomplete_utf8(binary, skipped)
       when skipped > @utf8_boundary_allowance do
    binary
  end

  defp drop_leading_incomplete_utf8(binary, skipped) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        binary

      {:incomplete, good, _rest} when is_binary(good) and good != <<>> ->
        binary

      {:error, good, _rest} when is_binary(good) and good != <<>> ->
        binary

      {:error, _good, <<_drop, rest::binary>>} ->
        drop_leading_incomplete_utf8(rest, skipped + 1)

      {:incomplete, <<>>, _rest} ->
        <<_drop, rest::binary>> = binary
        drop_leading_incomplete_utf8(rest, skipped + 1)

      _other ->
        <<>>
    end
  end

  defp take_bounded_utf8_prefix(_text, max_bytes)
       when is_integer(max_bytes) and max_bytes <= 0 do
    ""
  end

  defp take_bounded_utf8_prefix(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and byte_size(text) <= max_bytes do
    text
  end

  defp take_bounded_utf8_prefix(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> take_valid_utf8_prefix()
  end

  # Drop invalid sequences and continue so a valid suffix after bad bytes
  # remains visible. Incomplete trailing bytes are dropped. Window-edge
  # repair still uses take_valid_utf8_prefix/suffix only.
  defp keep_valid_utf8(binary) when is_binary(binary) do
    keep_valid_utf8_loop(binary, [])
  end

  defp keep_valid_utf8_loop(<<>>, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp keep_valid_utf8_loop(binary, acc) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        keep_valid_utf8_loop(<<>>, [valid | acc])

      {:incomplete, incomplete, _rest} when is_binary(incomplete) ->
        keep_valid_utf8_loop(<<>>, [incomplete | acc])

      {:error, good, <<_drop, more::binary>>} when is_binary(good) ->
        keep_valid_utf8_loop(more, [good | acc])

      {:error, good, <<>>} when is_binary(good) ->
        keep_valid_utf8_loop(<<>>, [good | acc])

      _other ->
        keep_valid_utf8_loop(<<>>, acc)
    end
  end

  defp take_valid_utf8_prefix(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      {:incomplete, incomplete, _rest} when is_binary(incomplete) ->
        incomplete

      {:error, good, _rest} when is_binary(good) ->
        good

      _other ->
        ""
    end
  end

  defp take_valid_utf8_suffix(<<>>), do: ""

  defp take_valid_utf8_suffix(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      <<_drop, rest::binary>> = binary
      take_valid_utf8_suffix(rest)
    end
  end

  defp sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp base_verdict(base) do
    counts = Map.get(base, :counts, empty_counts())

    cond do
      capacity_leg?(base) ->
        %{passed: false, reason: "validation_capacity_exceeded"}

      Map.get(base, :status) != :completed ->
        %{passed: false, reason: base_incomplete_reason(Map.get(base, :status))}

      # Same setup-before-incomplete order as candidate_gate/1.
      counts["setup_failures"] > 0 or counts["invalid"] > 0 ->
        %{passed: false, reason: "base_setup_failed"}

      counts["suite_started"] != true or counts["suite_completed"] != true ->
        %{passed: false, reason: "base_suite_incomplete"}

      counts["max_failures_reached"] == true ->
        %{passed: false, reason: "base_suite_incomplete"}

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
  defp candidate_incomplete_reason(:stage_timeout), do: "validation_capacity_exceeded"
  defp candidate_incomplete_reason(_status), do: "candidate_suite_incomplete"

  defp base_incomplete_reason(:artifact_invalid), do: "base_artifact_invalid"
  defp base_incomplete_reason(:helper_missing), do: "base_helper_missing"
  defp base_incomplete_reason(:snapshot_failed), do: "base_snapshot_failed"
  defp base_incomplete_reason(:overlay_failed), do: "base_overlay_failed"
  defp base_incomplete_reason(:execution_failed), do: "base_execution_failed"
  defp base_incomplete_reason(:not_run), do: "base_not_run"
  defp base_incomplete_reason(:stage_timeout), do: "validation_capacity_exceeded"
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
