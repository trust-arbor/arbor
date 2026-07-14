defmodule Arbor.Actions.Mix do
  @moduledoc """
  Elixir `mix` task operations as Jido actions.

  Each action wraps a specific `mix` task (`test`, `quality`, `format`) as a
  capability-distinct operation rather than letting agents reach for raw
  `Shell.Execute`. The win is granularity: an agent granted
  `arbor://action/mix/test` can run tests but cannot run `mix deps.update`,
  whereas raw shell access would conflate them.

  In production, all actions execute through `Arbor.Shell` with `:basic`
  sandboxing and emit `Arbor.Signals` events for observability. Shell's
  spawn-capable path currently fails closed until a production streaming
  handle/control plane can provide synchronous teardown receipts.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Compile` | Run `mix compile` (optionally with warnings-as-errors) |
  | `Test` | Run `mix test` (optionally with paths/args) |
  | `Quality` | Run `mix quality` (format-check + credo) |
  | `Format` | Run `mix format` (write or check-only) |

  ## Examples

      {:ok, result} = Arbor.Actions.Mix.Test.run(%{path: "/path/to/project"}, %{})
      result.exit_code  # => 0
      result.passed    # => true

      {:ok, result} = Arbor.Actions.Mix.Quality.run(%{path: "/path/to/project"}, %{})
      result.passed    # => false (format issues found)
  """

  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Config
  alias Arbor.Common.SafePath

  @compile_feedback_text_limit 2_000
  @excerpt_omission_marker "\n...[omitted]...\n"
  # Byte ceiling for operation_outcome retained inside cleanup-failure errors.
  # inspect limit/printable_limit alone does not bound nested term size.
  @cleanup_diagnostic_byte_limit 2_048
  @cleanup_diagnostic_term_depth 4
  @cleanup_diagnostic_list_limit 16
  @cleanup_diagnostic_scalar_bit_limit 256
  @cleanup_diagnostic_binary_byte_limit 256
  # Dependency snapshot / projection setup bounds (Slice 1).
  @snapshot_max_entries 50_000
  @snapshot_max_bytes 512 * 1024 * 1024
  @snapshot_max_depth 48

  # Path-bearing / code-loading Mix variables are module-owned under contained
  # execution. Caller opts and ambient Application env never become wrapper or
  # root authority; they are scrubbed after resource/runtime env is built.
  @module_owned_env_keys ~w(
    HOME
    TMPDIR
    TMP
    TEMP
    MIX_HOME
    MIX_ARCHIVES
    HEX_HOME
    MIX_BUILD_PATH
    MIX_BUILD_ROOT
    MIX_DEPS_PATH
    ERL_LIBS
    REBAR_CACHE_DIR
    ARBOR_MIX_CONTAINED
    ARBOR_ERLANG_ROOT
    ARBOR_ELIXIR_ROOT
    PATH
  )

  # Narrow safe surface callers may still influence (trusted validation only).
  @safe_caller_env_keys MapSet.new(["MIX_ENV"])

  @doc false
  def mix_timeout, do: 300_000
  @doc false
  def mix_sandbox, do: :basic

  @doc false
  def compile_feedback_text_limit, do: @compile_feedback_text_limit

  @doc false
  def module_owned_env_keys, do: @module_owned_env_keys

  @doc false
  def safe_caller_env_keys, do: MapSet.to_list(@safe_caller_env_keys)

  @doc false
  def cleanup_diagnostic_byte_limit, do: @cleanup_diagnostic_byte_limit

  @doc false
  def snapshot_bounds do
    %{
      max_entries: @snapshot_max_entries,
      max_bytes: @snapshot_max_bytes,
      max_depth: @snapshot_max_depth
    }
  end

  @doc false
  def compile_feedback(%{exit_code: exit_code, stdout: stdout, stderr: stderr}) do
    stdout = stdout || ""
    stderr = stderr || ""

    %{
      "exit_code" => exit_code,
      "passed" => exit_code == 0,
      "stdout_excerpt" => bounded_excerpt(stdout),
      "stderr_excerpt" => bounded_excerpt(stderr),
      "stdout_truncated" => String.length(stdout) > @compile_feedback_text_limit,
      "stderr_truncated" => String.length(stderr) > @compile_feedback_text_limit,
      "stdout_sha256" => sha256(stdout),
      "stderr_sha256" => sha256(stderr)
    }
  end

  defp bounded_excerpt(text) do
    if String.length(text) <= @compile_feedback_text_limit do
      text
    else
      available = @compile_feedback_text_limit - String.length(@excerpt_omission_marker)
      head_length = div(available, 2)
      tail_length = available - head_length

      String.slice(text, 0, head_length) <>
        @excerpt_omission_marker <>
        String.slice(text, -tail_length, tail_length)
    end
  end

  defp sha256(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end

  # ── Closed wrapper + runtime roots ────────────────────────────────

  @doc """
  Resolve the repository-local `./bin/mix` wrapper from trusted Arbor code
  roots already loaded in this BEAM.

  Authority is only loaded application/module code roots that resolve to a
  source umbrella layout (`mix.exs` + `apps/` + executable `bin/mix`).
  `File.cwd/0`, Application env, task/DOT input, candidate Git metadata, and
  caller opts are never consulted. Release packaging of a reviewed wrapper is
  not claimed yet — fail closed until Slice 2 bundles one.
  """
  @spec resolve_mix_wrapper() :: {:ok, String.t()} | {:error, term()}
  def resolve_mix_wrapper do
    resolve_mix_wrapper_from_anchors(code_root_anchors())
  end

  @doc false
  # Test seam: supply explicit anchors; never accepts Application env authority.
  @spec resolve_mix_wrapper_from_anchors([String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_mix_wrapper_from_anchors(anchors) when is_list(anchors) do
    anchors
    |> Enum.flat_map(&ancestor_paths/1)
    |> Enum.uniq()
    |> Enum.find_value(fn root ->
      case verify_wrapper_at(root) do
        {:ok, wrapper} -> {:ok, wrapper}
        {:error, _} -> nil
      end
    end)
    |> case do
      {:ok, wrapper} -> {:ok, wrapper}
      nil -> {:error, :mix_wrapper_unavailable}
    end
  end

  @doc """
  Canonical Erlang and Elixir installation roots derived from the already-loaded
  BEAM runtime. Never caller-controlled.
  """
  @spec runtime_roots() ::
          {:ok, %{erlang_root: String.t(), elixir_root: String.t()}} | {:error, term()}
  def runtime_roots do
    with {:ok, erlang_root} <- resolve_erlang_root(),
         {:ok, elixir_root} <- resolve_elixir_root() do
      {:ok, %{erlang_root: erlang_root, elixir_root: elixir_root}}
    end
  end

  # ── Validation resource helper ────────────────────────────────────

  @doc """
  Acquire exactly one owner-scoped validation resource for `workspace_id`, run
  `fun` with the public resource view, and release on success, error, raise, or
  throw.

  Cleanup is enforcing on ordinary returns: a release failure becomes
  `{:error, {:validation_resource_cleanup_failed, ...}}` and never reports
  validation success. Raise/throw/exit attempt cleanup exactly once then
  re-raise; retained cleanup failures are discoverable via
  `last_validation_cleanup_failure/0`.
  """
  @spec with_validation_resource(String.t(), map(), (map() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_validation_resource(workspace_id, context, fun)
      when is_binary(workspace_id) and is_map(context) and is_function(fun, 1) do
    with_validation_resource(workspace_id, context, fun, [])
  end

  def with_validation_resource(_workspace_id, _context, _fun),
    do: {:error, :invalid_validation_resource_request}

  @spec with_validation_resource(String.t(), map(), (map() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def with_validation_resource(workspace_id, context, fun, opts)
      when is_binary(workspace_id) and is_map(context) and is_function(fun, 1) and is_list(opts) do
    Process.delete({__MODULE__, :last_validation_cleanup_failure})
    caller = validation_caller(context)
    timeout = Keyword.get(opts, :timeout, mix_timeout())
    deadline_ms = Keyword.get(opts, :deadline_ms) || absolute_deadline(timeout)

    case remaining_timeout(deadline_ms) do
      {:error, _} = error ->
        error

      {:ok, _remaining} ->
        acquire_opts =
          caller
          |> Map.put(:deadline_ms, deadline_ms)
          |> Map.put(:snapshot_bounds, snapshot_bounds())

        case WorkspaceLeaseRegistry.acquire_validation_resource(workspace_id, acquire_opts) do
          {:ok, resource} ->
            outcome =
              try do
                case remaining_timeout(deadline_ms) do
                  {:ok, _} ->
                    {:return, fun.(resource)}

                  {:error, reason} ->
                    {:return, {:error, reason}}
                end
              rescue
                error ->
                  {:raise, error, __STACKTRACE__}
              catch
                :throw, value ->
                  {:throw, value}

                :exit, reason ->
                  {:exit, reason}
              end

            # Cleanup remains bounded and is attempted even after deadline expiry.
            cleanup =
              WorkspaceLeaseRegistry.release_validation_resource(resource.resource_id, caller)

            settle_validation_outcome(outcome, cleanup, resource.resource_id)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def with_validation_resource(_workspace_id, _context, _fun, _opts),
    do: {:error, :invalid_validation_resource_request}

  @doc false
  def last_validation_cleanup_failure do
    Process.get({__MODULE__, :last_validation_cleanup_failure})
  end

  defp settle_validation_outcome({:return, result}, cleanup, resource_id) do
    case cleanup do
      {:ok, _} ->
        result

      {:error, reason} ->
        diagnostic = bound_cleanup_diagnostic(result)

        {:error,
         {:validation_resource_cleanup_failed,
          %{
            resource_id: resource_id,
            cleanup_reason: reason,
            operation_outcome: diagnostic
          }}}
    end
  end

  defp settle_validation_outcome({:raise, error, stack}, cleanup, resource_id) do
    record_cleanup_if_failed(cleanup, resource_id, :raise)
    reraise error, stack
  end

  defp settle_validation_outcome({:throw, value}, cleanup, resource_id) do
    record_cleanup_if_failed(cleanup, resource_id, :throw)
    throw(value)
  end

  defp settle_validation_outcome({:exit, reason}, cleanup, resource_id) do
    record_cleanup_if_failed(cleanup, resource_id, :exit)
    exit(reason)
  end

  defp record_cleanup_if_failed({:ok, _}, _resource_id, _kind), do: :ok

  defp record_cleanup_if_failed({:error, reason}, resource_id, kind) do
    Process.put(
      {__MODULE__, :last_validation_cleanup_failure},
      %{resource_id: resource_id, reason: reason, during: kind}
    )

    :ok
  end

  @doc false
  # Total, non-raising diagnostic formatter for cleanup failure payloads.
  def bound_cleanup_diagnostic(result) do
    try do
      result
      |> bound_diagnostic_term(@cleanup_diagnostic_term_depth)
      |> safe_inspect_diagnostic()
      |> truncate_bytes_raw(@cleanup_diagnostic_byte_limit)
    rescue
      _ -> ":truncated"
    catch
      _, _ -> ":truncated"
    end
  end

  defp safe_inspect_diagnostic(term) do
    inspect(term,
      limit: @cleanup_diagnostic_list_limit,
      printable_limit: @cleanup_diagnostic_binary_byte_limit,
      pretty: false,
      structs: false
    )
  rescue
    _ -> ":truncated"
  end

  # Total walker: never raises, never follows improper lists unbounded, never
  # materializes huge integers as full decimal strings.
  defp bound_diagnostic_term(term, depth) when depth <= 0 do
    cond do
      is_binary(term) -> truncate_bytes_raw(term, 64)
      is_atom(term) -> term
      is_boolean(term) or is_nil(term) -> term
      is_integer(term) -> bound_integer(term)
      is_float(term) -> term
      true -> :truncated
    end
  end

  defp bound_diagnostic_term(term, _depth) when is_binary(term) do
    truncate_bytes_raw(term, @cleanup_diagnostic_binary_byte_limit)
  end

  defp bound_diagnostic_term(term, _depth) when is_atom(term), do: term
  defp bound_diagnostic_term(term, _depth) when is_boolean(term) or is_nil(term), do: term
  defp bound_diagnostic_term(term, _depth) when is_float(term), do: term
  defp bound_diagnostic_term(term, _depth) when is_integer(term), do: bound_integer(term)

  defp bound_diagnostic_term(term, depth) when is_list(term) do
    take_list_prefix(term, @cleanup_diagnostic_list_limit, depth, 0, [])
  rescue
    _ -> :truncated
  end

  defp bound_diagnostic_term(%{} = term, depth) do
    # Structs and maps: walk at most N pairs without relying on full Enum.
    {taken, count} =
      Enum.reduce_while(term, {[], 0}, fn {k, v}, {acc, n} ->
        if n >= @cleanup_diagnostic_list_limit do
          {:halt, {acc, n + 1}}
        else
          entry = {
            bound_diagnostic_term(k, depth - 1),
            bound_diagnostic_term(v, depth - 1)
          }

          {:cont, {[entry | acc], n + 1}}
        end
      end)

    base = Map.new(Enum.reverse(taken))

    if count > @cleanup_diagnostic_list_limit do
      Map.put(base, :truncated, true)
    else
      base
    end
  rescue
    _ -> :truncated
  end

  defp bound_diagnostic_term(term, depth) when is_tuple(term) do
    size = tuple_size(term)
    limit = min(size, @cleanup_diagnostic_list_limit)

    elements =
      for i <- 0..(limit - 1)//1 do
        bound_diagnostic_term(elem(term, i), depth - 1)
      end

    if size > limit do
      List.to_tuple(elements ++ [:truncated])
    else
      List.to_tuple(elements)
    end
  rescue
    _ -> :truncated
  end

  defp bound_diagnostic_term(term, _depth)
       when is_pid(term) or is_reference(term) or is_function(term) or is_port(term) do
    :truncated
  end

  defp bound_diagnostic_term(_term, _depth), do: :truncated

  defp take_list_prefix([], _limit, _depth, _n, acc), do: Enum.reverse(acc)

  defp take_list_prefix([head | tail], limit, depth, n, acc) when n < limit do
    take_list_prefix(
      tail,
      limit,
      depth,
      n + 1,
      [bound_diagnostic_term(head, depth - 1) | acc]
    )
  end

  defp take_list_prefix([_head | _tail], _limit, _depth, _n, acc) do
    Enum.reverse([:truncated | acc])
  end

  # Improper list tail (not a list): stop without raising.
  defp take_list_prefix(improper_tail, _limit, depth, _n, acc) do
    Enum.reverse([
      {:improper_tail, bound_diagnostic_term(improper_tail, depth - 1)} | acc
    ])
  end

  # Bit-size without allocating a binary proportional to the integer magnitude.
  defp bound_integer(n) when is_integer(n) do
    bits = integer_bit_length(n)

    if bits <= @cleanup_diagnostic_scalar_bit_limit do
      n
    else
      {:truncated_integer, bits}
    end
  rescue
    _ -> :truncated
  end

  defp integer_bit_length(n) when n < 0, do: integer_bit_length(-n) + 1
  defp integer_bit_length(0), do: 1

  defp integer_bit_length(n) when is_integer(n) and n > 0 do
    integer_bit_length_loop(n, 0)
  end

  defp integer_bit_length_loop(0, acc), do: acc

  defp integer_bit_length_loop(_n, acc) when acc > @cleanup_diagnostic_scalar_bit_limit * 4 do
    # Early exit — already far past the retain threshold; avoid long loops on
    # pathological bignums beyond what we need for classification.
    acc
  end

  defp integer_bit_length_loop(n, acc) do
    integer_bit_length_loop(Bitwise.bsr(n, 1), acc + 1)
  end

  # Byte-bounded truncation that never raises on invalid UTF-8.
  defp truncate_bytes_raw(binary, max_bytes)
       when is_binary(binary) and is_integer(max_bytes) and max_bytes >= 0 do
    size = byte_size(binary)

    cond do
      size <= max_bytes ->
        if String.valid?(binary), do: binary, else: sanitize_binary(binary, size)

      max_bytes <= 0 ->
        ""

      true ->
        part = binary_part(binary, 0, max_bytes)
        if String.valid?(part), do: part, else: sanitize_binary(part, max_bytes)
    end
  rescue
    _ -> ""
  end

  defp truncate_bytes_raw(_other, _max_bytes), do: ":truncated"

  defp sanitize_binary(binary, max_bytes) when is_binary(binary) do
    # Drop trailing incomplete UTF-8 sequence without raising.
    take_valid_prefix(binary, max_bytes)
  rescue
    _ -> ""
  end

  defp take_valid_prefix(_binary, max_bytes) when max_bytes <= 0, do: ""

  defp take_valid_prefix(binary, max_bytes) do
    part = binary_part(binary, 0, min(byte_size(binary), max_bytes))

    case :unicode.characters_to_binary(part, :utf8, :utf8) do
      bin when is_binary(bin) ->
        bin

      {:incomplete, incomplete, _rest} when is_binary(incomplete) ->
        incomplete

      {:error, good, _rest} when is_binary(good) ->
        good

      _ ->
        if max_bytes > 1, do: take_valid_prefix(binary, max_bytes - 1), else: ""
    end
  rescue
    _ -> ""
  end

  @doc """
  Build typed filesystem projections for a validation resource and revision.

  Read-only projections cover trusted runtime roots and the closed Mix wrapper.
  Read-write projections are revision-private only — never the validation root,
  never the opposite revision, never shared staged evidence.

  The revision runtime parent (`candidate_runtime_path` / `base_runtime_path`)
  remains lifecycle/cleanup ownership only: it is never projected. Guest mounts
  receive the typed children (home, tmp, build) plus worktree and deps, so
  Actions-owned runner/result artifacts under the runtime parent stay unmounted.
  """
  @spec projections_for_resource(map()) ::
          {:ok, %{read_only: [map()], read_write: [map()], revision: String.t()}}
          | {:error, term()}
  def projections_for_resource(resource) when is_map(resource) do
    projections_for_resource(resource, :candidate)
  end

  def projections_for_resource(_), do: {:error, :invalid_validation_resource}

  @spec projections_for_resource(map(), :candidate | :base) ::
          {:ok, %{read_only: [map()], read_write: [map()], revision: String.t()}}
          | {:error, term()}
  def projections_for_resource(resource, revision)
      when is_map(resource) and revision in [:candidate, :base] do
    with {:ok, wrapper} <- resolve_mix_wrapper(),
         {:ok, roots} <- runtime_roots(),
         {:ok, paths} <- revision_private_paths(resource, revision) do
      read_only = [
        projection(roots.erlang_root, :read_only, :runtime_erlang),
        projection(roots.elixir_root, :read_only, :runtime_elixir),
        projection(wrapper, :read_only, :mix_wrapper)
      ]

      # Never project the runtime parent: it owns runner/result plus home/tmp/build.
      # Mount only the typed children and worktree/deps so guest code cannot reach
      # Actions-owned artifacts or create ancestor/descendant mount overlap.
      read_write =
        [
          {paths.worktree_path, :worktree},
          {paths.home_path, :home},
          {paths.tmp_path, :tmp},
          {paths.build_path, :build},
          {paths.deps_path, :deps}
        ]
        |> Enum.reject(fn {path, _} -> is_nil(path) or path == "" end)
        |> Enum.map(fn {path, purpose} -> projection(path, :read_write, purpose) end)

      {:ok, %{read_only: read_only, read_write: read_write, revision: Atom.to_string(revision)}}
    end
  end

  def projections_for_resource(_, _), do: {:error, :invalid_validation_resource}

  @doc """
  Build the module-owned contained Mix environment from a live validation
  resource.

  Path-bearing keys always come from the resource and runtime roots. Caller
  `env` may only contribute `MIX_ENV`. Returns only resource-backed live paths;
  without a validation resource this fails closed with
  `:validation_resource_required` (ephemeral trees are owned privately by
  `run_mix/3` for a single invocation).
  """
  @spec contained_mix_env(keyword()) :: {:ok, map()} | {:error, term()}
  def contained_mix_env(opts \\ []) when is_list(opts) do
    resource = Keyword.get(opts, :validation_resource)

    if is_map(resource) do
      case contained_mix_env_owned(opts) do
        {:ok, env, nil} ->
          {:ok, env}

        {:ok, _env, ephemeral_root} when is_binary(ephemeral_root) ->
          cleanup_ephemeral_root(ephemeral_root)
          {:error, :validation_resource_required}

        other ->
          other
      end
    else
      {:error, :validation_resource_required}
    end
  end

  # Private: may allocate an ephemeral private tree for one `run_mix/3` call.
  # Caller must cleanup `ephemeral_root` when non-nil.
  defp contained_mix_env_owned(opts) when is_list(opts) do
    revision = Keyword.get(opts, :validation_revision, :candidate)
    resource = Keyword.get(opts, :validation_resource)
    project_path = Keyword.get(opts, :project_path)

    with {:ok, roots} <- runtime_roots(),
         {:ok, resource_paths, ephemeral_root} <-
           resource_env_paths(resource, revision, project_path) do
      safe_caller = scrub_caller_env(Keyword.get(opts, :env, %{}))
      defaults = Keyword.get(opts, :default_env, %{})

      env =
        %{}
        |> Map.merge(scrub_caller_env(defaults))
        |> Map.merge(safe_caller)
        |> then(&enforce_module_owned_keys(&1, roots, resource_paths))

      {:ok, env, ephemeral_root}
    end
  end

  # ── Shared command runner ─────────────────────────────────────────

  @doc false
  @spec run_mix(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, String.t() | Config.mix_shell_module_error() | term()}
  def run_mix(path, args, opts \\ []) do
    resource = Keyword.get(opts, :validation_resource)

    # Production path: owner-issued validation resource + typed projections are
    # mandatory. No ephemeral no-workspace bypass.
    if is_nil(resource) or not is_map(resource) do
      {:error, :validation_resource_required}
    else
      do_run_mix(path, args, opts)
    end
  end

  defp do_run_mix(path, args, opts) do
    timeout = Keyword.get(opts, :timeout, mix_timeout())
    deadline_ms = Keyword.get(opts, :deadline_ms) || absolute_deadline(timeout)
    resource = Keyword.get(opts, :validation_resource)
    revision = Keyword.get(opts, :validation_revision, :candidate)
    bind_tree? = Keyword.get(opts, :bind_committable_tree, true)

    opts =
      opts
      |> Keyword.put(:validation_resource, resource)
      |> Keyword.put(:validation_revision, revision)
      |> Keyword.put(:default_env, default_mix_env(args))
      |> Keyword.put(:deadline_ms, deadline_ms)

    case remaining_timeout(deadline_ms) do
      {:error, reason} ->
        {:error, reason}

      {:ok, remaining} ->
        case prepare_mix_invocation(path, opts) do
          {:ok, prepared} ->
            execute_prepared_mix(prepared, args, remaining, deadline_ms, bind_tree?)

          {:error, reason, ephemeral_root} ->
            settle_ephemeral_cleanup({:error, reason}, ephemeral_root)

          {:error, reason} ->
            format_prepare_error(reason)
        end
    end
  end

  defp execute_prepared_mix(prepared, args, remaining, deadline_ms, bind_tree?) do
    try do
      with {:ok, _} <- remaining_timeout(deadline_ms),
           {:ok, before_binding} <-
             maybe_tree_binding(prepared.cwd, bind_tree?, deadline_ms),
           {:ok, rem_after_bind} <- remaining_timeout(deadline_ms),
           {:ok, result} <-
             invoke_spawn_capable(prepared, args, min(remaining, rem_after_bind)),
           {:ok, after_binding} <-
             maybe_tree_binding(prepared.cwd, bind_tree?, deadline_ms),
           :ok <- assert_tree_stable(before_binding, after_binding) do
        result =
          if is_map(before_binding) do
            result
            |> Map.put(:validated_tree_oid, before_binding.tree_oid)
            |> Map.put(:validated_head, before_binding.head)
          else
            result
          end

        settle_ephemeral_cleanup({:ok, result}, prepared.ephemeral_root)
      else
        {:error, reason} ->
          settle_ephemeral_cleanup({:error, reason}, prepared.ephemeral_root)
      end
    rescue
      error ->
        _ = settle_ephemeral_cleanup({:error, :mix_execution_crashed}, prepared.ephemeral_root)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        _ = settle_ephemeral_cleanup({:error, :mix_execution_crashed}, prepared.ephemeral_root)

        case kind do
          :throw -> throw(reason)
          :exit -> exit(reason)
        end
    end
  end

  defp invoke_spawn_capable(prepared, args, remaining) do
    shell_opts =
      [
        cwd: prepared.cwd,
        timeout: remaining,
        sandbox: mix_sandbox(),
        env: prepared.env,
        clear_env: true,
        filesystem_projections: prepared.projections
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case prepared.shell_module.execute_spawn_capable(prepared.wrapper, args, shell_opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp prepare_mix_invocation(path, opts) do
    resource = Keyword.get(opts, :validation_resource)
    revision = Keyword.get(opts, :validation_revision, :candidate)
    deadline_ms = Keyword.get(opts, :deadline_ms)

    with {:ok, _} <- remaining_timeout(deadline_ms),
         {:ok, canonical_path} <- SafePath.resolve_real(path),
         true <- File.dir?(canonical_path) || {:error, :invalid_mix_worktree},
         :ok <- bind_cwd_to_revision(resource, revision, canonical_path),
         {:ok, wrapper} <- resolve_mix_wrapper(),
         {:ok, _} <- remaining_timeout(deadline_ms) do
      case build_contained_env(canonical_path, opts) do
        {:ok, env, ephemeral_root} ->
          case remaining_timeout(deadline_ms) do
            {:ok, _} ->
              finish_prepare(canonical_path, wrapper, env, ephemeral_root, resource, revision)

            {:error, reason} ->
              {:error, reason, ephemeral_root}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_mix_worktree}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp finish_prepare(cwd, wrapper, env, ephemeral_root, resource, revision) do
    with {:ok, projections} <- require_projections(resource, revision),
         {:ok, shell_module} <- Config.mix_shell_module() do
      {:ok,
       %{
         cwd: cwd,
         wrapper: wrapper,
         env: env,
         projections: projections,
         shell_module: shell_module,
         ephemeral_root: ephemeral_root
       }}
    else
      {:error, reason} ->
        {:error, reason, ephemeral_root}

      other ->
        {:error, other, ephemeral_root}
    end
  end

  defp build_contained_env(project_path, opts) do
    # Always require a live validation resource — never allocate a production
    # ephemeral execution root for project code.
    resource = Keyword.get(opts, :validation_resource)

    if is_map(resource) do
      case contained_mix_env_owned(Keyword.put(opts, :project_path, project_path)) do
        {:ok, env, nil} ->
          {:ok, env, nil}

        {:ok, _env, ephemeral_root} when is_binary(ephemeral_root) ->
          case cleanup_ephemeral_root(ephemeral_root) do
            :ok -> {:error, :validation_resource_required}
            {:error, reason} -> {:error, {:ephemeral_cleanup_failed, reason}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :validation_resource_required}
    end
  end

  defp format_prepare_error({:invalid_mix_shell_module, _} = error), do: {:error, error}
  defp format_prepare_error(reason) when is_binary(reason), do: {:error, reason}
  defp format_prepare_error(reason), do: {:error, inspect(reason)}

  # Enforcing cleanup: never ignore File.rm_rf outcomes.
  defp cleanup_ephemeral_root(nil), do: :ok

  defp cleanup_ephemeral_root(root) when is_binary(root) do
    case File.rm_rf(root) do
      {:ok, _paths} ->
        if File.exists?(root) do
          {:error, {:ephemeral_root_still_present, root}}
        else
          :ok
        end

      {:error, reason, _paths} ->
        {:error, {:ephemeral_rm_rf_failed, reason}}
    end
  rescue
    error ->
      {:error, {:ephemeral_cleanup_raised, Exception.message(error)}}
  end

  defp settle_ephemeral_cleanup(result, nil), do: normalize_mix_result(result)

  defp settle_ephemeral_cleanup(result, ephemeral_root) when is_binary(ephemeral_root) do
    case cleanup_ephemeral_root(ephemeral_root) do
      :ok ->
        normalize_mix_result(result)

      {:error, cleanup_reason} ->
        diagnostic = bound_cleanup_diagnostic(result)

        {:error,
         {:ephemeral_cleanup_failed,
          %{
            cleanup_reason: cleanup_reason,
            ephemeral_root: ephemeral_root,
            operation_outcome: diagnostic
          }}}
    end
  end

  defp normalize_mix_result({:ok, _} = ok), do: ok
  defp normalize_mix_result({:error, reason}), do: format_prepare_error(reason)
  defp normalize_mix_result(other), do: format_prepare_error(other)

  defp bind_cwd_to_revision(nil, _revision, _cwd), do: {:error, :validation_resource_required}

  defp bind_cwd_to_revision(resource, revision, cwd) when is_map(resource) do
    with {:ok, paths} <- revision_private_paths(resource, revision),
         {:ok, expected} <- SafePath.resolve_real(paths.worktree_path),
         true <- expected == cwd do
      :ok
    else
      false -> {:error, :cwd_not_bound_to_validation_revision}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :cwd_not_bound_to_validation_revision}
    end
  end

  @doc """
  Capture a Git binding for the exact committable tree at `worktree_path`.

  Builds the tree in a private temporary `GIT_DIR` / index with no
  local/global/system config, no hooks, no fsmonitor, and **no clean filters**.
  Regular file bytes are copied in bounded chunks from a validated source
  descriptor into an invocation-private staging file, then hashed with
  `git hash-object --no-filters` against that private copy — never
  `File.read/1` of untrusted content and never `git add` against the
  candidate worktree (which would run project-controlled filters/helpers).

  Includes tracked content plus non-ignored untracked content — the same set
  Git would stage with `add -A` excluding only content Git itself would not
  commit. Returns `%{head: oid, tree_oid: oid}`.

  Cumulative entry / byte / depth bounds from `snapshot_bounds/0` (or
  overriding opts) are enforced before unbounded allocation or hashing.

  Every git invocation uses `Arbor.Shell.execute_direct/3` (bounded childless
  structured argv) under the absolute operation deadline.
  """
  @spec committable_tree_binding(String.t()) :: {:ok, map()} | {:error, term()}
  def committable_tree_binding(worktree_path) when is_binary(worktree_path) do
    committable_tree_binding(worktree_path, [])
  end

  @spec committable_tree_binding(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def committable_tree_binding(worktree_path, opts)
      when is_binary(worktree_path) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, mix_timeout())
    deadline_ms = Keyword.get(opts, :deadline_ms) || absolute_deadline(timeout)

    with {:ok, _} <- remaining_timeout(deadline_ms),
         {:ok, canonical} <- SafePath.resolve_real(worktree_path),
         true <- File.dir?(canonical) || {:error, :invalid_worktree},
         {:ok, git_dir} <- resolve_git_common_dir(canonical, deadline_ms) do
      do_committable_tree_binding(canonical, git_dir, deadline_ms, opts)
    else
      false -> {:error, :invalid_worktree}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :committable_tree_binding_failed}
    end
  end

  def committable_tree_binding(_, _), do: {:error, :invalid_worktree}

  @doc """
  Resolve the tree OID of an existing commit object without reading the
  mutable worktree. Used to verify a completed commit matches the
  pre-validation binding.
  """
  @spec commit_tree_oid(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_tree_oid(repo_or_worktree, commit_oid, opts \\ [])

  def commit_tree_oid(repo_or_worktree, commit_oid, opts)
      when is_binary(repo_or_worktree) and is_binary(commit_oid) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, mix_timeout())
    deadline_ms = Keyword.get(opts, :deadline_ms) || absolute_deadline(timeout)

    with {:ok, _} <- remaining_timeout(deadline_ms),
         {:ok, path} <- SafePath.resolve_real(repo_or_worktree),
         {:ok, git_dir} <- resolve_git_common_dir(path, deadline_ms),
         true <- Regex.match?(~r/\A[0-9a-f]{7,64}\z/, commit_oid),
         {:ok, tree} <-
           git_direct(
             ["--git-dir", git_dir, "rev-parse", commit_oid <> "^{tree}"],
             deadline_ms
           ) do
      tree = String.trim(tree)

      if Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, tree) do
        {:ok, tree}
      else
        {:error, :commit_tree_oid_failed}
      end
    else
      false -> {:error, :invalid_commit_oid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :commit_tree_oid_failed}
    end
  end

  def commit_tree_oid(_, _, _), do: {:error, :invalid_commit_oid}

  defp do_committable_tree_binding(worktree, git_dir, deadline_ms, opts) do
    token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # Fail closed if the temp root cannot be proven via SafePath — never fall
    # back to an unresolved System.tmp_dir! path.
    case SafePath.resolve_real(System.tmp_dir!()) do
      {:ok, tmp} ->
        private_root = Path.join(tmp, "arbor-tree-bind-#{token}")
        private_git = Path.join(private_root, "git")
        private_index = Path.join(private_root, "index")
        private_stage = Path.join(private_root, "stage")
        budget = tree_binding_budget(opts)

        # Observer may pre-create the path (test seam). Exclusive mkdir must
        # not grant cleanup ownership on collision.
        maybe_observe_tree_binding_root(private_root)

        case File.mkdir(private_root) do
          {:error, :eexist} ->
            # Exclusive-create failure never grants cleanup ownership: do not
            # chmod, mutate, or delete the pre-existing path.
            {:error, :tree_binding_root_exists}

          {:error, reason} ->
            {:error, {:tree_binding_root_create_failed, reason}}

          :ok ->
            # Ownership is usable only after its initial identity is captured.
            # A later observation cannot prove that the path still names the
            # directory created by this invocation.
            case capture_binding_root_identity(private_root) do
              {:ok, root_identity} ->
                run_owned_tree_binding(
                  private_root,
                  root_identity,
                  private_git,
                  private_index,
                  private_stage,
                  worktree,
                  git_dir,
                  deadline_ms,
                  budget
                )

              {:error, reason} ->
                {:error, {:tree_binding_root_identity_unproven, bound_cleanup_diagnostic(reason)}}
            end
        end

      {:error, reason} ->
        {:error, {:tree_binding_tmp_unproven, bound_cleanup_diagnostic(reason)}}

      other ->
        {:error, {:tree_binding_tmp_unproven, bound_cleanup_diagnostic(other)}}
    end
  end

  # Private root was created by this invocation. Capture directory identity
  # (device/inode/type) immediately, finish setup + binding work, then clean
  # up only if the same directory identity is still at the path.
  #
  # Residual race: Elixir/Erlang File APIs do not expose openat(2). Between
  # the pre-rm_rf identity verification and the path-based File.rm_rf/1 a
  # concurrent renamer can still swap the directory; identity recheck reduces
  # but cannot eliminate that window without openat-style removal.
  defp run_owned_tree_binding(
         private_root,
         root_identity,
         private_git,
         private_index,
         private_stage,
         worktree,
         git_dir,
         deadline_ms,
         budget
       ) do
    outcome =
      try do
        with :ok <- finalize_owned_binding_root_children(private_root, private_git, private_stage),
             {:ok, _} <- remaining_timeout(deadline_ms),
             {:ok, _} <-
               git_direct(["init", "--bare", private_git], deadline_ms),
             # Resolve the *candidate worktree* HEAD. Using --git-dir with the
             # common dir returns the main worktree's HEAD for linked worktrees.
             # Keep common-dir (git_dir) only for object lookups elsewhere.
             {:ok, head} <-
               git_direct(["-C", worktree, "rev-parse", "HEAD"], deadline_ms),
             {:ok, paths} <- list_committable_paths(git_dir, worktree, deadline_ms, budget),
             :ok <-
               stage_committable_paths(
                 private_git,
                 private_index,
                 private_stage,
                 worktree,
                 paths,
                 deadline_ms,
                 budget
               ),
             {:ok, tree} <-
               git_direct(
                 ["--git-dir", private_git, "write-tree"],
                 deadline_ms,
                 [{"GIT_INDEX_FILE", private_index}]
               ) do
          {:ok,
           %{
             head: String.trim(head),
             tree_oid: String.trim(tree)
           }}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :committable_tree_binding_failed}
        end
      rescue
        error ->
          {:error, {:committable_tree_binding_raised, Exception.message(error)}}
      end

    case cleanup_owned_binding_root(private_root, root_identity) do
      :ok ->
        outcome

      {:error, cleanup_reason} ->
        diagnostic = bound_cleanup_diagnostic(outcome)

        {:error,
         {:tree_binding_cleanup_failed,
          %{
            cleanup_reason: bound_cleanup_diagnostic(cleanup_reason),
            operation_outcome: diagnostic
          }}}
    end
  end

  defp tree_binding_budget(opts) when is_list(opts) do
    bounds = snapshot_bounds()

    %{
      entries: 0,
      bytes: 0,
      max_entries: Keyword.get(opts, :max_entries, bounds.max_entries),
      max_bytes: Keyword.get(opts, :max_bytes, bounds.max_bytes),
      max_depth: Keyword.get(opts, :max_depth, bounds.max_depth)
    }
  end

  # After exclusive mkdir, set mode 0700 then create private children. The
  # root is already owned; failures still route through owned cleanup.
  defp finalize_owned_binding_root_children(private_root, private_git, private_stage)
       when is_binary(private_root) and is_binary(private_git) and is_binary(private_stage) do
    with :ok <- File.chmod(private_root, 0o700),
         :ok <- File.mkdir(private_git),
         :ok <- File.chmod(private_git, 0o700),
         :ok <- File.mkdir(private_stage),
         :ok <- File.chmod(private_stage, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:tree_binding_root_create_failed, reason}}
    end
  end

  # Stable identity for the owned root across the binding lifetime. Use
  # device/inode/type only — directory mtime/ctime change as children are
  # created and would false-fail a full-stat match before cleanup.
  defp capture_binding_root_identity(path) when is_binary(path) do
    case maybe_override_binding_root_identity(path) do
      :continue ->
        case File.lstat(path, time: :posix) do
          {:ok, %File.Stat{type: :directory} = stat} ->
            {:ok,
             {
               file_device_id(stat),
               Map.get(stat, :minor_device),
               stat.inode,
               :directory
             }}

          {:ok, %File.Stat{type: other}} ->
            {:error, {:tree_binding_root_not_directory, other}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_owned_binding_root(root, expected_identity)
       when is_binary(root) and is_tuple(expected_identity) do
    # Residual race (documented): no openat(2) — verify path identity then
    # path-based rm_rf; a same-window renamer between those steps is not
    # fully eliminable with stdlib File APIs.
    with {:ok, current_identity} <- capture_binding_root_identity(root),
         true <- current_identity == expected_identity do
      case File.rm_rf(root) do
        {:ok, _} ->
          if File.exists?(root),
            do: {:error, {:tree_binding_root_still_present, bound_path(root)}},
            else: :ok

        {:error, reason, _} ->
          {:error, {:tree_binding_rm_rf_failed, bound_cleanup_diagnostic(reason)}}
      end
    else
      {:error, :enoent} ->
        :ok

      false ->
        # Do not delete a replacement path that no longer matches ownership.
        {:error, :tree_binding_root_identity_changed}

      {:error, reason} ->
        {:error, {:tree_binding_cleanup_identity_unproven, bound_cleanup_diagnostic(reason)}}
    end
  rescue
    error ->
      {:error, {:tree_binding_cleanup_raised, Exception.message(error)}}
  end

  defp list_committable_paths(_git_dir, worktree, deadline_ms, budget) do
    # Use the worktree's own git directory/index via `-C` only. Forcing
    # `--git-dir` to the common dir can list the main worktree index and miss
    # linked-worktree entries (including gitlinks) that fail-closed gates need.
    with {:ok, tracked_stage} <-
           git_direct(["-C", worktree, "ls-files", "-z", "--stage"], deadline_ms),
         {:ok, tracked_paths} <- tracked_paths_from_stage(tracked_stage, budget),
         {:ok, untracked} <-
           git_direct(
             ["-C", worktree, "ls-files", "-z", "--others", "--exclude-standard"],
             deadline_ms
           ),
         {:ok, untracked_paths} <- untracked_paths_from_listing(untracked, budget) do
      paths =
        (tracked_paths ++ untracked_paths)
        |> Enum.uniq()
        |> Enum.sort()

      validate_committable_paths(paths, budget)
    end
  end

  # Parse `git ls-files --stage -z` entries. Fail closed on gitlinks (160000)
  # and any other unsupported tracked mode rather than silently omitting them.
  # Entry/depth bounds are checked before accumulating the full path list.
  defp tracked_paths_from_stage(stage_binary, budget) when is_binary(stage_binary) do
    stage_binary
    |> split_z()
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, acc, count} ->
      next_count = count + 1

      cond do
        next_count > budget.max_entries ->
          {:halt, {:error, :tree_binding_bounds_exceeded}}

        true ->
          case parse_stage_entry(entry) do
            {:ok, mode, _oid, path} when mode in ["100644", "100755", "120000"] ->
              case check_path_depth(path, budget.max_depth) do
                :ok ->
                  {:cont, {:ok, [path | acc], next_count}}

                {:error, _} = error ->
                  {:halt, error}
              end

            {:ok, "160000", _oid, path} ->
              {:halt, {:error, {:unsupported_tracked_gitlink, bound_path(path)}}}

            {:ok, mode, _oid, path} ->
              {:halt, {:error, {:unsupported_tracked_entry, mode, bound_path(path)}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, paths, _count} -> {:ok, Enum.reverse(paths)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracked_paths_from_stage(_, _), do: {:error, :invalid_stage_listing}

  defp untracked_paths_from_listing(untracked, budget) when is_binary(untracked) do
    untracked
    |> split_z()
    |> Enum.reduce_while({:ok, [], 0}, fn path, {:ok, acc, count} ->
      next_count = count + 1

      cond do
        path == "" ->
          {:cont, {:ok, acc, count}}

        next_count > budget.max_entries ->
          {:halt, {:error, :tree_binding_bounds_exceeded}}

        true ->
          case check_path_depth(path, budget.max_depth) do
            :ok ->
              {:cont, {:ok, [path | acc], next_count}}

            {:error, _} = error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, paths, _count} -> {:ok, Enum.reverse(paths)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp untracked_paths_from_listing(_, _), do: {:error, :invalid_untracked_listing}

  # Stage line: "<mode> <object> <stage>\t<path>" (NUL already stripped).
  # Split at the FIRST tab only — valid Git paths may contain tabs. Preserve
  # exact path bytes; never String.trim path or meta. Fail closed without
  # raising on malformed or non-UTF-8 records.
  defp parse_stage_entry(entry) when is_binary(entry) do
    try do
      case :binary.split(entry, <<?\t>>, []) do
        [meta, path] when path != <<>> and meta != <<>> ->
          case :binary.split(meta, <<" ">>, [:global]) do
            [mode, oid, _stage]
            when mode != <<>> and oid != <<>> and byte_size(mode) <= 8 and byte_size(oid) <= 64 ->
              {:ok, mode, oid, path}

            _ ->
              {:error, :invalid_stage_entry}
          end

        _ ->
          {:error, :invalid_stage_entry}
      end
    rescue
      _ -> {:error, :invalid_stage_entry}
    end
  end

  defp parse_stage_entry(_), do: {:error, :invalid_stage_entry}

  # Test-only: exercise first-tab stage parsing with exact binary path bytes.
  @doc false
  def __test_parse_stage_entry__(entry), do: parse_stage_entry(entry)

  defp validate_committable_paths(paths, budget) when is_list(paths) do
    if length(paths) > budget.max_entries do
      {:error, :tree_binding_bounds_exceeded}
    else
      Enum.reduce_while(paths, {:ok, paths}, fn path, {:ok, _} = acc ->
        cond do
          not safe_index_path?(path) ->
            {:halt, {:error, {:unsafe_index_path, bound_path(path)}}}

          match?({:error, _}, check_path_depth(path, budget.max_depth)) ->
            {:halt, {:error, :tree_binding_bounds_exceeded}}

          true ->
            {:cont, acc}
        end
      end)
    end
  end

  defp check_path_depth(path, max_depth)
       when is_binary(path) and is_integer(max_depth) and max_depth >= 0 do
    depth = path_segment_depth(path)

    if depth > max_depth do
      {:error, :tree_binding_bounds_exceeded}
    else
      :ok
    end
  end

  defp check_path_depth(_, _), do: {:error, :tree_binding_bounds_exceeded}

  defp path_segment_depth(path) when is_binary(path) do
    path
    |> :binary.split(<<"/">>, [:global])
    |> Enum.reject(&(&1 == <<>>))
    |> length()
  end

  defp stage_committable_paths(
         private_git,
         private_index,
         private_stage,
         worktree,
         paths,
         deadline_ms,
         budget
       ) do
    Enum.reduce_while(paths, {:ok, budget}, fn rel, {:ok, acc} ->
      case remaining_timeout(deadline_ms) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        {:ok, _} ->
          case stage_one_path(
                 private_git,
                 private_index,
                 private_stage,
                 worktree,
                 rel,
                 deadline_ms,
                 acc
               ) do
            {:ok, next} ->
              {:cont, {:ok, next}}

            # Deleted tracked paths are omitted from the would-be commit tree.
            :skip ->
              {:cont, {:ok, acc}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, _budget} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_one_path(
         private_git,
         private_index,
         private_stage,
         worktree,
         rel,
         deadline_ms,
         budget
       ) do
    unless safe_index_path?(rel) do
      {:error, {:unsafe_index_path, bound_path(rel)}}
    else
      # Join segments without Path.expand so leading/trailing spaces and
      # component-internal ".." (foo..bar) are preserved as literal path bytes.
      abs = worktree_join(worktree, rel)

      case File.lstat(abs, time: :posix) do
        {:error, :enoent} ->
          :skip

        {:ok, %File.Stat{type: :symlink} = before_stat} ->
          with :ok <- check_path_depth(rel, budget.max_depth),
               true <-
                 budget.entries + 1 <= budget.max_entries ||
                   {:error, :tree_binding_bounds_exceeded},
               {:ok, target} <- read_symlink_stable(abs, before_stat),
               true <-
                 budget.bytes + byte_size(target) <= budget.max_bytes ||
                   {:error, :tree_binding_bounds_exceeded},
               {:ok, oid} <-
                 hash_object_stdin_no_filters(private_git, target, deadline_ms),
               :ok <-
                 update_index_cacheinfo(
                   private_git,
                   private_index,
                   "120000",
                   oid,
                   rel,
                   deadline_ms
                 ) do
            {:ok,
             %{
               budget
               | entries: budget.entries + 1,
                 bytes: budget.bytes + byte_size(target)
             }}
          else
            false -> {:error, :tree_binding_bounds_exceeded}
            {:error, reason} -> {:error, reason}
            _ -> {:error, :stage_symlink_failed}
          end

        {:ok, %File.Stat{type: :regular, mode: mode} = before_stat} ->
          with :ok <- check_path_depth(rel, budget.max_depth),
               true <-
                 budget.entries + 1 <= budget.max_entries ||
                   {:error, :tree_binding_bounds_exceeded},
               {:ok, oid, size} <-
                 hash_regular_file_via_private_stage(
                   private_git,
                   private_stage,
                   abs,
                   before_stat,
                   budget,
                   deadline_ms
                 ),
               mode_oct <- if(executable_mode?(mode), do: "100755", else: "100644"),
               :ok <-
                 update_index_cacheinfo(
                   private_git,
                   private_index,
                   mode_oct,
                   oid,
                   rel,
                   deadline_ms
                 ) do
            {:ok, %{budget | entries: budget.entries + 1, bytes: budget.bytes + size}}
          else
            false -> {:error, :tree_binding_bounds_exceeded}
            {:error, reason} -> {:error, reason}
            _ -> {:error, :stage_file_failed}
          end

        {:ok, %File.Stat{type: :directory}} ->
          # Tracked gitlinks look like directories; listing already rejects
          # mode 160000. Any remaining directory at a listed path is unsupported.
          {:error, {:unsupported_worktree_directory, bound_path(rel)}}

        {:ok, %File.Stat{type: other}} ->
          {:error, {:unsupported_worktree_entry, other}}

        {:error, reason} ->
          {:error, {:worktree_lstat_failed, reason}}
      end
    end
  end

  defp worktree_join(worktree, rel)
       when is_binary(worktree) and is_binary(rel) and worktree != "" and rel != "" do
    worktree <> "/" <> rel
  end

  # Copy untrusted regular-file bytes through a validated descriptor into an
  # invocation-private staging file, then hash that private copy. Never
  # File.read/1 the worktree path wholesale into BEAM memory.
  @tree_binding_copy_chunk 65_536

  defp hash_regular_file_via_private_stage(
         private_git,
         private_stage,
         abs,
         before_stat,
         budget,
         deadline_ms
       ) do
    size = max(before_stat.size || 0, 0)

    cond do
      budget.bytes + size > budget.max_bytes ->
        {:error, :tree_binding_bounds_exceeded}

      true ->
        stage_token = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        stage_path = Path.join(private_stage, "blob-#{stage_token}")

        try do
          with :ok <-
                 copy_regular_file_to_private_stage(
                   abs,
                   before_stat,
                   stage_path,
                   size,
                   deadline_ms
                 ),
               {:ok, oid} <- hash_object_file_no_filters(private_git, stage_path, deadline_ms) do
            {:ok, oid, size}
          end
        after
          _ = File.rm(stage_path)
        end
    end
  end

  defp copy_regular_file_to_private_stage(
         abs,
         before_stat,
         stage_path,
         expected_size,
         deadline_ms
       ) do
    with {:ok, _} <- remaining_timeout(deadline_ms),
         {:ok, src} <- :file.open(String.to_charlist(abs), [:read, :raw, :binary]) do
      try do
        copy_opened_regular_to_stage(
          src,
          abs,
          before_stat,
          stage_path,
          expected_size,
          deadline_ms
        )
      after
        _ = :file.close(src)
      end
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:worktree_file_open_failed, other}}
    end
  end

  defp copy_opened_regular_to_stage(src, abs, before_stat, stage_path, expected_size, deadline_ms) do
    with {:ok, %File.Stat{type: :regular} = opened_stat} <- descriptor_file_stat(src),
         true <- stable_file_identity(before_stat) == stable_file_identity(opened_stat),
         true <- opened_stat.size == expected_size,
         {:ok, dst} <-
           :file.open(String.to_charlist(stage_path), [:write, :raw, :binary, :exclusive]) do
      try do
        with {:ok, ^expected_size} <-
               copy_descriptor_chunks(src, dst, expected_size, 0, deadline_ms),
             {:ok, %File.Stat{type: :regular} = after_desc} <- descriptor_file_stat(src),
             true <- stable_file_identity(before_stat) == stable_file_identity(after_desc),
             true <- after_desc.size == expected_size,
             {:ok, %File.Stat{type: :regular} = after_path} <- File.lstat(abs, time: :posix),
             true <- stable_file_identity(before_stat) == stable_file_identity(after_path),
             true <- after_path.size == expected_size do
          :ok
        else
          false -> {:error, :worktree_file_changed}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:worktree_file_copy_failed, other}}
        end
      after
        _ = :file.close(dst)
      end
    else
      false ->
        {:error, :worktree_file_changed}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:worktree_file_copy_failed, other}}
    end
  end

  defp copy_descriptor_chunks(_src, _dst, expected_size, copied, _deadline)
       when copied == expected_size do
    {:ok, copied}
  end

  defp copy_descriptor_chunks(src, dst, expected_size, copied, deadline_ms) do
    with {:ok, _} <- remaining_timeout(deadline_ms) do
      to_read = min(@tree_binding_copy_chunk, expected_size - copied)

      case :file.read(src, to_read) do
        {:ok, data} when is_binary(data) and byte_size(data) > 0 ->
          case :file.write(dst, data) do
            :ok ->
              copy_descriptor_chunks(
                src,
                dst,
                expected_size,
                copied + byte_size(data),
                deadline_ms
              )

            other ->
              {:error, {:stage_write_failed, other}}
          end

        :eof when copied == expected_size ->
          {:ok, copied}

        :eof ->
          {:error, :worktree_file_changed}

        other ->
          {:error, {:stage_read_failed, other}}
      end
    end
  end

  defp descriptor_file_stat(io_device) do
    case :file.read_file_info(io_device, time: :posix) do
      {:ok, info} ->
        {:ok, File.Stat.from_record(info)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Symlink capture is race-stable: path lstat (caller) → read target → optional
  # process-local test hook → re-read target → path lstat. Require identical
  # stable identity *and* identical target observations so an equal-size
  # replacement cannot pass on device/inode/size alone.
  #
  # Residual stdlib limitation: Elixir/Erlang File APIs do not expose
  # openat(2)/O_PATH/O_NOFOLLOW directory-FD traversal, and `time: :posix`
  # mtime/ctime are second-resolution. A same-second metadata-preserving swap
  # that also reuses device/inode is not fully eliminable without OS-level
  # openat-style capture.
  defp read_symlink_stable(path, %File.Stat{type: :symlink} = before_stat) do
    with {:ok, target_before} <- File.read_link(path),
         true <- symlink_target_size_matches?(before_stat, target_before),
         :ok <- maybe_tree_binding_symlink_capture_hook(path),
         {:ok, target_after} <- File.read_link(path),
         true <- target_before == target_after,
         {:ok, %File.Stat{type: :symlink} = after_stat} <- File.lstat(path, time: :posix),
         true <- stable_file_identity(before_stat) == stable_file_identity(after_stat) do
      {:ok, target_after}
    else
      {:error, reason} when reason in [:enoent, :einval, :eacces, :eperm] ->
        {:error, :worktree_symlink_changed}

      _ ->
        {:error, :worktree_symlink_changed}
    end
  end

  defp symlink_target_size_matches?(%File.Stat{size: size}, target)
       when is_integer(size) and is_binary(target) do
    size == byte_size(target)
  end

  defp symlink_target_size_matches?(_, _), do: false

  # Test-only deterministic seam for symlink swap during capture. Process
  # dictionary only — no Application environment fallback (cross-process leak).
  defp maybe_tree_binding_symlink_capture_hook(path) when is_binary(path) do
    case Process.get({__MODULE__, :tree_binding_symlink_capture_hook}) do
      fun when is_function(fun, 1) ->
        _ = fun.(path)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_observe_tree_binding_root(root) when is_binary(root) do
    case Process.get({__MODULE__, :tree_binding_root_observer}) do
      fun when is_function(fun, 1) ->
        _ = fun.(root)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_override_binding_root_identity(root) when is_binary(root) do
    case Process.get({__MODULE__, :tree_binding_root_identity_hook}) do
      fun when is_function(fun, 1) -> fun.(root)
      _ -> :continue
    end
  end

  @doc false
  def __test_set_symlink_capture_hook__(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :tree_binding_symlink_capture_hook}, fun)
    :ok
  end

  def __test_set_symlink_capture_hook__(nil) do
    Process.delete({__MODULE__, :tree_binding_symlink_capture_hook})
    :ok
  end

  @doc false
  def __test_set_binding_root_observer__(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :tree_binding_root_observer}, fun)
    :ok
  end

  def __test_set_binding_root_observer__(nil) do
    Process.delete({__MODULE__, :tree_binding_root_observer})
    :ok
  end

  @doc false
  def __test_set_binding_root_identity_hook__(fun) when is_function(fun, 1) do
    Process.put({__MODULE__, :tree_binding_root_identity_hook}, fun)
    :ok
  end

  def __test_set_binding_root_identity_hook__(nil) do
    Process.delete({__MODULE__, :tree_binding_root_identity_hook})
    :ok
  end

  # Test-only: exercise the same fail-closed path gate used before update-index.
  @doc false
  def __test_reject_index_path__(path) when is_binary(path) do
    if safe_index_path?(path), do: :ok, else: {:error, {:unsafe_index_path, bound_path(path)}}
  end

  # Identity used for TOCTOU checks between path lstat and descriptor fstat.
  # Path and descriptor stats MUST both use `time: :posix` so mtime/ctime are
  # comparable integers. Includes mode/mtime/ctime in addition to
  # device/inode/size/type.
  #
  # Residual limitation: no openat(2) in stdlib; posix times are second-
  # resolution on this stack, so same-second metadata-preserving replacement
  # is not a full hostile-runtime guarantee.
  defp stable_file_identity(%File.Stat{} = stat) do
    {
      file_device_id(stat),
      Map.get(stat, :minor_device),
      stat.inode,
      stat.size,
      stat.type,
      stat.mode,
      stat.mtime,
      stat.ctime
    }
  end

  defp file_device_id(%File.Stat{} = stat) do
    Map.get(stat, :major_device) || Map.get(stat, :device)
  end

  defp executable_mode?(mode) when is_integer(mode), do: Bitwise.band(mode, 0o111) != 0
  defp executable_mode?(_), do: false

  defp hash_object_stdin_no_filters(private_git, content, deadline_ms) when is_binary(content) do
    with {:ok, rem} <- remaining_timeout(deadline_ms),
         {:ok, result} <-
           Arbor.Shell.execute_direct(
             "git",
             isolated_git_args([
               "--git-dir",
               private_git,
               "hash-object",
               "--stdin",
               "-w",
               "--no-filters"
             ]),
             timeout: rem,
             env: isolated_git_env([]),
             clear_env: true,
             sandbox: :none,
             stdin: content
           ),
         oid when is_binary(oid) <- String.trim(result.stdout || ""),
         true <- Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, oid) do
      {:ok, oid}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :hash_object_failed}
    end
  end

  defp hash_object_file_no_filters(private_git, file_path, deadline_ms)
       when is_binary(file_path) do
    with {:ok, rem} <- remaining_timeout(deadline_ms),
         {:ok, result} <-
           Arbor.Shell.execute_direct(
             "git",
             isolated_git_args([
               "--git-dir",
               private_git,
               "hash-object",
               "-w",
               "--no-filters",
               "--",
               file_path
             ]),
             timeout: rem,
             env: isolated_git_env([]),
             clear_env: true,
             sandbox: :none
           ),
         oid when is_binary(oid) <- String.trim(result.stdout || ""),
         true <- Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, oid) do
      {:ok, oid}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :hash_object_failed}
    end
  end

  defp update_index_cacheinfo(private_git, private_index, mode, oid, path, deadline_ms) do
    # Refuse path components that could escape or inject. Use the three-arg
    # --cacheinfo form so paths containing commas remain well-formed.
    if safe_index_path?(path) do
      case git_direct(
             [
               "--git-dir",
               private_git,
               "update-index",
               "--add",
               "--cacheinfo",
               mode,
               oid,
               path
             ],
             deadline_ms,
             [{"GIT_INDEX_FILE", private_index}]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:unsafe_index_path, bound_path(path)}}
    end
  end

  # Segment-aware path safety: absolute paths and actual "." / ".." components
  # are invalid. A substring ".." inside a component (foo..bar) is allowed.
  # Leading/trailing spaces and tabs in components are preserved and accepted.
  # Binary-safe: never raise on non-UTF-8 path bytes (fail closed instead).
  defp safe_index_path?(path) when is_binary(path) do
    try do
      path != <<>> and not binary_contains_any?(path, [<<0>>, <<"\n">>, <<"\r">>]) and
        not absolute_index_path?(path) and
        safe_index_segments?(path)
    rescue
      _ -> false
    end
  end

  defp safe_index_path?(_), do: false

  defp binary_contains_any?(binary, needles) when is_binary(binary) and is_list(needles) do
    Enum.any?(needles, fn needle ->
      case :binary.match(binary, needle) do
        :nomatch -> false
        {_pos, _len} -> true
      end
    end)
  end

  defp absolute_index_path?(path) when is_binary(path) do
    leading_slash? =
      byte_size(path) > 0 and :binary.part(path, {0, 1}) == <<"/">>

    leading_slash? or Path.type(path) == :absolute
  end

  defp safe_index_segments?(path) when is_binary(path) do
    segments = :binary.split(path, <<"/">>, [:global])

    segments != [] and
      Enum.all?(segments, fn segment ->
        segment != <<>> and segment != <<".">> and segment != <<"..">>
      end)
  end

  defp maybe_tree_binding(_cwd, false, _deadline), do: {:ok, nil}

  defp maybe_tree_binding(cwd, true, deadline_ms) do
    committable_tree_binding(cwd, deadline_ms: deadline_ms)
  end

  defp assert_tree_stable(nil, nil), do: :ok

  defp assert_tree_stable(%{tree_oid: before}, %{tree_oid: after_oid})
       when before == after_oid,
       do: :ok

  defp assert_tree_stable(_before, _after), do: {:error, :validation_tree_mutated}

  defp resolve_git_common_dir(path, deadline_ms) do
    with {:ok, output} <-
           git_direct(
             ["-C", path, "rev-parse", "--is-inside-work-tree"],
             deadline_ms
           ),
         true <- String.trim(output) in ["true", "true\n"],
         {:ok, git_dir} <-
           git_direct(["-C", path, "rev-parse", "--git-common-dir"], deadline_ms) do
      git_dir = String.trim(git_dir)

      absolute =
        if Path.type(git_dir) == :absolute,
          do: git_dir,
          else: Path.expand(git_dir, path)

      case SafePath.resolve_real(absolute) do
        {:ok, real} -> {:ok, real}
        _ -> {:error, :git_dir_unavailable}
      end
    else
      false -> {:error, :not_a_git_worktree}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_a_git_worktree}
    end
  end

  # Isolated, structured-argv git via the childless Shell primitive. Never uses
  # the candidate repo's local config for filter/hook/fsmonitor execution.
  defp git_direct(args, deadline_ms, extra_env \\ [])
       when is_list(args) and is_integer(deadline_ms) do
    with {:ok, rem} <- remaining_timeout(deadline_ms),
         {:ok, result} <-
           Arbor.Shell.execute_direct(
             "git",
             isolated_git_args(args),
             timeout: rem,
             env: isolated_git_env(extra_env),
             clear_env: true,
             sandbox: :none
           ) do
      if result.exit_code == 0 do
        {:ok, result.stdout || ""}
      else
        {:error, :git_failed}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :git_failed}
    end
  end

  # Match the Git action isolation prefix: no hooks, no fsmonitor, no external
  # attribute/exclude files. Clean filters are additionally defeated by hashing
  # with --no-filters into a private GIT_DIR rather than `git add` in-place.
  defp isolated_git_args(args) when is_list(args) do
    [
      "--no-pager",
      "--no-replace-objects",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "core.useBuiltinFSMonitor=false",
      "-c",
      "core.attributesFile=/dev/null",
      "-c",
      "core.excludesFile=/dev/null",
      "-c",
      "core.pager=cat",
      "-c",
      "core.askPass=",
      "-c",
      "credential.helper=",
      "-c",
      "sequence.editor=",
      "-c",
      "core.editor="
      | args
    ]
  end

  defp isolated_git_env(extra) when is_list(extra) do
    base = %{
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_OPTIONAL_LOCKS" => "0",
      "GIT_ATTR_NOSYSTEM" => "1"
    }

    Enum.reduce(extra, base, fn {k, v}, acc ->
      Map.put(acc, to_string(k), to_string(v))
    end)
  end

  # Preserve exact path bytes from NUL-delimited git output. Do not String.trim:
  # leading/trailing spaces are valid filename characters.
  defp split_z(binary) when is_binary(binary) do
    binary
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
  end

  defp split_z(_), do: []

  defp bound_path(path) when is_binary(path), do: truncate_bytes_raw(path, 256)
  defp bound_path(other), do: bound_cleanup_diagnostic(other)

  defp absolute_deadline(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp absolute_deadline(_), do: System.monotonic_time(:millisecond) + mix_timeout()

  defp remaining_timeout(nil), do: {:ok, mix_timeout()}

  defp remaining_timeout(deadline_ms) when is_integer(deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining > 0 do
      {:ok, remaining}
    else
      {:error, :operation_deadline_exceeded}
    end
  end

  defp remaining_timeout(_), do: {:error, :operation_deadline_exceeded}

  @doc false
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  defp default_mix_env(["test" | _args]), do: %{"MIX_ENV" => "test"}
  defp default_mix_env(_args), do: %{}

  @doc false
  def shared_host_mix_env(path, opts \\ [])

  def shared_host_mix_env(path, opts) when is_binary(path) and is_list(opts), do: %{}

  def shared_host_mix_env(_path, _opts), do: %{}

  @doc false
  def scrub_caller_env(env) when is_map(env) do
    env
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      string_key = env_key(key)

      cond do
        string_key in @module_owned_env_keys ->
          acc

        MapSet.member?(@safe_caller_env_keys, string_key) and is_binary(value) ->
          Map.put(acc, string_key, value)

        true ->
          acc
      end
    end)
  end

  def scrub_caller_env(_), do: %{}

  defp require_projections(nil, _revision), do: {:error, :validation_resource_required}

  defp require_projections(resource, revision),
    do: projections_for_resource(resource, revision)

  # No production ephemeral execution roots: only owner-scoped validation
  # resources may supply path-bearing Mix env.
  defp resource_env_paths(nil, _revision, _project_path),
    do: {:error, :validation_resource_required}

  defp resource_env_paths(resource, revision, _project_path) when is_map(resource) do
    with {:ok, paths} <- revision_private_paths(resource, revision) do
      {:ok,
       %{
         home_path: paths.home_path,
         tmp_path: paths.tmp_path,
         build_path: paths.build_path,
         deps_path: paths.deps_path
       }, nil}
    end
  end

  defp resource_env_paths(_, _, _), do: {:error, :invalid_validation_resource}

  defp revision_private_paths(resource, :candidate) when is_map(resource) do
    build = resource_field(resource, :candidate_build_path)

    runtime =
      resource_field(resource, :candidate_runtime_path) ||
        if(is_binary(build), do: Path.dirname(build), else: nil)

    paths = %{
      worktree_path: resource_field(resource, :candidate_path),
      runtime_path: runtime,
      home_path:
        resource_field(resource, :candidate_home_path) || resource_field(resource, :home_path),
      tmp_path:
        resource_field(resource, :candidate_tmp_path) || resource_field(resource, :tmp_path),
      build_path: build,
      deps_path: resource_field(resource, :candidate_deps_path)
    }

    if Enum.all?(Map.values(paths), &(is_binary(&1) and &1 != "")) do
      {:ok, paths}
    else
      {:error, :invalid_validation_resource}
    end
  end

  defp revision_private_paths(resource, :base) when is_map(resource) do
    paths = %{
      worktree_path: resource_field(resource, :base_worktree_path),
      runtime_path: resource_field(resource, :base_runtime_path),
      home_path: resource_field(resource, :base_home_path),
      tmp_path: resource_field(resource, :base_tmp_path),
      build_path: resource_field(resource, :base_build_path),
      deps_path: resource_field(resource, :base_deps_path)
    }

    if Enum.all?(Map.values(paths), &(is_binary(&1) and &1 != "")) do
      {:ok, paths}
    else
      {:error, :invalid_validation_resource}
    end
  end

  defp revision_private_paths(_, _), do: {:error, :invalid_validation_resource}

  defp enforce_module_owned_keys(env, roots, resource_paths) do
    Map.merge(env, %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_ERLANG_ROOT" => roots.erlang_root,
      "ARBOR_ELIXIR_ROOT" => roots.elixir_root,
      "PATH" => contained_path(roots),
      "HOME" => resource_paths.home_path,
      "TMPDIR" => resource_paths.tmp_path,
      "TMP" => resource_paths.tmp_path,
      "TEMP" => resource_paths.tmp_path,
      "MIX_HOME" => Path.join(resource_paths.home_path, ".mix"),
      "MIX_ARCHIVES" => Path.join(resource_paths.home_path, ".mix/archives"),
      "HEX_HOME" => Path.join(resource_paths.home_path, ".hex"),
      "REBAR_CACHE_DIR" => Path.join(resource_paths.home_path, ".cache/rebar3"),
      "MIX_BUILD_PATH" => resource_paths.build_path,
      "MIX_BUILD_ROOT" => false,
      "MIX_DEPS_PATH" => resource_paths.deps_path,
      "ERL_LIBS" => false
    })
  end

  defp contained_path(roots) do
    Enum.join(
      [
        Path.join(roots.erlang_root, "bin"),
        Path.join(roots.elixir_root, "bin"),
        "/usr/bin",
        "/bin"
      ],
      ":"
    )
  end

  # Ephemeral private trees are no longer used for production Mix execution.
  # Keep enforcing cleanup helper above for any residual roots from older paths
  # or failure settlement. create_private_tree remains available for tests that
  # inject partial cleanup scenarios via the registry.

  defp validation_caller(context) when is_map(context) do
    %{
      task_id: Workspace.context_task_id(context),
      principal_id: Workspace.context_principal_id(context),
      cleanup_failures:
        Map.get(context, :cleanup_failures) || Map.get(context, "cleanup_failures"),
      force_cleanup_failure_once:
        Map.get(context, :force_cleanup_failure_once) == true ||
          Map.get(context, "force_cleanup_failure_once") == true,
      force_dependency_snapshot_failure:
        Map.get(context, :force_dependency_snapshot_failure) == true ||
          Map.get(context, "force_dependency_snapshot_failure") == true,
      force_partial_cleanup_failure_once:
        Map.get(context, :force_partial_cleanup_failure_once) == true ||
          Map.get(context, "force_partial_cleanup_failure_once") == true,
      server: Map.get(context, :server) || Map.get(context, "server")
    }
  end

  defp projection(path, mode, purpose)
       when is_binary(path) and is_atom(mode) and is_atom(purpose) do
    %{
      "path" => path,
      "mode" => Atom.to_string(mode),
      "purpose" => Atom.to_string(purpose)
    }
  end

  defp resource_field(resource, key) when is_map(resource) and is_atom(key) do
    Map.get(resource, key) || Map.get(resource, Atom.to_string(key))
  end

  defp env_key(key) when is_atom(key), do: Atom.to_string(key)
  defp env_key(key) when is_binary(key), do: key
  defp env_key(_), do: ""

  # Wrapper authority comes only from loaded application/module code roots.
  # Never bake a developer source path into the BEAM; a release layout without
  # a bundled reviewed wrapper fails closed.
  defp code_root_anchors do
    [
      safe_app_dir(:arbor_actions),
      safe_lib_dir(:arbor_actions),
      safe_module_dir(),
      safe_app_dir(:arbor_common),
      safe_lib_dir(:arbor_common)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp safe_app_dir(app) do
    Application.app_dir(app)
  rescue
    _ -> nil
  end

  defp safe_lib_dir(app) do
    case :code.lib_dir(app) do
      path when is_list(path) -> List.to_string(path)
      _ -> nil
    end
  end

  defp safe_module_dir do
    case :code.which(__MODULE__) do
      path when is_list(path) -> Path.dirname(List.to_string(path))
      _ -> nil
    end
  end

  defp ancestor_paths(nil), do: []

  defp ancestor_paths(path) when is_binary(path) do
    path = Path.expand(path)
    do_ancestors(path, [path])
  end

  defp do_ancestors(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse(acc)
    else
      do_ancestors(parent, [parent | acc])
    end
  end

  defp verify_wrapper_at(root) when is_binary(root) do
    wrapper = Path.join(root, "bin/mix")

    with true <- umbrella_root?(root),
         true <- File.regular?(wrapper),
         true <- executable_file?(wrapper),
         {:ok, canonical} <- SafePath.resolve_real(wrapper),
         true <- File.regular?(canonical),
         true <- executable_file?(canonical),
         {:ok, canonical_root} <- SafePath.resolve_real(root),
         true <- path_under?(canonical, Path.join(canonical_root, "bin")) do
      {:ok, canonical}
    else
      _ -> {:error, :mix_wrapper_unavailable}
    end
  end

  defp umbrella_root?(path) do
    File.exists?(Path.join(path, "mix.exs")) and File.dir?(Path.join(path, "apps")) and
      File.dir?(Path.join(path, "bin"))
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp path_under?(path, parent) do
    path == parent or String.starts_with?(path, parent <> "/")
  end

  defp resolve_erlang_root do
    root = :code.root_dir() |> to_string() |> Path.expand()
    erl = Path.join(root, "bin/erl")

    with {:ok, canonical} <- SafePath.resolve_real(root),
         erl_path = Path.join(canonical, "bin/erl"),
         true <- File.exists?(erl_path) or File.exists?(erl) do
      {:ok, canonical}
    else
      _ -> {:error, :erlang_root_unavailable}
    end
  end

  defp resolve_elixir_root do
    elixir_lib = :code.lib_dir(:elixir) |> to_string() |> Path.expand()
    root = elixir_lib |> Path.dirname() |> Path.dirname()

    with {:ok, canonical} <- SafePath.resolve_real(root),
         true <- executable_file?(Path.join(canonical, "bin/mix")),
         true <- executable_file?(Path.join(canonical, "bin/elixir")) do
      {:ok, canonical}
    else
      _ -> {:error, :elixir_root_unavailable}
    end
  end

  @doc false
  # Production Mix actions always require an owner-issued workspace lease.
  # There is no optional bypass: missing workspace_id fails closed before spawn.
  def run_with_required_workspace(path, args, params, context, base_opts) do
    case required_workspace_id(params) do
      {:ok, workspace_id} ->
        timeout = Keyword.get(base_opts, :timeout, mix_timeout())
        deadline_ms = absolute_deadline(timeout)
        bind_tree? = Keyword.get(base_opts, :bind_committable_tree, true)

        with_validation_resource(
          workspace_id,
          context || %{},
          fn resource ->
            case remaining_timeout(deadline_ms) do
              {:ok, remaining} ->
                run_mix(
                  path,
                  args,
                  base_opts
                  |> Keyword.put(:validation_resource, resource)
                  |> Keyword.put(:timeout, remaining)
                  |> Keyword.put(:deadline_ms, deadline_ms)
                  |> Keyword.put(:bind_committable_tree, bind_tree?)
                )

              {:error, reason} ->
                {:error, reason}
            end
          end,
          timeout: timeout,
          deadline_ms: deadline_ms
        )

      :error ->
        {:error, :workspace_id_required}
    end
  end

  # Back-compat alias used by older call sites/tests; behaves as required.
  @doc false
  def run_with_optional_workspace(path, args, params, context, base_opts) do
    run_with_required_workspace(path, args, params, context, base_opts)
  end

  @doc false
  def required_workspace_id(params) when is_map(params) do
    case Map.get(params, :workspace_id) || Map.get(params, "workspace_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  def required_workspace_id(_), do: :error

  @doc false
  def optional_workspace_id(params) do
    case required_workspace_id(params) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  @doc false
  def timeout_opts(params) when is_map(params) do
    if params[:timeout], do: [timeout: params[:timeout]], else: []
  end

  def timeout_opts(_), do: []

  defmodule Compile do
    @moduledoc """
    Run `mix compile`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `workspace_id` | string | yes | Opaque workspace lease for owner-scoped validation resources |
    | `warnings_as_errors` | boolean | no | Pass `--warnings-as-errors` |
    | `timeout` | integer | no | Command timeout in ms (default 5 min) |
    """

    use Jido.Action,
      name: "mix_compile",
      description: "Run `mix compile` in a project directory",
      category: "mix",
      tags: ["mix", "compile", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id for owner-scoped validation resources"
        ],
        warnings_as_errors: [
          type: :boolean,
          default: false,
          doc: "Treat compiler warnings as errors"
        ],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        workspace_id: :control,
        warnings_as_errors: :control,
        timeout: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, context) do
      Actions.emit_started(__MODULE__, params)

      args = build_args(params)
      opts = MixAction.timeout_opts(params) ++ [bind_committable_tree: true]

      case MixAction.run_with_required_workspace(path, args, params, context || %{}, opts) do
        {:ok, result} ->
          feedback = MixAction.compile_feedback(result)

          output = %{
            path: path,
            exit_code: result.exit_code,
            passed: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr,
            feedback: feedback,
            feedback_json: Jason.encode!(feedback),
            validated_tree_oid: Map.get(result, :validated_tree_oid),
            validated_head: Map.get(result, :validated_head)
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix compile failed to execute: #{MixAction.format_error(reason)}"}
      end
    end

    defp build_args(params) do
      args = ["compile"]

      if params[:warnings_as_errors] do
        args ++ ["--warnings-as-errors"]
      else
        args
      end
    end
  end

  defmodule Test do
    @moduledoc """
    Run `mix test`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `workspace_id` | string | yes | Opaque workspace lease for owner-scoped validation resources |
    | `test_paths` | list | no | Specific test files/dirs to run |
    | `tags` | string | no | `--only` tag filter (e.g. `"fast"`) |
    | `seed` | integer | no | Test seed for deterministic ordering |
    | `timeout` | integer | no | Command timeout in ms (default 5 min) |

    ## Returns

    - `path` — project path
    - `exit_code` — `mix test` exit code (0 = success)
    - `passed` — boolean derived from exit_code (no `?` suffix so this
      can be used directly in DOT edge conditions like
      `context.exec.<node>.passed=true`)
    - `stdout` — captured stdout
    - `stderr` — captured stderr
    - `feedback` — JSON-clean bounded output excerpts, truncation flags,
      and full-output SHA-256 hashes
    - `feedback_json` — JSON serialization of `feedback`
    """

    use Jido.Action,
      name: "mix_test",
      description: "Run `mix test` in a project directory",
      category: "mix",
      tags: ["mix", "test", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id for owner-scoped validation resources"
        ],
        test_paths: [type: {:list, :string}, doc: "Specific test paths to run"],
        tags: [type: :string, doc: "Tag filter for --only"],
        seed: [type: :non_neg_integer, doc: "Test seed"],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        workspace_id: :control,
        test_paths: {:control, requires: [:path_traversal]},
        tags: {:control, requires: [:command_injection]},
        seed: :data,
        timeout: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, context) do
      Actions.emit_started(__MODULE__, params)

      opts = MixAction.timeout_opts(params) ++ [bind_committable_tree: true]

      with {:ok, args} <- build_args(path, params),
           {:ok, result} <-
             MixAction.run_with_required_workspace(path, args, params, context || %{}, opts) do
        feedback = MixAction.compile_feedback(result)

        output = %{
          path: path,
          exit_code: result.exit_code,
          passed: result.exit_code == 0,
          stdout: result.stdout,
          stderr: result.stderr,
          feedback: feedback,
          feedback_json: Jason.encode!(feedback),
          validated_tree_oid: Map.get(result, :validated_tree_oid),
          validated_head: Map.get(result, :validated_head)
        }

        Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
        {:ok, output}
      else
        {:error, {:invalid_test_path, _path} = reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test rejected invalid test_paths: #{inspect(reason)}"}

        {:error, {:invalid_test_tag, _tag} = reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test rejected invalid tag: #{inspect(reason)}"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test failed to execute: #{MixAction.format_error(reason)}"}
      end
    end

    defp build_args(path, params) do
      with :ok <- validate_tag(params[:tags]),
           {:ok, test_paths} <- validate_test_paths(path, params[:test_paths]) do
        args = ["test"]
        args = if params[:tags], do: args ++ ["--only", params[:tags]], else: args
        args = if params[:seed], do: args ++ ["--seed", to_string(params[:seed])], else: args

        if test_paths == [] do
          {:ok, args}
        else
          {:ok, args ++ ["--" | test_paths]}
        end
      end
    end

    defp validate_tag(nil), do: :ok

    defp validate_tag(tag) when is_binary(tag) do
      if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_.-]*\z/, tag),
        do: :ok,
        else: {:error, {:invalid_test_tag, tag}}
    end

    defp validate_tag(tag), do: {:error, {:invalid_test_tag, tag}}

    defp validate_test_paths(_root, nil), do: {:ok, []}
    defp validate_test_paths(_root, []), do: {:ok, []}

    defp validate_test_paths(root, paths) when is_list(paths) do
      Enum.reduce_while(paths, {:ok, []}, fn test_path, {:ok, accepted} ->
        case validate_test_path(root, test_path) do
          :ok -> {:cont, {:ok, [test_path | accepted]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
        error -> error
      end
    end

    defp validate_test_paths(_root, paths), do: {:error, {:invalid_test_path, paths}}

    defp validate_test_path(root, test_path) when is_binary(test_path) do
      path_without_line = Regex.replace(~r/:\d+\z/, test_path, "")
      expanded_root = Path.expand(root)
      expanded = Path.expand(path_without_line, expanded_root)

      valid_shape? =
        Regex.match?(
          ~r/\A(?:apps\/[A-Za-z0-9_.-]+\/)?test(?:\/[A-Za-z0-9_.()&+@ -]+)*(?::\d+)?\z/,
          test_path
        )

      contained? = canonical_test_path?(expanded_root, expanded)

      if valid_shape? and contained? and File.exists?(expanded) do
        :ok
      else
        {:error, {:invalid_test_path, test_path}}
      end
    end

    defp validate_test_path(_root, test_path), do: {:error, {:invalid_test_path, test_path}}

    defp canonical_test_path?(root, path) do
      with {:ok, canonical_root} <- SafePath.resolve_real(root),
           {:ok, canonical_path} <- SafePath.resolve_real(path) do
        canonical_path == canonical_root or
          String.starts_with?(canonical_path, canonical_root <> "/")
      else
        _ -> false
      end
    end
  end

  defmodule Quality do
    @moduledoc """
    Run `mix quality` (the Arbor-wide format-check + credo --strict alias
    defined in the umbrella's mix.exs).

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `workspace_id` | string | yes | Opaque workspace lease for owner-scoped validation resources |
    | `timeout` | integer | no | Command timeout in ms (default 5 min) |

    ## Returns

    - `path` — project path
    - `exit_code` — `mix quality` exit code (0 = passed all checks)
    - `passed` — boolean derived from exit_code
    - `stdout` / `stderr` — captured output
    """

    use Jido.Action,
      name: "mix_quality",
      description: "Run `mix quality` (format-check + credo)",
      category: "mix",
      tags: ["mix", "quality", "lint", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id for owner-scoped validation resources"
        ],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        workspace_id: :control,
        timeout: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, context) do
      Actions.emit_started(__MODULE__, params)

      opts = MixAction.timeout_opts(params) ++ [bind_committable_tree: true]

      case MixAction.run_with_required_workspace(
             path,
             ["quality"],
             params,
             context || %{},
             opts
           ) do
        {:ok, result} ->
          output = %{
            path: path,
            exit_code: result.exit_code,
            passed: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr,
            validated_tree_oid: Map.get(result, :validated_tree_oid),
            validated_head: Map.get(result, :validated_head)
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix quality failed to execute: #{MixAction.format_error(reason)}"}
      end
    end
  end

  defmodule Format do
    @moduledoc """
    Run `mix format`. Default mode rewrites files; `check_only: true` runs
    `mix format --check-formatted` and reports drift without writing.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `workspace_id` | string | yes | Opaque workspace lease for owner-scoped validation resources |
    | `check_only` | boolean | no | `--check-formatted` mode (default false) |
    | `files` | list | no | Existing project-relative files (no options or globs) |

    ## Returns

    - `path` — project path
    - `exit_code` — exit code (0 = clean / formatted, non-zero = drift in check_only mode)
    - `passed` — boolean derived from the formatter exit status
    - `stdout` / `stderr` — captured output
    """

    use Jido.Action,
      name: "mix_format",
      description: "Run `mix format` (write or check-only)",
      category: "mix",
      tags: ["mix", "format", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id for owner-scoped validation resources"
        ],
        check_only: [type: :boolean, default: false, doc: "Check-only mode"],
        files: [
          type: {:list, :string},
          doc: "Existing project-relative files (no options or globs)"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafePath
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        workspace_id: :control,
        check_only: :control,
        files: {:control, requires: [:path_traversal]}
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{} = params, context) do
      with {:ok, path, args} <- build_invocation(params) do
        Actions.emit_started(__MODULE__, params)
        # Write mode intentionally mutates sources; check-only binds the tree.
        bind_tree? = Map.get(params, :check_only, false) == true
        opts = [bind_committable_tree: bind_tree?]

        case MixAction.run_with_required_workspace(path, args, params, context || %{}, opts) do
          {:ok, result} ->
            output = %{
              path: path,
              exit_code: result.exit_code,
              passed: result.exit_code == 0,
              stdout: result.stdout,
              stderr: result.stderr
            }

            Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
            {:ok, output}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "mix format failed to execute: #{MixAction.format_error(reason)}"}
        end
      else
        {:error, reason} ->
          {:error, "mix format rejected invalid invocation: #{inspect(reason)}"}
      end
    end

    def run(_params, _context),
      do: {:error, "mix format rejected invalid invocation: :invalid_format_params"}

    defp build_invocation(params) do
      with :ok <- validate_option_keys(params),
           {:ok, path} <- validate_root(params[:path]),
           {:ok, check_only} <- validate_check_only(Map.get(params, :check_only, false)),
           {:ok, files} <- validate_files(path, Map.get(params, :files)) do
        options = if check_only, do: ["--check-formatted"], else: []
        file_args = if files == [], do: [], else: ["--" | files]
        {:ok, path, ["format"] ++ options ++ file_args}
      end
    end

    defp validate_option_keys(params) do
      if Enum.all?(Map.keys(params), &(&1 in [:path, :workspace_id, :check_only, :files])),
        do: :ok,
        else: {:error, :unsupported_format_option}
    end

    defp validate_root(path) when is_binary(path) and path != "" do
      case SafePath.resolve_real(path) do
        {:ok, canonical} ->
          if File.dir?(canonical), do: {:ok, canonical}, else: {:error, :invalid_format_root}

        _other ->
          {:error, :invalid_format_root}
      end
    end

    defp validate_root(_path), do: {:error, :invalid_format_root}

    defp validate_check_only(value) when is_boolean(value), do: {:ok, value}
    defp validate_check_only(_value), do: {:error, :invalid_check_only}

    defp validate_files(_root, nil), do: {:ok, []}
    defp validate_files(_root, []), do: {:ok, []}

    defp validate_files(root, files) when is_list(files) do
      Enum.reduce_while(files, {:ok, []}, fn file, {:ok, accepted} ->
        case validate_file(root, file) do
          :ok -> {:cont, {:ok, [file | accepted]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
        error -> error
      end
    end

    defp validate_files(_root, _files), do: {:error, :invalid_format_files}

    defp validate_file(root, file) when is_binary(file) do
      components = Path.split(file)

      valid_shape? =
        file != "" and byte_size(file) <= 4_096 and String.valid?(file) and
          not String.contains?(file, [<<0>>, "\n", "\r", "\\"]) and
          not Regex.match?(~r/[\x00-\x1F\x7F]/u, file) and
          not String.starts_with?(file, "-") and Path.type(file) == :relative and
          Enum.all?(components, &(&1 not in ["", ".", ".."])) and
          Regex.match?(~r/\A[A-Za-z0-9_.()&+@ -]+(?:\/[A-Za-z0-9_.()&+@ -]+)*\z/, file)

      candidate = Path.expand(file, root)

      with true <- valid_shape?,
           {:ok, canonical} <- SafePath.resolve_real(candidate),
           true <- canonical == root or String.starts_with?(canonical, root <> "/"),
           true <- File.regular?(canonical) do
        :ok
      else
        _other -> {:error, {:invalid_format_file, file}}
      end
    end

    defp validate_file(_root, file), do: {:error, {:invalid_format_file, file}}
  end

  defmodule Xref do
    @moduledoc """
    Run bounded `mix xref` forms (graph / stats) under an owner-issued workspace.

    Unsupported xref flags fail closed at the action/parser boundary rather than
    falling through to raw Shell.Execute.
    """

    use Jido.Action,
      name: "mix_xref",
      description: "Run bounded `mix xref` in a project directory",
      category: "mix",
      tags: ["mix", "xref", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        workspace_id: [
          type: :string,
          required: true,
          doc: "Opaque workspace lease id for owner-scoped validation resources"
        ],
        mode: [
          type: :string,
          default: "graph",
          doc: "xref mode (currently only graph)"
        ],
        format: [
          type: :string,
          doc: "Optional --format for graph mode (stats|cycles|linked)"
        ],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        workspace_id: :control,
        mode: :control,
        format: :control,
        timeout: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, args} <- build_args(params) do
        opts = MixAction.timeout_opts(params) ++ [bind_committable_tree: true]

        case MixAction.run_with_required_workspace(path, args, params, context || %{}, opts) do
          {:ok, result} ->
            feedback = MixAction.compile_feedback(result)

            output = %{
              path: path,
              exit_code: result.exit_code,
              passed: result.exit_code == 0,
              stdout: result.stdout,
              stderr: result.stderr,
              feedback: feedback,
              feedback_json: Jason.encode!(feedback),
              validated_tree_oid: Map.get(result, :validated_tree_oid),
              validated_head: Map.get(result, :validated_head)
            }

            Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
            {:ok, output}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "mix xref failed to execute: #{MixAction.format_error(reason)}"}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix xref rejected invalid invocation: #{inspect(reason)}"}
      end
    end

    defp build_args(params) do
      mode = Map.get(params, :mode) || Map.get(params, "mode") || "graph"
      format = Map.get(params, :format) || Map.get(params, "format")

      cond do
        mode != "graph" ->
          {:error, :unsupported_xref_mode}

        is_binary(format) and format not in ["stats", "cycles", "linked"] ->
          {:error, :unsupported_xref_format}

        is_binary(format) ->
          {:ok, ["xref", "graph", "--format", format]}

        true ->
          {:ok, ["xref", "graph"]}
      end
    end
  end
end
