defmodule Arbor.Memory.MutationAdmission.OwnerRoots do
  @moduledoc false

  # Imperative helper over public MutationAdmission.acquire/1 and release/1.
  # Not an authority, process, backend, or facade.

  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.Lease

  defstruct by_agent: %{}

  @type t :: %__MODULE__{by_agent: %{optional(String.t()) => [Lease.t()]}}

  @spec new() :: t()
  def new, do: %__MODULE__{by_agent: %{}}

  @spec admit_new(t(), String.t()) :: {:ok, Lease.t()} | {:error, atom()}
  def admit_new(%__MODULE__{} = _roots, agent_id) do
    MutationAdmission.acquire(agent_id)
  end

  @spec defer(t(), String.t(), Lease.t()) :: {:ok, t()} | {:error, :invalid_lease}
  def defer(%__MODULE__{} = roots, agent_id, %Lease{} = lease) do
    if lease.agent_id == agent_id do
      held = agent_leases(roots, agent_id)

      next_held =
        if Enum.any?(held, &(&1 == lease)) do
          held
        else
          held ++ [lease]
        end

      {:ok, put_agent_leases(roots, agent_id, next_held)}
    else
      {:error, :invalid_lease}
    end
  end

  def defer(%__MODULE__{} = _roots, _agent_id, _lease), do: {:error, :invalid_lease}

  @spec ack(t(), Lease.t()) :: {t(), :ok | {:error, atom()}}
  def ack(%__MODULE__{by_agent: by_agent} = roots, %Lease{} = lease) do
    result = MutationAdmission.release(lease)

    next_by_agent =
      by_agent
      |> Enum.reduce(%{}, fn {agent_id, leases}, acc ->
        remaining = Enum.reject(leases, &(&1 == lease))

        if remaining == [] do
          acc
        else
          Map.put(acc, agent_id, remaining)
        end
      end)

    {%{roots | by_agent: next_by_agent}, result}
  end

  @spec settle_agent(t(), String.t(), Lease.t() | nil) :: {t(), :ok}
  def settle_agent(%__MODULE__{} = roots, agent_id, lease_or_nil \\ nil) do
    held = agent_leases(roots, agent_id)

    to_release =
      case lease_or_nil do
        %Lease{} = lease ->
          if Enum.any?(held, &(&1 == lease)), do: held, else: held ++ [lease]

        _ ->
          held
      end

    Enum.each(to_release, &MutationAdmission.release/1)
    {put_agent_leases(roots, agent_id, []), :ok}
  end

  @spec ensure_deferred_root(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def ensure_deferred_root(%__MODULE__{} = roots, agent_id) do
    if held?(roots, agent_id) do
      {:ok, roots}
    else
      case admit_new(roots, agent_id) do
        {:ok, lease} -> defer(roots, agent_id, lease)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec held?(t(), String.t()) :: boolean()
  def held?(%__MODULE__{} = roots, agent_id) do
    held_count(roots, agent_id) > 0
  end

  @spec held_count(t(), String.t()) :: non_neg_integer()
  def held_count(%__MODULE__{} = roots, agent_id) do
    length(agent_leases(roots, agent_id))
  end

  defp agent_leases(%__MODULE__{by_agent: by_agent}, agent_id) do
    Map.get(by_agent, agent_id, [])
  end

  defp put_agent_leases(%__MODULE__{} = roots, agent_id, []) do
    %{roots | by_agent: Map.delete(roots.by_agent, agent_id)}
  end

  defp put_agent_leases(%__MODULE__{} = roots, agent_id, leases) when is_list(leases) do
    %{roots | by_agent: Map.put(roots.by_agent, agent_id, leases)}
  end

  defimpl Inspect do
    def inspect(%{by_agent: by_agent}, _opts) do
      counts = Map.new(by_agent, fn {agent_id, leases} -> {agent_id, length(leases)} end)
      "#MutationAdmission.OwnerRoots<#{inspect(counts)}>"
    end
  end
end
