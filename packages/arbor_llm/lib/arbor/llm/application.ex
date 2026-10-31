defmodule Arbor.LLM.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    _ = Arbor.LLM.OpenCodeZen.ensure_eval_probes_table()
    warm_model_catalog()

    children = [
      Arbor.LLM.OAuth.Login.PendingStore,
      Arbor.LLM.OAuth.RecoveryProofStore,
      Arbor.LLM.OAuth.Login.LoopbackRootSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.LLM.Supervisor)
  end

  # ReqLLM 1.25 resolves a provider base URL through LLMDB even when the
  # caller already passed one. The first lookup hashes the packaged catalog,
  # and Arbor's receive-timeout covers that setup. Do it once here, outside
  # any request deadline. A load failure must not stop the supervisor.
  defp warm_model_catalog do
    case Application.ensure_all_started(:llm_db) do
      {:ok, _} ->
        case LLMDB.Catalog.ensure_loaded() do
          :ok -> :ok
          {:error, reason} -> log_catalog_warm_failure(reason)
        end

      {:error, reason} ->
        log_catalog_warm_failure(reason)
    end
  rescue
    exception -> log_catalog_warm_failure(exception)
  catch
    kind, reason -> log_catalog_warm_failure({kind, reason})
  end

  defp log_catalog_warm_failure(reason) do
    Logger.warning("llm model catalog warm failed: #{inspect(reason)}")
    :error
  end
end
