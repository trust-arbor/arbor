defmodule Arbor.Orchestrator.GraphRegistry do
  @moduledoc """
  Named registry for DOT graphs that can be invoked as sub-graphs.

  Uses `persistent_term` for storage. Graphs are registered by name
  and resolved to DOT strings at invocation time.

  ## Registration

      GraphRegistry.register("consensus-flow", "specs/pipelines/consensus-flow.dot")
      GraphRegistry.register("inline-graph", "digraph G { ... }")

  ## Resolution

      {:ok, dot_string} = GraphRegistry.resolve("consensus-flow")

  ## Auto-discovery

      GraphRegistry.register_directory("specs/pipelines/")
  """

  @key {__MODULE__, :graphs}

  @spec register(String.t(), String.t()) :: :ok
  def register(name, source) when is_binary(name) and is_binary(source) do
    put_graphs(Map.put(graphs(), name, source))
  end

  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve(name) when is_binary(name) do
    case Map.get(graphs(), name) do
      nil ->
        {:error, :not_found}

      source ->
        if String.ends_with?(source, ".dot") do
          read_file(source)
        else
          {:ok, source}
        end
    end
  end

  @spec unregister(String.t()) :: :ok
  def unregister(name) when is_binary(name) do
    put_graphs(Map.delete(graphs(), name))
  end

  @spec list() :: [String.t()]
  def list, do: Map.keys(graphs())

  @spec reset() :: :ok
  def reset, do: put_graphs(%{})

  @spec snapshot() :: map()
  def snapshot, do: graphs()

  @spec restore(map()) :: :ok
  def restore(saved) when is_map(saved), do: put_graphs(saved)

  @spec register_directory(String.t()) :: {:ok, non_neg_integer()}
  def register_directory(dir) when is_binary(dir) do
    expanded = Path.expand(dir)

    dot_files =
      case File.ls(expanded) do
        {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".dot"))
        {:error, _} -> []
      end

    Enum.each(dot_files, fn file ->
      name = Path.rootname(file)
      register(name, Path.join(expanded, file))
    end)

    {:ok, length(dot_files)}
  end

  # --- Private ---

  defp graphs do
    :persistent_term.get(@key, %{})
  end

  defp put_graphs(map) do
    :persistent_term.put(@key, map)
    :ok
  end

  defp read_file(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file_read, reason, expanded}}
    end
  end
end
