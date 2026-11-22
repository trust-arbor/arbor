defmodule Arbor.KernelRuntime.Feature do
  @moduledoc """
  Passive description of the current fixed Core host wiring.

  children/1 accepts exactly %{start_profile: :full | :activation_only,
  profile_admission: :admitted}. The admission value is an already resolved
  owner fact, not an authorization token or proof supplied by external input.
  Only trusted owner plumbing may supply this snapshot.

  The renderer never reads configuration, starts providers, creates references
  or invokes a child-spec producer. Missing, refused or malformed snapshots
  raise the same redacted ArgumentError. The host reports unresolved inputs
  before invoking this callback; it must not substitute an empty child list.

  Empty action/URI/route lists describe no additional DIRECT Application
  entrypoint contribution here. They make no assertion about nested services,
  runtime actions, resource URIs or release absence. Health is unobserved.
  """

  @behaviour Arbor.Contracts.Feature

  @invalid_snapshot "invalid feature snapshot"
  @provider_roots [:os_mon, :recon, :mint, :finch, :req]

  @impl true
  def id, do: :core

  @impl true
  def requires, do: []

  @impl true
  @spec children(map()) :: [Supervisor.child_spec()]
  def children(%{start_profile: profile, profile_admission: :admitted} = snapshot)
      when profile in [:activation_only, :full] do
    if exact_keys?(snapshot, [:start_profile, :profile_admission]) do
      case profile do
        :activation_only ->
          [owner_child()]

        :full ->
          [
            owner_child(),
            %{
              id: Arbor.KernelRuntime.ProviderGate,
              start:
                {Arbor.KernelRuntime.ProviderGate, :start_link,
                 [[name: Arbor.KernelRuntime.ProviderGate, roots: @provider_roots]]},
              type: :worker,
              restart: :permanent
            },
            %{
              id: Arbor.Common.Application,
              start: {Arbor.Common.Application, :start, [:normal, []]},
              type: :supervisor
            },
            %{
              id: Arbor.Signals.Application,
              start: {Arbor.Signals.Application, :start, [:normal, []]},
              type: :supervisor
            },
            %{
              id: Arbor.Monitor.Application,
              start: {Arbor.Monitor.Application, :start, [:normal, []]},
              type: :supervisor
            }
          ]
      end
    else
      invalid_snapshot!()
    end
  end

  def children(_snapshot), do: invalid_snapshot!()

  @impl true
  def action_modules, do: []

  @impl true
  def uri_prefixes, do: []

  @impl true
  def routes, do: []

  @impl true
  def health, do: %{status: :unobserved}

  defp owner_child do
    %{
      id: Arbor.KernelRuntime.BootProfileBinding,
      start: {Arbor.KernelRuntime.BootProfileBinding, :start_link, [[]]},
      type: :worker,
      restart: :permanent
    }
  end

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end

  defp invalid_snapshot!, do: raise(ArgumentError, @invalid_snapshot)
end
