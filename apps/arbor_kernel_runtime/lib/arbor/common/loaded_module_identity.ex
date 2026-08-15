defmodule Arbor.Common.LoadedModuleIdentity do
  @moduledoc """
  Binds retrievable BEAM bytes to the module code currently loaded by the VM.

  `:code.get_object_code/1` may return bytes from the code path after a module
  has been hot-reloaded. The loaded module MD5 must therefore agree with the
  object-code MD5 before those bytes are safe to identify executable code.
  """

  @spec sha256(module()) :: {:ok, String.t()} | {:error, atom()}
  def sha256(module) when is_atom(module) do
    with loaded_md5_before when is_binary(loaded_md5_before) <- loaded_md5(module),
         {^module, beam, _filename} when is_binary(beam) and byte_size(beam) > 0 <-
           :code.get_object_code(module),
         {:ok, {^module, object_md5}} <- :beam_lib.md5(beam),
         loaded_md5_after when is_binary(loaded_md5_after) <- loaded_md5(module),
         true <- loaded_md5_before == object_md5 and loaded_md5_after == object_md5 do
      {:ok, beam |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    else
      false -> {:error, :loaded_object_code_mismatch}
      _other -> {:error, :module_object_code_unavailable}
    end
  rescue
    _exception -> {:error, :module_object_code_unavailable}
  catch
    _kind, _reason -> {:error, :module_object_code_unavailable}
  end

  def sha256(_module), do: {:error, :module_object_code_unavailable}

  defp loaded_md5(module), do: apply(module, :module_info, [:md5])
end
