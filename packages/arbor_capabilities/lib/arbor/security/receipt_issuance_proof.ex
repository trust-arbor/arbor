defmodule Arbor.Security.ReceiptIssuanceProof do
  @moduledoc false

  @tag :arbor_security_receipt_issuance_v1

  @doc false
  @spec admit(term(), pid(), atom()) :: {:ok, map()} | {:error, :receipt_issuance_unauthorized}
  def admit(proof, caller, expected_kind)
      when is_function(proof, 1) and is_pid(caller) and is_atom(expected_kind) do
    challenge = make_ref()

    with {:module, Arbor.Security} <- :erlang.fun_info(proof, :module),
         {:type, :local} <- :erlang.fun_info(proof, :type),
         {:arity, 1} <- :erlang.fun_info(proof, :arity),
         {@tag, ^challenge, ^caller, ^expected_kind, payload} <- proof.(challenge),
         true <- is_map(payload) do
      {:ok, payload}
    else
      _ -> {:error, :receipt_issuance_unauthorized}
    end
  rescue
    _ -> {:error, :receipt_issuance_unauthorized}
  catch
    _, _ -> {:error, :receipt_issuance_unauthorized}
  end

  def admit(_proof, _caller, _expected_kind),
    do: {:error, :receipt_issuance_unauthorized}
end
