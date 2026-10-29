defmodule Arbor.Contracts.Coding.PendingApprovalResourceId do
  @moduledoc """
  Contract-owned deterministic resource IDs for pending-approval reconciliation.

  Raw approval IDs are arbitrary bounded UTF-8 data. Only the hashed
  `approval_<hex>` form is safe to embed in later authorization URIs.
  """

  @sources ~w(consensus interaction)
  @max_approval_id_bytes 256
  @domain "arbor:coding:reconciliation:pending_approval:v1"
  @resource_id_pattern ~r/\Aapproval_[0-9a-f]{64}\z/

  @doc "Closed approval source enum as strings."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  Derive the canonical pending-approval resource ID.

  Preimage is domain-separated: domain, source, and raw approval_id joined by NUL.
  """
  @spec resource_id(String.t() | atom(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_pending_approval_resource_id}
  def resource_id(source, approval_id) do
    with {:ok, source_string} <- normalize_source(source),
         {:ok, approval_id} <- normalize_approval_id(approval_id) do
      preimage =
        IO.iodata_to_binary([
          @domain,
          0,
          source_string,
          0,
          approval_id
        ])

      digest =
        :crypto.hash(:sha256, preimage)
        |> Base.encode16(case: :lower)

      {:ok, "approval_" <> digest}
    else
      _ -> {:error, :invalid_pending_approval_resource_id}
    end
  rescue
    _ -> {:error, :invalid_pending_approval_resource_id}
  catch
    _, _ -> {:error, :invalid_pending_approval_resource_id}
  end

  @doc "Return true when value is a canonical approval_<64 lowercase hex> id."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(@resource_id_pattern, value)
  def valid?(_value), do: false

  defp normalize_source(source) when is_atom(source), do: normalize_source(Atom.to_string(source))

  defp normalize_source(source) when is_binary(source) and source in @sources, do: {:ok, source}
  defp normalize_source(_source), do: :error

  defp normalize_approval_id(approval_id)
       when is_binary(approval_id) and byte_size(approval_id) > 0 and
              byte_size(approval_id) <= @max_approval_id_bytes do
    if String.valid?(approval_id) and not String.contains?(approval_id, <<0>>),
      do: {:ok, approval_id},
      else: :error
  end

  defp normalize_approval_id(_approval_id), do: :error
end
