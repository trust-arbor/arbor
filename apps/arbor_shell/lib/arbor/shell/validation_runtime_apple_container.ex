defmodule Arbor.Shell.ValidationRuntime.AppleContainer do
  @moduledoc false

  @behaviour Arbor.Shell.ValidationRuntime

  alias Arbor.Shell.AppleContainerExecutor
  alias Arbor.Shell.AppleContainerProber
  alias Arbor.Shell.AppleContainerControlPlaneAuthority
  alias Arbor.Shell.SpawnCapableTimeout

  @impl true
  @spec execute(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, args, opts), do: AppleContainerExecutor.execute(tool_name, args, opts)

  @impl true
  @spec probe() :: {:ok, map()} | {:error, term()}
  def probe do
    probe(SpawnCapableTimeout.max_probe_deadline_ms())
  end

  @impl true
  @spec probe(term()) :: {:ok, map()} | {:error, term()}
  def probe(deadline_ms) do
    probe_with(deadline_ms, &AppleContainerProber.probe/1, &public_status/0)
  end

  @doc false
  @spec probe_for_test((pos_integer() -> term()), (-> term())) ::
          {:ok, map()} | {:error, term()}
  def probe_for_test(prober, status_provider)
      when is_function(prober, 1) and is_function(status_provider, 0) do
    probe_for_test(SpawnCapableTimeout.max_probe_deadline_ms(), prober, status_provider)
  end

  @doc false
  @spec probe_for_test(term(), (term() -> term()), (-> term())) ::
          {:ok, map()} | {:error, term()}
  def probe_for_test(deadline_ms, prober, status_provider)
      when is_function(prober, 1) and is_function(status_provider, 0) do
    probe_with(deadline_ms, prober, status_provider)
  end

  defp probe_with(deadline_ms, prober, status_provider) do
    case prober.(deadline_ms) do
      {:ok, _admission} ->
        case status_provider.() do
          %{"state" => "pinned"} = status -> {:ok, status}
          %{"state" => "unsupported"} -> {:error, :apple_container_unsupported}
          _other -> {:error, :apple_container_unavailable}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :apple_container_unavailable}
    end
  end

  @impl true
  @spec public_status() :: map()
  def public_status do
    AppleContainerControlPlaneAuthority.public_status()
    |> Map.put("driver", "apple_container")
  end
end
