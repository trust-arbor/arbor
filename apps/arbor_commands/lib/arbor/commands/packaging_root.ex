defmodule Arbor.Commands.PackagingRoot do
  @moduledoc false

  alias Arbor.Common.SafePath

  @markers [
    "mix.exs",
    "apps/arbor_commands/mix.exs",
    "apps/arbor_kernel/mix.exs"
  ]

  @spec resolve(nil | String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(nil), do: discover(File.cwd!())

  def resolve(path) when is_binary(path) do
    case SafePath.validate(path) do
      :ok ->
        expanded = Path.expand(path)

        if root?(expanded) do
          {:ok, expanded}
        else
          {:error, :invalid_root_marker}
        end

      {:error, reason} ->
        {:error, {:root_path, reason}}
    end
  end

  def resolve(_), do: {:error, :invalid_root}

  @spec discover(String.t()) :: {:ok, String.t()} | {:error, term()}
  def discover(start) when is_binary(start), do: find_root(Path.expand(start))
  def discover(_), do: {:error, :invalid_root}

  @spec root?(term()) :: boolean()
  def root?(dir) when is_binary(dir) do
    Enum.all?(@markers, &File.regular?(Path.join(dir, &1)))
  end

  def root?(_), do: false

  defp find_root(dir) do
    cond do
      root?(dir) -> {:ok, dir}
      Path.dirname(dir) == dir -> {:error, :umbrella_root_not_found}
      true -> find_root(Path.dirname(dir))
    end
  end
end
