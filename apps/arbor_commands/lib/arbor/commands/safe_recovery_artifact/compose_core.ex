defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeCore do
  @moduledoc false

  # Pure reducer/fact boundary for the E0B2C3b two-build composer. No IO, no
  # process calls. next/1 walks a fixed closed step order and step_result/3
  # admits every raw Shell/SourceStaging result -- only the first failing
  # step is ever observed, so error precedence is a direct function of this
  # order.

  alias Arbor.Commands.SafeRecoveryArtifact.{Core, Encode, TrustedInventory}

  @steps [
    {:stage_source, :a},
    {:stage_source, :b},
    :compare_sources,
    {:acquire_build, :a},
    {:acquire_build, :b},
    {:run_phase, :a, "deps_get"},
    {:stage_native, :a},
    {:inventory_deps, :a},
    {:run_phase, :b, "deps_get"},
    {:stage_native, :b},
    {:inventory_deps, :b},
    :compare_deps,
    {:run_phase, :a, "compile"},
    {:run_phase, :b, "compile"},
    {:run_phase, :a, "release"},
    {:run_phase, :b, "release"},
    {:remove_cookie, :a},
    {:remove_cookie, :b},
    {:inventory_release, :a},
    {:inventory_release, :b},
    {:read_descriptors, :a},
    {:read_descriptors, :b}
  ]

  @source_fact_keys ["commit", "tree", "object_format", "build_inputs"]

  @spec init() :: map()
  def init do
    %{
      steps: @steps,
      source: %{a: nil, b: nil},
      build: %{a: nil, b: nil},
      deps: %{a: nil, b: nil},
      release_raw: %{a: nil, b: nil},
      release_projected: %{a: nil, b: nil},
      descriptors: %{a: nil, b: nil}
    }
  end

  @spec next(map()) ::
          {:effect, term(), map()} | {:done, {:ok, map()} | {:error, term()}} | {:error, term()}
  def next(%{steps: []} = state), do: {:done, project_candidate(state)}

  def next(%{steps: [:compare_sources | rest]} = state) do
    case compare_sources(state) do
      :ok -> next(%{state | steps: rest})
      {:error, _reason} = error -> error
    end
  end

  def next(%{steps: [:compare_deps | rest]} = state) do
    case compare_deps(state) do
      :ok -> next(%{state | steps: rest})
      {:error, _reason} = error -> error
    end
  end

  def next(%{steps: [step | rest]} = state) do
    {:effect, step, %{state | steps: rest}}
  end

  @spec step_result(map(), term(), term()) :: {:ok, map()} | {:error, term()}
  def step_result(state, {:stage_source, slot}, {:ok, lease}) do
    {:ok, put_in(state, [:source, slot], lease)}
  end

  # The C1 identity map (raw paths/inode/device) is private cleanup/runtime
  # state -- it is ledgered separately for the actual retry (see
  # ComposeShell/ComposeFactInterpreter), but it and the internal
  # :cleanup_retained tag must never themselves become part of the outcome
  # returned to a caller, whether the resolution is immediate or via a later
  # retry (preserved_outcome is set from this normalized value, not the raw
  # one).
  def step_result(_state, {:stage_source, slot}, {:error, {:cleanup_retained, reason, _identity}}) do
    {:error, {:source_staging_failed, slot, reason}}
  end

  def step_result(_state, {:stage_source, _slot}, {:error, reason}), do: {:error, reason}

  def step_result(state, {:acquire_build, slot}, {:ok, handle}) do
    {:ok, put_in(state, [:build, slot], handle)}
  end

  def step_result(_state, {:acquire_build, _slot}, {:error, reason}), do: {:error, reason}

  def step_result(
        state,
        {:run_phase, _slot, _phase},
        {:ok, %{exit_code: 0, timed_out: false, killed: false}}
      ) do
    {:ok, state}
  end

  def step_result(_state, {:run_phase, slot, phase}, {:ok, result}) do
    {:error, {:trusted_build_phase_failed, slot, phase, result}}
  end

  def step_result(_state, {:run_phase, slot, phase}, {:error, reason}) do
    {:error, {:trusted_build_phase_failed, slot, phase, reason}}
  end

  def step_result(state, {:stage_native, _slot}, {:ok, _result}), do: {:ok, state}
  def step_result(_state, {:stage_native, _slot}, {:error, reason}), do: {:error, reason}

  def step_result(state, {:inventory_deps, slot}, {:ok, document}) do
    case TrustedInventory.admit_deps(document) do
      {:ok, admitted} -> {:ok, put_in(state, [:deps, slot], admitted)}
      {:error, reason} -> {:error, reason}
    end
  end

  def step_result(_state, {:inventory_deps, _slot}, {:error, reason}), do: {:error, reason}

  def step_result(state, {:remove_cookie, _slot}, {:ok, _result}), do: {:ok, state}
  def step_result(_state, {:remove_cookie, _slot}, {:error, reason}), do: {:error, reason}

  def step_result(state, {:inventory_release, slot}, {:ok, document}) do
    with {:ok, admitted} <- TrustedInventory.admit_release(document),
         {:ok, projected} <- TrustedInventory.project_release_root(admitted) do
      state =
        state
        |> put_in([:release_raw, slot], admitted)
        |> put_in([:release_projected, slot], projected)

      {:ok, state}
    end
  end

  def step_result(_state, {:inventory_release, _slot}, {:error, reason}), do: {:error, reason}

  def step_result(state, {:read_descriptors, slot}, {:ok, raw_contents})
      when is_list(raw_contents) do
    admit_descriptors(state, slot, raw_contents)
  end

  def step_result(_state, {:read_descriptors, _slot}, {:error, reason}), do: {:error, reason}

  defp compare_sources(state) do
    a = state.source.a
    b = state.source.b

    if Enum.all?(@source_fact_keys, &(a[&1] == b[&1])) do
      :ok
    else
      {:error, :source_fact_disagreement}
    end
  end

  defp compare_deps(state) do
    if state.deps.a == state.deps.b do
      :ok
    else
      {:error, :dependency_inventory_disagreement}
    end
  end

  defp admit_descriptors(state, slot, raw_contents) do
    selectors = TrustedInventory.descriptor_selectors(state.release_raw[slot])
    rebase_by_selector = Map.new(selectors, & &1)
    expected = MapSet.new(selectors, fn {selector, _rebased} -> selector end)
    actual_paths = Enum.map(raw_contents, & &1["path"])
    actual = MapSet.new(actual_paths)

    cond do
      length(actual_paths) != length(Enum.uniq(actual_paths)) ->
        {:error, :duplicate_descriptor}

      not MapSet.subset?(actual, expected) ->
        {:error, :extra_descriptor}

      not MapSet.subset?(expected, actual) ->
        {:error, :missing_descriptor}

      true ->
        term_contents =
          Enum.map(raw_contents, fn %{"path" => selector, "bytes" => bytes} ->
            %{"path" => Map.fetch!(rebase_by_selector, selector), "bytes" => bytes}
          end)

        {:ok, put_in(state, [:descriptors, slot], term_contents)}
    end
  end

  defp project_candidate(state) do
    with {:ok, candidate} <- assemble_candidate(state) do
      Core.project(candidate)
    end
  end

  defp assemble_candidate(state) do
    source_a = state.source.a
    build_inputs = source_a["build_inputs"]

    with {:ok, tool_versions_sha256} <- fetch_input_digest(build_inputs, ".tool-versions"),
         {:ok, mix_lock_sha256} <- fetch_input_digest(build_inputs, "mix.lock") do
      candidate = %{
        "profile" => profile(),
        "source" => source(source_a),
        "toolchain" => toolchain(tool_versions_sha256, mix_lock_sha256),
        "release" => release(),
        "builds" => [snapshot(state, :a), snapshot(state, :b)]
      }

      {:ok, candidate}
    end
  end

  defp profile do
    %{
      "schema" => Encode.profile_schema(),
      "name" => Encode.profile_name(),
      "digest" => Encode.profile_digest_value(),
      "evidence_status" => "conformant",
      "architecture_status" => "blocked"
    }
  end

  defp source(lease) do
    %{
      "commit" => lease["commit"],
      "tree" => lease["tree"],
      "object_format" => lease["object_format"],
      "platform_inventory" => %{
        "platform_inventory_schema" => Encode.platform_inventory_schema(),
        "selected_file_count" => Encode.selected_file_count(),
        "selected_index_digest" => Encode.e0a_index_digest(),
        "entries_digest" => Encode.e0a_entries_digest(),
        "review_digest" => Encode.e0a_review_digest()
      },
      "build_inputs" => lease["build_inputs"]
    }
  end

  defp toolchain(tool_versions_sha256, mix_lock_sha256) do
    Map.merge(Encode.toolchain_constants(), %{
      "tool_versions_sha256" => tool_versions_sha256,
      "mix_lock_sha256" => mix_lock_sha256
    })
  end

  defp release do
    %{
      "name" => Encode.release_name(),
      "version" => Encode.release_version(),
      "logical_root" => Encode.logical_root()
    }
  end

  defp snapshot(state, slot) do
    %{
      "inventory" => state.release_projected[slot],
      "term_contents" => state.descriptors[slot]
    }
  end

  defp fetch_input_digest(build_inputs, path) do
    case Enum.find(build_inputs, &(&1["path"] == path)) do
      %{"sha256" => digest} -> {:ok, digest}
      nil -> {:error, {:missing_build_input, path}}
    end
  end
end
