defmodule Arbor.Orchestrator.RunLifecycle.LegacyJobAdapter do
  @moduledoc """
  Sole boundary allowed to read/mutate historical `JobRegistry` entries.

  Current pipeline execution never dual-writes JobRegistry. Recovery and
  the public facade discover legacy interrupted jobs only through this
  module; claim/abandon mutations for historical rows also pass here.
  """

  alias Arbor.Orchestrator.JobRegistry
  alias Arbor.Orchestrator.JobRegistry.Entry, as: JobEntry
  alias Arbor.Orchestrator.RunLifecycle.Adapter
  alias Arbor.Orchestrator.RunLifecycle.Record

  @doc "List interrupted historical jobs as typed lifecycle records."
  @spec list_interrupted() :: [Record.t()]
  def list_interrupted do
    JobRegistry.list_interrupted()
    |> Enum.map(&to_record/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "List historical jobs owned by a node."
  @spec list_by_owner(node() | String.t()) :: [Record.t()]
  def list_by_owner(node_name) do
    JobRegistry.list_by_owner(node_name)
    |> Enum.map(&to_record/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "List historical jobs with stale heartbeats."
  @spec list_stale_heartbeats(non_neg_integer(), DateTime.t()) :: [Record.t()]
  def list_stale_heartbeats(max_age_ms, %DateTime{} = now) do
    JobRegistry.list_stale_heartbeats(max_age_ms, now)
    |> Enum.map(&to_record/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Fetch one historical job as a Record, or nil."
  @spec get(String.t()) :: Record.t() | nil
  def get(run_id) when is_binary(run_id) do
    case JobRegistry.get(run_id) do
      nil -> nil
      entry -> to_record(entry)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc "Atomically claim a historical interrupted job for recovery."
  @spec claim_for_recovery(String.t(), node()) :: {:ok, Record.t()} | {:error, term()}
  def claim_for_recovery(run_id, claiming_node \\ Kernel.node()) when is_binary(run_id) do
    case JobRegistry.claim_for_recovery(run_id, claiming_node) do
      {:ok, entry} -> {:ok, to_record(entry)}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec mark_interrupted(String.t()) :: :ok | {:error, term()}
  def mark_interrupted(run_id) when is_binary(run_id) do
    JobRegistry.mark_interrupted(run_id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec mark_abandoned(String.t()) :: :ok | {:error, term()}
  def mark_abandoned(run_id) when is_binary(run_id) do
    JobRegistry.mark_abandoned(run_id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec mark_recovering(String.t()) :: :ok | {:error, term()}
  def mark_recovering(run_id) when is_binary(run_id) do
    JobRegistry.mark_recovering(run_id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp to_record(%JobEntry{} = entry), do: Adapter.from_job_entry(entry)
  defp to_record(data) when is_map(data), do: Adapter.from_job_entry(data)
end
