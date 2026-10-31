defmodule Arbor.Historian.Ports.AuthoritySource do
  @moduledoc false
  @behaviour Arbor.Historian.Contracts.AuthoritySource
  alias Arbor.Historian.Config

  @callbacks [
    reconcile_authority_audit: 0,
    authority_audit_delivery_batch: 0,
    acknowledge_authority_audit: 2
  ]

  @impl true
  def reconcile_authority_audit, do: invoke(:reconcile_authority_audit, [])
  @impl true
  def authority_audit_delivery_batch, do: invoke(:authority_audit_delivery_batch, [])
  @impl true
  def acknowledge_authority_audit(id, digest),
    do: invoke(:acknowledge_authority_audit, [id, digest])

  defp invoke(function, args) do
    provider = Config.authority_source()

    if is_atom(provider) and provider not in [nil, true, false, __MODULE__] and
         Code.ensure_loaded?(provider) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(provider, name, arity) end) do
      admit(function, apply(provider, function, args))
    else
      {:error, :security_provider_unavailable}
    end
  rescue
    _ -> {:error, :security_provider_unavailable}
  catch
    _, _ -> {:error, :security_provider_unavailable}
  end

  defp admit(_function, {:error, _} = error), do: error
  defp admit(:reconcile_authority_audit, :ok), do: :ok

  defp admit(:authority_audit_delivery_batch, {:ok, batch} = result) when is_list(batch) do
    if Enum.all?(batch, &(is_map(&1) and not is_struct(&1))),
      do: result,
      else: {:error, :invalid_authority_source_reply}
  end

  defp admit(:acknowledge_authority_audit, {:ok, _} = result), do: result
  defp admit(_function, _response), do: {:error, :invalid_authority_source_reply}
end
