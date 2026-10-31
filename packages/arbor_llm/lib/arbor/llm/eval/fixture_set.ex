defmodule Arbor.LLM.Eval.FixtureSet do
  @moduledoc false

  @maximum_path_bytes 4_096
  def selection(opts) do
    case Keyword.fetch(opts, :fixture_set) do
      :error ->
        {:ok, nil}

      {:ok, name} ->
        with {:ok, _scope} <- resolve(name), do: {:ok, name}
    end
  end

  # Only an operator-configured name crosses the adapter boundary. A caller
  # cannot supply the mode or destination through transport options.
  def resolve(name) when is_binary(name) and byte_size(name) in 1..64 do
    if String.valid?(name) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, name) do
      lookup(name, Application.get_env(:arbor_llm, :eval_fixture_sets, %{}))
    else
      {:error, :invalid_eval_fixture_set_name}
    end
  end

  def resolve(_name), do: {:error, :invalid_eval_fixture_set_name}

  defp lookup(name, sets) when is_map(sets) and not is_struct(sets) do
    case Map.fetch(sets, name) do
      {:ok, config} -> validate_config(name, config)
      :error -> {:error, {:unknown_eval_fixture_set, name}}
    end
  end

  defp lookup(_name, _sets), do: {:error, :invalid_eval_fixture_sets_config}

  defp validate_config(name, %{mode: mode, path: path} = config)
       when mode in [:record, :replay] and is_binary(path) do
    if map_size(config) == 2 and byte_size(path) in 1..@maximum_path_bytes and
         String.valid?(path) and not String.contains?(path, <<0>>) and
         Path.type(path) == :absolute do
      {:ok, %{set: name, mode: mode, path: Path.expand(path)}}
    else
      {:error, {:invalid_eval_fixture_set_config, name}}
    end
  end

  defp validate_config(name, _config),
    do: {:error, {:invalid_eval_fixture_set_config, name}}
end
