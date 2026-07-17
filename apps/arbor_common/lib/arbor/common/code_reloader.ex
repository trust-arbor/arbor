defmodule Arbor.Common.CodeReloader do
  @moduledoc false

  @max_beam_bytes 16 * 1024 * 1024

  @type failure :: {atom(), term()}
  @type summary :: %{
          checked: non_neg_integer(),
          unchanged: non_neg_integer(),
          reloaded: [module()],
          failures: [failure()]
        }

  @spec reload_changed() :: summary()
  def reload_changed do
    {modules, discovery_failures} = loaded_project_modules()

    modules
    |> Enum.reduce(
      %{
        checked: length(modules),
        unchanged: 0,
        reloaded: [],
        failures: discovery_failures
      },
      fn {module, ebin}, summary ->
        case reload_module(module, ebin) do
          :unchanged -> Map.update!(summary, :unchanged, &(&1 + 1))
          {:reloaded, ^module} -> Map.update!(summary, :reloaded, &[module | &1])
          {:error, reason} -> Map.update!(summary, :failures, &[{module, reason} | &1])
        end
      end
    )
    |> Map.update!(:reloaded, &Enum.reverse/1)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  @doc false
  @spec reload_module(module(), Path.t()) :: :unchanged | {:reloaded, module()} | {:error, term()}
  def reload_module(module, expected_ebin) when is_atom(module) and is_binary(expected_ebin) do
    with {:ok, live_md5} <- loaded_md5(module),
         {:ok, disk} <- read_disk_beam(module, expected_ebin) do
      if live_md5 == disk.md5 do
        :unchanged
      else
        reload_stale_module(module, expected_ebin, live_md5, disk)
      end
    end
  end

  def reload_module(_module, _expected_ebin), do: {:error, :invalid_module_identity}

  defp reload_stale_module(module, expected_ebin, expected_live_md5, expected_disk) do
    with {:ok, live_md5} <- loaded_md5(module),
         {:ok, disk} <- read_disk_beam(module, expected_ebin) do
      cond do
        live_md5 == disk.md5 ->
          :unchanged

        live_md5 != expected_live_md5 ->
          {:error, :loaded_code_changed_during_reload}

        disk.md5 != expected_disk.md5 ->
          {:error, :disk_code_changed_during_reload}

        not :code.soft_purge(module) ->
          {:error, :old_code_in_use}

        true ->
          load_and_verify(module, disk)
      end
    end
  end

  defp load_and_verify(module, disk) do
    case :code.load_binary(module, String.to_charlist(disk.filename), disk.beam) do
      {:module, ^module} ->
        case loaded_md5(module) do
          {:ok, md5} when md5 == disk.md5 -> {:reloaded, module}
          {:ok, _other_md5} -> {:error, :loaded_code_does_not_match_disk}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:load_failed, reason}}

      other ->
        {:error, {:unexpected_load_result, other}}
    end
  end

  defp loaded_project_modules do
    Application.loaded_applications()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&arbor_application?/1)
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn app, {modules, failures} ->
      case application_modules(app) do
        {:ok, app_modules} -> {app_modules ++ modules, failures}
        {:error, reason} -> {modules, [{app, reason} | failures]}
      end
    end)
    |> then(fn {modules, failures} ->
      modules =
        modules
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.filter(fn {module, _ebin} -> :code.is_loaded(module) != false end)
        |> Enum.sort_by(fn {module, _ebin} -> Atom.to_string(module) end)

      {modules, failures}
    end)
  end

  defp application_modules(app) do
    case {Application.spec(app, :modules), :code.lib_dir(app)} do
      {modules, lib_dir} when is_list(modules) and is_list(lib_dir) ->
        ebin = lib_dir |> List.to_string() |> Path.join("ebin") |> Path.expand()
        {:ok, Enum.map(modules, &{&1, ebin})}

      {nil, _ebin} ->
        {:error, :application_modules_unavailable}

      {_modules, {:error, reason}} ->
        {:error, {:application_ebin_unavailable, reason}}

      _other ->
        {:error, :invalid_application_metadata}
    end
  end

  defp read_disk_beam(module, expected_ebin) do
    with path when is_list(path) <- :code.which(module),
         filename <- path |> List.to_string() |> Path.expand(),
         :ok <- validate_ebin(filename, expected_ebin),
         {:ok, beam} <- File.read(filename),
         :ok <- validate_beam_size(beam),
         {:ok, {^module, md5}} <- :beam_lib.md5(beam) do
      {:ok, %{beam: beam, filename: filename, md5: md5}}
    else
      :non_existing -> {:error, :beam_not_found}
      :preloaded -> {:error, :preloaded_module}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_beam}
    end
  rescue
    _exception -> {:error, :invalid_beam}
  end

  defp validate_ebin(filename, expected_ebin) do
    if Path.dirname(filename) == Path.expand(expected_ebin),
      do: :ok,
      else: {:error, :beam_outside_application_ebin}
  end

  defp validate_beam_size(beam) do
    if byte_size(beam) > 0 and byte_size(beam) <= @max_beam_bytes,
      do: :ok,
      else: {:error, :invalid_beam_size}
  end

  defp loaded_md5(module) do
    case apply(module, :module_info, [:md5]) do
      md5 when is_binary(md5) -> {:ok, md5}
      _other -> {:error, :loaded_md5_unavailable}
    end
  rescue
    _exception -> {:error, :loaded_md5_unavailable}
  end

  defp arbor_application?(app),
    do: app |> Atom.to_string() |> String.starts_with?("arbor_")
end
