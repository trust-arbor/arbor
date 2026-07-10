defmodule Arbor.Orchestrator.CodingPlan.LoadedModuleIdentity do
  @moduledoc false

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

  # module_info/1 is served by the code loaded in the VM. beam_lib.md5/1 is
  # derived from the object bytes returned by the code server. They must agree
  # before those bytes can identify code that a subsequent remote call invokes.
  defp loaded_md5(module), do: apply(module, :module_info, [:md5])
end
