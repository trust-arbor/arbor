defmodule Arbor.KernelRuntime.ProviderGate.SDKPath do
  @moduledoc false

  # Pure decisions over observations gathered only from the current VM SDK.
  # These functions do not resolve paths, read files, or alter the code path.
  def validate_root(root, lib) when is_binary(root) and is_binary(lib) do
    if Path.type(root) == :absolute and lib == Path.join(root, "lib"),
      do: :ok,
      else: {:error, :unsafe}
  end

  def validate_root(_root, _lib), do: {:error, :unsafe}

  def one_component(entries) when is_list(entries) do
    case Enum.filter(entries, &(&1 == "os_mon" or String.starts_with?(&1, "os_mon-"))) do
      [] ->
        {:error, :missing}

      [name] ->
        if Regex.match?(~r/\Aos_mon(?:-[0-9]+(?:\.[0-9]+)*)?\z/, name),
          do: {:ok, name},
          else: {:error, :unsafe}

      _multiple ->
        {:error, :ambiguous}
    end
  end

  def validate_entry(path, resolved, info, type, uid)
      when is_binary(path) and is_integer(uid) do
    case {resolved, info} do
      {{:ok, ^path}, {:ok, %File.Stat{type: ^type, uid: ^uid, mode: mode, links: links}}}
      when is_integer(mode) and is_integer(links) ->
        if :erlang.band(mode, 0o022) == 0 and (type != :regular or links == 1),
          do: :ok,
          else: {:error, :unsafe}

      _other ->
        {:error, :unsafe}
    end
  end

  def validate_entry(_path, _resolved, _info, _type, _uid), do: {:error, :unsafe}
end
