defmodule Arbor.Shell.ValidationRuntime.AppleContainer do
  @moduledoc false

  @behaviour Arbor.Shell.ValidationRuntime

  alias Arbor.Shell.AppleContainerControlPlaneAuthority
  alias Arbor.Shell.AppleContainerExecutor

  @impl true
  @spec execute(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, args, opts), do: AppleContainerExecutor.execute(tool_name, args, opts)

  @impl true
  @spec probe() :: {:ok, map()} | {:error, atom()}
  def probe do
    status = AppleContainerControlPlaneAuthority.public_status()

    case status do
      %{"state" => "pinned"} -> {:ok, status}
      %{"state" => "unsupported"} -> {:error, :apple_container_unsupported}
      _other -> {:error, :apple_container_unavailable}
    end
  end

  @impl true
  @spec public_status() :: map()
  def public_status do
    AppleContainerControlPlaneAuthority.public_status()
    |> Map.put("driver", "apple_container")
  end
end
