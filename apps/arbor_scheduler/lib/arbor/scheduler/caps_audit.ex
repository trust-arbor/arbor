defmodule Arbor.Scheduler.CapsAudit do
  @moduledoc """
  Runtime scanner for scheduler pipeline capability files.

  This module intentionally lives outside Mix task code so operational commands
  can RPC into a running Arbor node and evaluate `.caps.json` files against that
  node's live `IssuerRegistry`/identity state.
  """

  alias Arbor.Scheduler.CapsFile
  alias Arbor.Scheduler.CapsFile.Attestation

  @type pipeline_status :: {:ok, Attestation.t()} | :missing | {:error, term()}
  @type result :: {String.t(), pipeline_status()}

  @doc """
  Scan `dir` for `.dot` pipelines and load matching `.caps.json` files.

  Returns `{:ok, results}` where each result is `{pipeline_base_name, status}`.
  Returns `{:error, {:read_failed, dir, reason}}` when the directory cannot be
  listed.
  """
  @spec scan(Path.t()) :: {:ok, [result()]} | {:error, {:read_failed, Path.t(), term()}}
  def scan(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        results =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".dot"))
          |> Enum.sort()
          |> Enum.map(&scan_pipeline(dir, &1))

        {:ok, results}

      {:error, reason} ->
        {:error, {:read_failed, dir, reason}}
    end
  end

  @doc """
  True when any scanned caps file failed verification.

  Missing `.caps.json` files are reported separately. PipelineRunner still
  refuses them at execution time.
  """
  @spec errors?([result()]) :: boolean()
  def errors?(results), do: Enum.any?(results, &match?({_, {:error, _}}, &1))

  @doc """
  Count OK, missing, and error entries in a scan result.
  """
  @spec counts([result()]) :: %{
          ok: non_neg_integer(),
          missing: non_neg_integer(),
          error: non_neg_integer()
        }
  def counts(results) do
    %{
      ok: Enum.count(results, &match?({_, {:ok, _}}, &1)),
      missing: Enum.count(results, &match?({_, :missing}, &1)),
      error: Enum.count(results, &match?({_, {:error, _}}, &1))
    }
  end

  defp scan_pipeline(dir, dot) do
    base = String.replace_trailing(dot, ".dot", "")
    caps_path = Path.join(dir, "#{base}.caps.json")

    status =
      if File.exists?(caps_path) do
        CapsFile.load(caps_path)
      else
        :missing
      end

    {base, status}
  end
end
