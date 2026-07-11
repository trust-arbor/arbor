defmodule Arbor.Actions.Coding.CrossApp.Core do
  @moduledoc """
  Pure input, dependency-selection, and evidence logic for cross-app validation.

  The imperative shell supplies changed files and parsed app metadata. This module
  decides the affected-app closure and formats JSON-clean validation evidence
  without filesystem, process, clock, or registry operations.
  """

  @default_timeout 300_000
  @minimum_timeout 1_000
  @maximum_timeout 600_000
  @allowed_param_keys [:workspace_id, :timeout]
  @allowed_param_string_keys Enum.map(@allowed_param_keys, &Atom.to_string/1)

  @max_changed_files 2_000
  @max_apps 256
  @max_identifier_bytes 64
  @max_test_paths 256
  @max_output_list 2_000
  # Process/stream excerpts and aggregate evidence are fixed-size by *bytes*.
  @max_output_excerpt_bytes 2_000
  @max_aggregate_excerpt_bytes 2_000
  @excerpt_omission_marker "\n...[omitted]...\n"
  # U+FFFD replacement character in UTF-8.
  @utf8_replacement <<0xEF, 0xBF, 0xBD>>
  # Max incomplete UTF-8 sequence length is 3 trailing/leading bytes. Windows
  # take this extra raw allowance so repair can complete a cut multi-byte char
  # without scanning the rest of the stream.
  @utf8_boundary_allowance 3

  @root_wide_exact MapSet.new([
                     "mix.exs",
                     "mix.lock",
                     ".formatter.exs",
                     ".tool-versions"
                   ])

  @typedoc "Normalized, side-effect-free action input."
  @type input :: %{
          workspace_id: String.t(),
          timeout: pos_integer()
        }

  @typedoc "One umbrella app's static dependency metadata."
  @type app_def :: %{
          dir: String.t(),
          app: String.t(),
          deps: [String.t()]
        }

  @typedoc "Dependency graph keyed by app directory/name."
  @type graph :: %{
          apps: [String.t()],
          # app => upstream in-umbrella deps it depends on
          depends_on: %{optional(String.t()) => [String.t()]},
          # app => downstream apps that depend on it
          depended_by: %{optional(String.t()) => [String.t()]}
        }

  @typedoc "Selection result for changed files against a graph."
  @type selection :: %{
          changed_files: [String.t()],
          changed_apps: [String.t()],
          affected_apps: [String.t()],
          test_paths: [String.t()],
          root_wide: boolean()
        }

  @typedoc "One completed (or budget-exhausted) per-app test invocation record."
  @type app_test_result :: %{
          path: String.t(),
          passed: boolean(),
          timed_out: boolean(),
          exit_code: integer() | nil,
          reason: String.t() | nil,
          stdout_excerpt: String.t(),
          stderr_excerpt: String.t(),
          stdout_truncated: boolean(),
          stderr_truncated: boolean(),
          stdout_sha256: String.t(),
          stderr_sha256: String.t()
        }

  @typedoc "Pure decision for the next sequential app-test Mix invocation."
  @type test_step ::
          :complete
          | {:run, String.t(), pos_integer(), [String.t()]}
          | {:timeout, String.t(), [String.t()]}

  @doc "Construct and validate the action's deliberately narrow input surface."
  @spec new(map()) :: {:ok, input()} | {:error, atom()}
  def new(params) when is_map(params) do
    with :ok <- validate_param_keys(params),
         {:ok, workspace_id} <- validate_workspace_id(param(params, :workspace_id)),
         {:ok, timeout} <- validate_timeout(param(params, :timeout)) do
      {:ok, %{workspace_id: workspace_id, timeout: timeout}}
    end
  end

  def new(_params), do: {:error, :invalid_parameters}

  @doc "Build a dependency graph from pure app definitions. Fails closed on ambiguity."
  @spec build_graph([app_def()]) :: {:ok, graph()} | {:error, term()}
  def build_graph(app_defs) when is_list(app_defs) do
    with :ok <- validate_app_def_count(app_defs),
         :ok <- validate_app_defs(app_defs) do
      apps = app_defs |> Enum.map(& &1.dir) |> Enum.sort()
      app_set = MapSet.new(apps)

      depends_on =
        Map.new(app_defs, fn %{dir: dir, deps: deps} ->
          {dir, deps |> Enum.uniq() |> Enum.sort()}
        end)

      with :ok <- validate_dep_targets(depends_on, app_set) do
        depended_by =
          Enum.reduce(depends_on, %{}, fn {app, deps}, acc ->
            Enum.reduce(deps, acc, fn dep, acc2 ->
              Map.update(acc2, dep, [app], fn existing -> [app | existing] end)
            end)
          end)
          |> Map.new(fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)

        {:ok,
         %{
           apps: apps,
           depends_on: depends_on,
           depended_by: depended_by
         }}
      end
    end
  end

  def build_graph(_), do: {:error, :invalid_app_defs}

  @doc """
  Select changed and affected apps from changed files and a dependency graph.

  Directly changed apps plus every downstream in-umbrella dependent. Root
  build-impact files select all apps. Unrelated docs do not widen selection.
  """
  @spec select([String.t()], graph()) :: {:ok, selection()} | {:error, term()}
  def select(changed_files, graph) when is_list(changed_files) and is_map(graph) do
    with {:ok, files} <- normalize_changed_files(changed_files),
         {:ok, changed_apps, root_wide} <- classify_files(files, graph) do
      affected_apps =
        if root_wide do
          graph.apps
        else
          downstream_closure(changed_apps, graph.depended_by)
        end

      test_paths =
        affected_apps
        |> Enum.map(&("apps/" <> &1 <> "/test"))
        |> Enum.take(@max_test_paths)

      {:ok,
       %{
         changed_files: Enum.take(files, @max_output_list),
         changed_apps: changed_apps,
         affected_apps: affected_apps,
         test_paths: test_paths,
         root_wide: root_wide
       }}
    end
  end

  def select(_, _), do: {:error, :invalid_selection_input}

  @doc "Assemble bounded JSON-clean evidence from selection and check results."
  @spec show(map()) :: map()
  def show(%{
        selection: selection,
        checks: checks,
        base_commit: base_commit
      })
      when is_map(selection) and is_map(checks) do
    compile = Map.get(checks, :compile) || Map.get(checks, "compile") || %{}
    xref = Map.get(checks, :xref) || Map.get(checks, "xref") || %{}
    test = Map.get(checks, :test) || Map.get(checks, "test") || %{}

    compile_passed = Map.get(compile, :passed) || Map.get(compile, "passed") || false
    xref_passed = Map.get(xref, :passed) || Map.get(xref, "passed") || false
    test_passed = Map.get(test, :passed) || Map.get(test, "passed") || false

    passed = compile_passed and xref_passed and test_passed
    reason = overall_reason(passed, compile, xref, test)

    %{
      passed: passed,
      reason: reason,
      base_commit: base_commit,
      changed_files: selection.changed_files,
      changed_apps: selection.changed_apps,
      affected_apps: selection.affected_apps,
      test_paths: selection.test_paths,
      root_wide: selection.root_wide,
      compile: normalize_check(compile),
      xref: normalize_check(xref),
      test: normalize_check(test)
    }
  end

  @doc false
  def default_timeout, do: @default_timeout

  @doc false
  def maximum_timeout, do: @maximum_timeout

  @doc false
  def root_wide_path?(path) when is_binary(path) do
    cond do
      MapSet.member?(@root_wide_exact, path) -> true
      String.starts_with?(path, "config/") -> true
      true -> false
    end
  end

  def root_wide_path?(_), do: false

  @doc false
  def app_dir_from_path(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app | _rest] when app != "" ->
        if valid_identifier?(app), do: {:ok, app}, else: {:error, {:invalid_app_dir, app}}

      _ ->
        :not_app_path
    end
  end

  def app_dir_from_path(_), do: :not_app_path

  @doc "Build a skipped-check map (domain failure cascade)."
  @spec skipped_check(String.t()) :: map()
  def skipped_check(reason) when is_binary(reason) do
    %{
      "status" => "skipped",
      "passed" => false,
      "exit_code" => nil,
      "reason" => reason,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => sha256(""),
      "stderr_sha256" => sha256("")
    }
  end

  @doc "Build a completed-check map from Mix feedback plus optional status."
  @spec completed_check(map(), keyword()) :: map()
  def completed_check(feedback, opts \\ []) when is_map(feedback) do
    passed = Map.get(feedback, "passed") || Map.get(feedback, :passed) || false
    exit_code = Map.get(feedback, "exit_code") || Map.get(feedback, :exit_code)

    %{
      "status" => Keyword.get(opts, :status, "completed"),
      "passed" => passed == true,
      "exit_code" => exit_code,
      "reason" => Keyword.get(opts, :reason),
      "stdout_excerpt" =>
        json_safe_utf8(
          Map.get(feedback, "stdout_excerpt") || Map.get(feedback, :stdout_excerpt) || ""
        ),
      "stderr_excerpt" =>
        json_safe_utf8(
          Map.get(feedback, "stderr_excerpt") || Map.get(feedback, :stderr_excerpt) || ""
        ),
      "stdout_truncated" =>
        Map.get(feedback, "stdout_truncated") || Map.get(feedback, :stdout_truncated) || false,
      "stderr_truncated" =>
        Map.get(feedback, "stderr_truncated") || Map.get(feedback, :stderr_truncated) || false,
      "stdout_sha256" =>
        Map.get(feedback, "stdout_sha256") || Map.get(feedback, :stdout_sha256) || sha256(""),
      "stderr_sha256" =>
        Map.get(feedback, "stderr_sha256") || Map.get(feedback, :stderr_sha256) || sha256("")
    }
  end

  @doc "No-op passed check when there is nothing to run (e.g. zero test paths)."
  @spec empty_pass_check(String.t()) :: map()
  def empty_pass_check(reason) when is_binary(reason) do
    %{
      "status" => "skipped",
      "passed" => true,
      "exit_code" => 0,
      "reason" => reason,
      "stdout_excerpt" => "",
      "stderr_excerpt" => "",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => sha256(""),
      "stderr_sha256" => sha256("")
    }
  end

  @doc """
  Build JSON-clean Mix feedback from a raw process result map.

  Process streams are treated as arbitrary bytes: SHA-256 hashes the raw binary,
  excerpts are UTF-8-safe for Jason, and excerpt length is bounded by *bytes*
  without splitting multi-byte codepoints.
  """
  @spec feedback_from_result(map()) :: map()
  def feedback_from_result(result) when is_map(result) do
    stdout = raw_stream(result, :stdout)
    stderr = raw_stream(result, :stderr)
    exit_code = Map.get(result, :exit_code) || Map.get(result, "exit_code")

    {stdout_excerpt, stdout_truncated} = bound_output_excerpt(stdout)
    {stderr_excerpt, stderr_truncated} = bound_output_excerpt(stderr)

    %{
      "exit_code" => exit_code,
      "passed" => exit_code == 0,
      "stdout_excerpt" => stdout_excerpt,
      "stderr_excerpt" => stderr_excerpt,
      "stdout_truncated" => stdout_truncated,
      "stderr_truncated" => stderr_truncated,
      "stdout_sha256" => sha256(stdout),
      "stderr_sha256" => sha256(stderr)
    }
  end

  @doc """
  True only for exact runner/result timeout markers.

  Never inspects stdout/stderr/reason text for words like "timeout".
  """
  @spec runner_timed_out?(term()) :: boolean()
  def runner_timed_out?(result) when is_map(result) do
    Map.get(result, :timed_out) == true or Map.get(result, "timed_out") == true
  end

  def runner_timed_out?(_), do: false

  @doc """
  Stage-level timeout after a child returns: runner marker **or** shared budget
  fully consumed (`remaining_ms_after <= 0`), including the final child.
  """
  @spec child_timed_out?(boolean(), integer()) :: boolean()
  def child_timed_out?(runner_timed_out?, remaining_ms_after)
      when is_boolean(runner_timed_out?) and is_integer(remaining_ms_after) do
    runner_timed_out? or remaining_ms_after <= 0
  end

  @doc """
  Pure next-step decision for sequential per-app tests under a shared budget.

  `remaining_ms` is computed by the shell from a single monotonic deadline for
  the entire test stage. Returns:
  - `:complete` when no paths remain
  - `{:run, path, budget_ms, rest}` when budget remains
  - `{:timeout, path, rest}` when budget is exhausted with paths left
  """
  @spec next_test_step(integer(), [String.t()]) :: test_step()
  def next_test_step(_remaining_ms, []) do
    :complete
  end

  def next_test_step(remaining_ms, [path | rest])
      when is_integer(remaining_ms) and remaining_ms <= 0 and is_binary(path) do
    {:timeout, path, rest}
  end

  def next_test_step(remaining_ms, [path | rest])
      when is_integer(remaining_ms) and remaining_ms > 0 and is_binary(path) do
    {:run, path, remaining_ms, rest}
  end

  def next_test_step(_, _), do: :complete

  @doc """
  Classify one Mix process result for a single app test path.

  Deadline/process wall-clock work stays in the shell; this only maps feedback
  into a pure per-app record. Timed-out processes are failures with
  `tests_timed_out`; non-zero exits use the stable `tests_failed` reason.
  Timeout classification is driven solely by the `timed_out` option (exact
  shape from the shell), never by substring matching on output text.
  """
  @spec classify_app_test_result(String.t(), map(), keyword()) :: app_test_result()
  def classify_app_test_result(path, feedback, opts \\ [])
      when is_binary(path) and is_map(feedback) and is_list(opts) do
    timed_out = Keyword.get(opts, :timed_out, false) == true
    exit_code = Map.get(feedback, "exit_code") || Map.get(feedback, :exit_code)
    raw_passed = Map.get(feedback, "passed") || Map.get(feedback, :passed) || false
    passed = raw_passed == true and not timed_out and exit_code == 0

    reason =
      cond do
        passed -> nil
        timed_out -> "tests_timed_out"
        true -> "tests_failed"
      end

    stdout_excerpt =
      json_safe_utf8(
        Map.get(feedback, "stdout_excerpt") || Map.get(feedback, :stdout_excerpt) || ""
      )

    stderr_excerpt =
      json_safe_utf8(
        Map.get(feedback, "stderr_excerpt") || Map.get(feedback, :stderr_excerpt) || ""
      )

    %{
      path: path,
      passed: passed,
      timed_out: timed_out,
      exit_code: exit_code,
      reason: reason,
      stdout_excerpt: stdout_excerpt,
      stderr_excerpt: stderr_excerpt,
      stdout_truncated:
        Map.get(feedback, "stdout_truncated") || Map.get(feedback, :stdout_truncated) || false,
      stderr_truncated:
        Map.get(feedback, "stderr_truncated") || Map.get(feedback, :stderr_truncated) || false,
      stdout_sha256:
        Map.get(feedback, "stdout_sha256") || Map.get(feedback, :stdout_sha256) || sha256(""),
      stderr_sha256:
        Map.get(feedback, "stderr_sha256") || Map.get(feedback, :stderr_sha256) || sha256("")
    }
  end

  @doc """
  Deterministic record for an app path that was not started because the shared
  test-stage budget was already exhausted.
  """
  @spec budget_exhausted_result(String.t()) :: app_test_result()
  def budget_exhausted_result(path) when is_binary(path) do
    message = "test stage budget exhausted before " <> path

    %{
      path: path,
      passed: false,
      timed_out: true,
      exit_code: nil,
      reason: "tests_timed_out",
      stdout_excerpt: message,
      stderr_excerpt: "",
      stdout_truncated: false,
      stderr_truncated: false,
      stdout_sha256: sha256(message),
      stderr_sha256: sha256("")
    }
  end

  @doc """
  Aggregate ordered per-app test results into the existing JSON-clean check shape.

  Excerpts are path-labeled and re-bounded to a fixed *byte* size independent of
  app count. Aggregate hashes are derived from each path plus that process's
  stdout/stderr hashes so completed invocations remain covered without retaining
  unbounded process output. Prior successful children stay in the aggregate when
  a later child fails or times out.
  """
  @spec aggregate_test_check([app_test_result()]) :: map()
  def aggregate_test_check([]), do: empty_pass_check("no_existing_test_dirs")

  def aggregate_test_check(app_results) when is_list(app_results) do
    all_passed = Enum.all?(app_results, &(&1.passed == true))

    reason =
      cond do
        all_passed -> nil
        Enum.any?(app_results, &(&1.timed_out == true)) -> "tests_timed_out"
        true -> "tests_failed"
      end

    exit_code =
      cond do
        all_passed ->
          0

        true ->
          app_results
          |> Enum.find(&(&1.passed != true))
          |> case do
            %{exit_code: code} -> code
            _ -> nil
          end
      end

    {stdout_excerpt, stdout_agg_truncated} =
      bound_aggregate_excerpt(app_results, :stdout_excerpt)

    {stderr_excerpt, stderr_agg_truncated} =
      bound_aggregate_excerpt(app_results, :stderr_excerpt)

    stdout_truncated =
      stdout_agg_truncated or Enum.any?(app_results, &(&1.stdout_truncated == true))

    stderr_truncated =
      stderr_agg_truncated or Enum.any?(app_results, &(&1.stderr_truncated == true))

    completed_check(
      %{
        "passed" => all_passed,
        "exit_code" => exit_code,
        "stdout_excerpt" => stdout_excerpt,
        "stderr_excerpt" => stderr_excerpt,
        "stdout_truncated" => stdout_truncated,
        "stderr_truncated" => stderr_truncated,
        "stdout_sha256" => aggregate_stream_hash(app_results, :stdout_sha256),
        "stderr_sha256" => aggregate_stream_hash(app_results, :stderr_sha256)
      },
      reason: reason
    )
  end

  @doc false
  def max_aggregate_excerpt, do: @max_aggregate_excerpt_bytes

  @doc false
  def max_output_excerpt_bytes, do: @max_output_excerpt_bytes

  @doc false
  def bound_output_excerpt(raw) when is_binary(raw) do
    # Never sanitize or enumerate the full raw stream just to build a ~2 KB
    # excerpt. Hashing (caller) covers the complete already-bounded raw bytes;
    # excerpts only repair bounded head/tail windows (+ UTF-8 boundary allowance).
    size = byte_size(raw)

    if size <= @max_output_excerpt_bytes do
      {replace_invalid_utf8(raw), false}
    else
      marker = @excerpt_omission_marker
      available = @max_output_excerpt_bytes - byte_size(marker)
      head_budget = div(available, 2)
      tail_budget = available - head_budget

      head = repair_raw_window_prefix(raw, head_budget)
      tail = repair_raw_window_suffix(raw, tail_budget)
      {head <> marker <> tail, true}
    end
  end

  def bound_output_excerpt(_), do: {"", false}

  @doc false
  def json_safe_utf8(data) when is_binary(data), do: replace_invalid_utf8(data)
  def json_safe_utf8(_), do: ""

  defp bound_aggregate_excerpt(app_results, field) do
    text =
      app_results
      |> Enum.map(fn result ->
        body = json_safe_utf8(Map.get(result, field) || "")
        path = json_safe_utf8(result.path)
        "[" <> path <> "]\n" <> body
      end)
      |> Enum.join("\n")

    # Per-app bodies are already excerpt-bounded; re-use the same windowed
    # head/tail path so aggregate re-bounding never walks the joined text as
    # a full character list either.
    bound_output_excerpt(text)
  end

  defp aggregate_stream_hash(app_results, field) do
    material =
      app_results
      |> Enum.map(fn result ->
        hash = Map.get(result, field) || sha256("")
        result.path <> "\n" <> hash
      end)
      |> Enum.join("\n")

    sha256(material)
  end

  defp raw_stream(result, key) when is_atom(key) do
    case Map.fetch(result, key) do
      {:ok, value} when is_binary(value) ->
        value

      {:ok, nil} ->
        ""

      {:ok, _} ->
        ""

      :error ->
        case Map.fetch(result, Atom.to_string(key)) do
          {:ok, value} when is_binary(value) -> value
          _ -> ""
        end
    end
  end

  # Linear iodata repair: each invalid/incomplete byte becomes U+FFFD once.
  # Used only on already-bounded windows (or streams that already fit the
  # excerpt budget), never as a full-stream pre-pass for large process output.
  defp replace_invalid_utf8(data) when is_binary(data) do
    data
    |> replace_invalid_utf8_iodata([])
    |> IO.iodata_to_binary()
  end

  defp replace_invalid_utf8_iodata(<<>>, acc), do: Enum.reverse(acc)

  defp replace_invalid_utf8_iodata(data, acc) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      result when is_binary(result) ->
        Enum.reverse([result | acc])

      {:error, good, <<_bad, next::binary>>} when is_binary(good) ->
        replace_invalid_utf8_iodata(next, prepend_replacement(good, acc))

      {:error, good, _rest} when is_binary(good) ->
        Enum.reverse(prepend_replacement(good, acc))

      {:incomplete, good, _rest} when is_binary(good) ->
        Enum.reverse(prepend_replacement(good, acc))

      _other ->
        Enum.reverse([@utf8_replacement | acc])
    end
  end

  defp prepend_replacement(<<>>, acc), do: [@utf8_replacement | acc]
  defp prepend_replacement(good, acc), do: [@utf8_replacement, good | acc]

  defp repair_raw_window_prefix(raw, budget)
       when is_binary(raw) and is_integer(budget) and budget <= 0 do
    ""
  end

  defp repair_raw_window_prefix(raw, budget) when is_binary(raw) and is_integer(budget) do
    size = byte_size(raw)
    take = min(size, budget + @utf8_boundary_allowance)

    raw
    |> binary_part(0, take)
    |> replace_invalid_utf8()
    |> take_utf8_prefix_bytes(budget)
  end

  defp repair_raw_window_suffix(raw, budget)
       when is_binary(raw) and is_integer(budget) and budget <= 0 do
    ""
  end

  defp repair_raw_window_suffix(raw, budget) when is_binary(raw) and is_integer(budget) do
    size = byte_size(raw)
    take = min(size, budget + @utf8_boundary_allowance)

    raw
    |> binary_part(size - take, take)
    |> replace_invalid_utf8()
    |> take_utf8_suffix_bytes(budget)
  end

  defp take_utf8_prefix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and max_bytes <= 0 do
    ""
  end

  defp take_utf8_prefix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and byte_size(text) <= max_bytes do
    text
  end

  defp take_utf8_prefix_bytes(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    # Input is already repaired/valid UTF-8 of a bounded window. Drop at most
    # a few trailing bytes so we do not split a multi-byte codepoint.
    text
    |> binary_part(0, max_bytes)
    |> trim_incomplete_utf8_suffix()
  end

  defp take_utf8_suffix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and max_bytes <= 0 do
    ""
  end

  defp take_utf8_suffix_bytes(text, max_bytes)
       when is_binary(text) and is_integer(max_bytes) and byte_size(text) <= max_bytes do
    text
  end

  defp take_utf8_suffix_bytes(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    # Input is already repaired/valid UTF-8 of a bounded window. Align the
    # start index forward by at most 3 bytes so the suffix is complete UTF-8.
    size = byte_size(text)
    start = align_utf8_start(text, size - max_bytes, 0)
    binary_part(text, start, size - start)
  end

  defp trim_incomplete_utf8_suffix(<<>>), do: <<>>

  defp trim_incomplete_utf8_suffix(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      size = byte_size(bin)

      if size <= 1 do
        <<>>
      else
        trim_incomplete_utf8_suffix(binary_part(bin, 0, size - 1))
      end
    end
  end

  defp align_utf8_start(_text, start, _n) when start <= 0, do: 0

  defp align_utf8_start(_text, start, n) when n > @utf8_boundary_allowance do
    # Should not happen for valid UTF-8; fail soft to empty-aligned start.
    start
  end

  defp align_utf8_start(text, start, n) do
    size = byte_size(text)
    part = binary_part(text, start, size - start)

    if String.valid?(part) do
      start
    else
      align_utf8_start(text, start + 1, n + 1)
    end
  end

  defp validate_param_keys(params) do
    valid? =
      Enum.all?(Map.keys(params), fn key ->
        key in @allowed_param_keys or key in @allowed_param_string_keys
      end)

    if valid?, do: :ok, else: {:error, :unsupported_parameter}
  end

  defp validate_workspace_id(value)
       when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, value}
    else
      {:error, :invalid_workspace_id}
    end
  end

  defp validate_workspace_id(_value), do: {:error, :invalid_workspace_id}

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

  defp validate_app_def_count(app_defs) do
    if length(app_defs) <= @max_apps, do: :ok, else: {:error, :too_many_apps}
  end

  defp validate_app_defs(app_defs) do
    dirs = Enum.map(app_defs, & &1.dir)
    apps = Enum.map(app_defs, & &1.app)

    cond do
      Enum.any?(app_defs, fn def ->
        not is_binary(def.dir) or not is_binary(def.app) or not is_list(def.deps)
      end) ->
        {:error, :malformed_app_def}

      Enum.any?(app_defs, fn def -> def.dir != def.app end) ->
        {:error, :app_dir_name_mismatch}

      Enum.any?(dirs, &(not valid_identifier?(&1))) ->
        {:error, :invalid_app_identifier}

      Enum.any?(apps, &(not valid_identifier?(&1))) ->
        {:error, :invalid_app_identifier}

      Enum.any?(app_defs, fn def -> Enum.any?(def.deps, &(not valid_identifier?(&1))) end) ->
        {:error, :invalid_dep_identifier}

      length(Enum.uniq(dirs)) != length(dirs) ->
        {:error, :duplicate_app_dir}

      length(Enum.uniq(apps)) != length(apps) ->
        {:error, :duplicate_app_name}

      true ->
        :ok
    end
  end

  defp validate_dep_targets(depends_on, app_set) do
    unknown =
      depends_on
      |> Enum.flat_map(fn {from, deps} ->
        Enum.reject(deps, &MapSet.member?(app_set, &1))
        |> Enum.map(&{from, &1})
      end)

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_in_umbrella_dep, Enum.sort(unknown)}}
    end
  end

  defp normalize_changed_files(files) do
    if length(files) > @max_changed_files do
      {:error, :too_many_changed_files}
    else
      normalized =
        files
        |> Enum.map(&normalize_path/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      if Enum.any?(normalized, &(byte_size(&1) > 1_024)) do
        {:error, :changed_file_path_too_long}
      else
        {:ok, normalized}
      end
    end
  end

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> nil
      String.contains?(trimmed, <<0>>) -> nil
      String.starts_with?(trimmed, "/") -> nil
      String.contains?(trimmed, "..") -> nil
      true -> trimmed
    end
  end

  defp normalize_path(_), do: nil

  defp classify_files(files, graph) do
    app_set = MapSet.new(graph.apps)

    Enum.reduce_while(files, {:ok, MapSet.new(), false}, fn path, {:ok, apps, root_wide} ->
      cond do
        root_wide_path?(path) ->
          {:cont, {:ok, apps, true}}

        true ->
          case app_dir_from_path(path) do
            {:ok, app} ->
              if MapSet.member?(app_set, app) do
                {:cont, {:ok, MapSet.put(apps, app), root_wide}}
              else
                # Changed path under apps/<unknown>/ — fail closed unless the
                # path is merely an untracked junk file outside known apps.
                # Known-app directories are the only authority for selection.
                {:halt, {:error, {:changed_unknown_app, app}}}
              end

            :not_app_path ->
              # docs, scripts, etc. — do not widen
              {:cont, {:ok, apps, root_wide}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, apps, root_wide} ->
        {:ok, apps |> MapSet.to_list() |> Enum.sort(), root_wide}

      {:error, _} = error ->
        error
    end
  end

  defp downstream_closure(seeds, depended_by) do
    seeds = MapSet.new(seeds)

    expand = fn
      expand_fun, frontier, seen ->
        next =
          frontier
          |> Enum.flat_map(fn app -> Map.get(depended_by, app, []) end)
          |> Enum.reject(&MapSet.member?(seen, &1))

        if next == [] do
          seen
        else
          next_set = MapSet.new(next)
          expand_fun.(expand_fun, next, MapSet.union(seen, next_set))
        end
    end

    seeds
    |> then(fn s -> expand.(expand, MapSet.to_list(s), s) end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp valid_identifier?(name)
       when is_binary(name) and name != "" and byte_size(name) <= @max_identifier_bytes do
    String.match?(name, ~r/^[a-z][a-z0-9_]*$/)
  end

  defp valid_identifier?(_), do: false

  defp overall_reason(true, _compile, _xref, _test), do: "cross_app_validated"

  defp overall_reason(false, compile, xref, test) do
    cond do
      check_failed?(compile) -> check_reason(compile, "compile_failed")
      check_failed?(xref) -> check_reason(xref, "xref_failed")
      check_failed?(test) -> check_reason(test, "tests_failed")
      true -> "validation_failed"
    end
  end

  defp check_failed?(check) do
    passed = Map.get(check, :passed) || Map.get(check, "passed")
    passed != true
  end

  defp check_reason(check, default) do
    Map.get(check, :reason) || Map.get(check, "reason") || default
  end

  defp normalize_check(check) when is_map(check) do
    %{
      "status" =>
        to_string_value(Map.get(check, :status) || Map.get(check, "status") || "unknown"),
      "passed" => Map.get(check, :passed) || Map.get(check, "passed") || false,
      "exit_code" => Map.get(check, :exit_code) || Map.get(check, "exit_code"),
      "reason" => Map.get(check, :reason) || Map.get(check, "reason"),
      "stdout_excerpt" =>
        json_safe_utf8(Map.get(check, :stdout_excerpt) || Map.get(check, "stdout_excerpt") || ""),
      "stderr_excerpt" =>
        json_safe_utf8(Map.get(check, :stderr_excerpt) || Map.get(check, "stderr_excerpt") || ""),
      "stdout_truncated" =>
        Map.get(check, :stdout_truncated) || Map.get(check, "stdout_truncated") || false,
      "stderr_truncated" =>
        Map.get(check, :stderr_truncated) || Map.get(check, "stderr_truncated") || false,
      "stdout_sha256" =>
        Map.get(check, :stdout_sha256) || Map.get(check, "stdout_sha256") || sha256(""),
      "stderr_sha256" =>
        Map.get(check, :stderr_sha256) || Map.get(check, "stderr_sha256") || sha256("")
    }
  end

  defp normalize_check(_), do: skipped_check("missing_check")

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: inspect(value)

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp sha256(output) when is_binary(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
