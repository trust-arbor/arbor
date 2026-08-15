defmodule Arbor.Commands.AppEnvInventory do
  @moduledoc """
  Imperative shell for the retired app-env inventory.

  Production `run/1` only accepts CLI options. Synthetic inventory and Git
  runners are test-only via `run_for_test/1`.
  """

  alias Arbor.Commands.AppEnvInventory.{Core, Encode}
  alias Arbor.Commands.SourceCoupling.GitInventory
  alias Arbor.Commands.PackagingRoot

  @production_opt_keys [:mode, :json, :root]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @production_opt_keys do
      [] -> do_run(opts, allow_synthetic: false)
      unexpected -> {:error, {:production_opts_forbid_synthetic, unexpected}}
    end
  end

  def run(_), do: {:error, :invalid_opts}

  @doc false
  @spec run_for_test(keyword()) :: {:ok, map()} | {:error, term()}
  def run_for_test(opts) when is_list(opts) do
    do_run(opts, allow_synthetic: true)
  end

  def run_for_test(_), do: {:error, :invalid_opts}

  defp do_run(opts, allow_synthetic: allow_synthetic) do
    mode = Keyword.get(opts, :mode, "report")
    json? = Keyword.get(opts, :json, false) == true
    output = if json?, do: "json", else: "human"

    with {:ok, root} <- resolve_root(Keyword.get(opts, :root)),
         {:ok, inventory} <- load_inventory(root, opts, allow_synthetic),
         {:ok, report} <- Core.project(inventory) do
      {:ok, Core.show(report, mode: mode, output: output)}
    end
  end

  defp load_inventory(root, opts, allow_synthetic) do
    git_opts = Keyword.take(opts, [:run_git, :max_blob_bytes, :max_total_bytes])

    case Keyword.get(opts, :inventory) do
      inv when is_map(inv) ->
        if allow_synthetic do
          {:ok, Map.put(inv, :provenance_source, "test_injection")}
        else
          {:error, :synthetic_inventory_not_allowed}
        end

      nil ->
        if Keyword.has_key?(opts, :run_git) and not allow_synthetic do
          {:error, :synthetic_run_git_not_allowed}
        else
          case GitInventory.load_elixir_index(root, git_opts) do
            {:ok, inv} -> {:ok, Map.put(inv, :provenance_source, "git_index_blobs")}
            other -> other
          end
        end
    end
  end

  defp resolve_root(path), do: PackagingRoot.resolve(path)

  @doc false
  @spec encode_report(map()) :: {:ok, binary()} | {:error, term()}
  def encode_report(report), do: Encode.encode_report(report)
end
