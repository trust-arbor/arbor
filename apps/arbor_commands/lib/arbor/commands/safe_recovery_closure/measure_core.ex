defmodule Arbor.Commands.SafeRecoveryClosure.MeasureCore do
  @moduledoc false

  # Pure step order for one held trusted-build + probe. No IO.

  @steps [
    :stage_source,
    :acquire_build,
    {:run_phase, "deps_get"},
    :stage_native,
    :inventory_deps,
    {:run_phase, "compile"},
    {:run_phase, "release"},
    :remove_cookie,
    :inventory_release,
    :pin_root,
    :measure
  ]

  @spec init() :: map()
  def init do
    %{
      steps: @steps,
      source: nil,
      build: nil,
      release_root: nil,
      measurement: nil
    }
  end

  @spec steps() :: [term()]
  def steps, do: @steps

  @spec next(map()) ::
          {:effect, term(), map()} | {:done, {:ok, map()} | {:error, term()}} | {:error, term()}
  def next(%{steps: []} = state) do
    case state.measurement do
      %{} = measurement -> {:done, {:ok, measurement}}
      _ -> {:error, :measure_missing}
    end
  end

  def next(%{steps: [step | rest]} = state) do
    {:effect, step, %{state | steps: rest}}
  end

  @spec step_result(map(), term(), term()) :: {:ok, map()} | {:error, term()}
  def step_result(state, :stage_source, {:ok, lease}) do
    {:ok, %{state | source: lease}}
  end

  def step_result(_state, :stage_source, {:error, {:cleanup_retained, reason, _identity}}) do
    {:error, {:source_staging_failed, reason}}
  end

  def step_result(_state, :stage_source, {:error, reason}), do: {:error, reason}

  def step_result(state, :acquire_build, {:ok, handle}) do
    {:ok, %{state | build: handle}}
  end

  def step_result(_state, :acquire_build, {:error, reason}), do: {:error, reason}

  def step_result(
        state,
        {:run_phase, _phase},
        {:ok, %{exit_code: 0, timed_out: false, killed: false}}
      ) do
    {:ok, state}
  end

  def step_result(_state, {:run_phase, phase}, {:ok, result}) do
    {:error, {:trusted_build_phase_failed, phase, result}}
  end

  def step_result(_state, {:run_phase, phase}, {:error, reason}) do
    {:error, {:trusted_build_phase_failed, phase, reason}}
  end

  def step_result(state, :stage_native, {:ok, _result}), do: {:ok, state}
  def step_result(_state, :stage_native, {:error, reason}), do: {:error, reason}

  def step_result(state, :inventory_deps, {:ok, _document}), do: {:ok, state}
  def step_result(_state, :inventory_deps, {:error, reason}), do: {:error, reason}

  def step_result(state, :remove_cookie, {:ok, _result}), do: {:ok, state}
  def step_result(_state, :remove_cookie, {:error, reason}), do: {:error, reason}

  def step_result(state, :inventory_release, {:ok, _document}), do: {:ok, state}
  def step_result(_state, :inventory_release, {:error, reason}), do: {:error, reason}

  def step_result(state, :pin_root, {:ok, path}) when is_binary(path) do
    {:ok, %{state | release_root: path}}
  end

  def step_result(_state, :pin_root, {:error, reason}), do: {:error, reason}
  def step_result(_state, :pin_root, _other), do: {:error, :invalid_release_root}

  def step_result(state, :measure, {:ok, measurement}) when is_map(measurement) do
    {:ok, %{state | measurement: measurement}}
  end

  def step_result(_state, :measure, {:error, reason}), do: {:error, reason}
  def step_result(_state, :measure, _other), do: {:error, :invalid_measurement}
end
