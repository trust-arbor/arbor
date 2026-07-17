defmodule Arbor.Shell.SpawnCapableTimeout do
  @moduledoc """
  Pure system ceilings for spawn-capable execution wall-clock timeouts.

  Single Shell-owned source of truth for the maximum `:timeout` accepted by
  `Arbor.Shell.execute_spawn_capable/3` and the Apple Container unit admission
  path. Ceilings are closed and keyed by the existing resource profile:

    * `:standard` — 600_000 ms (default; historical units)
    * `:intensive` — 1_200_000 ms (reviewed high-capacity units only)

  Fail-closed: values above the selected profile's ceiling are rejected without
  clamping. A caller cannot request an intensive timeout under `:standard`, and
  unknown profiles are rejected.

  Higher libraries must read the bound only through the public
  `Arbor.Shell.spawn_capable_max_timeout_ms/0` and
  `Arbor.Shell.spawn_capable_max_timeout_ms/1` facades.
  """

  @standard_max_timeout_ms 600_000
  @intensive_max_timeout_ms 1_200_000
  @profile_max_timeouts %{
    standard: @standard_max_timeout_ms,
    intensive: @intensive_max_timeout_ms
  }
  @max_probe_deadline_ms 300_000
  @min_timeout_ms 1

  @type resource_profile :: :standard | :intensive

  @doc """
  Non-bypassable hard maximum for the default (`:standard`) profile (ms).

  Preserves the historical single-ceiling contract for consumers that have not
  selected `:intensive`.
  """
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @standard_max_timeout_ms

  @doc """
  Non-bypassable hard maximum for a closed resource profile (ms).

  Returns `{:ok, ms}` for `:standard` | `:intensive`, otherwise
  `{:error, :invalid_resource_profile}` — never raises and never clamps.
  """
  @spec max_timeout_ms(term()) ::
          {:ok, pos_integer()} | {:error, :invalid_resource_profile}
  def max_timeout_ms(profile) when is_atom(profile) do
    case Map.fetch(@profile_max_timeouts, profile) do
      {:ok, ms} -> {:ok, ms}
      :error -> {:error, :invalid_resource_profile}
    end
  end

  def max_timeout_ms(_other), do: {:error, :invalid_resource_profile}

  @doc """
  Validate a wall-clock timeout against a closed resource profile.

  Returns:
  - `:ok` when `timeout` is an integer in `min_timeout_ms()..ceiling`
  - `{:error, :timeout_too_large}` when above the profile ceiling
  - `{:error, :timeout_too_small}` when below the minimum
  - `{:error, :invalid_resource_profile}` for unknown profiles
  - `{:error, :invalid_timeout}` for non-integer timeouts
  """
  @spec validate_timeout_ms(term(), term()) ::
          :ok
          | {:error,
             :timeout_too_large
             | :timeout_too_small
             | :invalid_timeout
             | :invalid_resource_profile}
  def validate_timeout_ms(timeout, profile) when is_integer(timeout) do
    with {:ok, max} <- max_timeout_ms(profile) do
      cond do
        timeout < @min_timeout_ms -> {:error, :timeout_too_small}
        timeout > max -> {:error, :timeout_too_large}
        true -> :ok
      end
    end
  end

  def validate_timeout_ms(_timeout, _profile), do: {:error, :invalid_timeout}

  @doc "Hard maximum for the admission probe sub-deadline (ms)."
  @spec max_probe_deadline_ms() :: pos_integer()
  def max_probe_deadline_ms, do: @max_probe_deadline_ms

  @doc "Minimum accepted spawn-capable execution timeout (ms)."
  @spec min_timeout_ms() :: pos_integer()
  def min_timeout_ms, do: @min_timeout_ms
end
