defmodule Arbor.Persistence.Eval.Store do
  @moduledoc false

  # High-level eval run persistence: Postgres when available, JSON file fallback
  # otherwise. Public access is via Arbor.Persistence only.
  #
  # Ownership-extraction commit preserves historical false-success fallback
  # behavior (DB insert/changeset failures fall through to file and return
  # {:ok, attrs}). Hardening commit tightens that contract.

  require Logger

  alias Arbor.Persistence
  alias Arbor.Persistence.Eval.{FileStore, RunIdentity}
  alias Arbor.Persistence.Repo

  @type backend() :: :auto | :database | :file

  @spec database_available?() :: boolean()
  def database_available? do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  rescue
    _ -> false
  end

  @spec generate_run_id(String.t(), String.t()) :: String.t()
  def generate_run_id(model, domain) when is_binary(model) and is_binary(domain) do
    slug = model |> String.replace(~r/[:\/.]+/, "-") |> String.downcase()
    date = Date.utc_today() |> Date.to_iso8601()
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{slug}-#{domain}-#{date}-#{suffix}"
  end

  @spec create_run(map(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def create_run(attrs, opts \\ []) when is_map(attrs) do
    attrs = RunIdentity.capture(attrs)
    backend = backend(opts)

    case backend do
      :file ->
        file_create(attrs, opts)

      :database ->
        Persistence.insert_eval_run(attrs)

      :auto ->
        if database_available?() do
          case Persistence.insert_eval_run(attrs) do
            {:ok, _} = ok ->
              Logger.debug("EvalPersistence: created run #{attrs[:id]} in Postgres")
              ok

            {:error, reason} ->
              Logger.warning(
                "EvalPersistence: DB insert failed: #{inspect(reason)}, falling back to JSON"
              )

              file_create(attrs, opts)
          end
        else
          Logger.debug("EvalPersistence: Postgres unavailable, using JSON fallback")
          file_create(attrs, opts)
        end
    end
  rescue
    e ->
      Logger.warning("EvalPersistence: create_run rescue: #{Exception.message(e)}")
      file_create(attrs, opts)
  catch
    :exit, reason ->
      Logger.warning("EvalPersistence: create_run exit: #{inspect(reason)}")
      file_create(attrs, opts)
  end

  @spec update_run(String.t(), map(), keyword()) :: :ok | {:ok, struct()} | {:error, term()}
  def update_run(run_id, attrs, opts \\ []) when is_binary(run_id) and is_map(attrs) do
    backend = backend(opts)

    case backend do
      :file ->
        :ok

      :database ->
        Persistence.update_eval_run(run_id, attrs)

      :auto ->
        if database_available?() do
          Persistence.update_eval_run(run_id, attrs)
        else
          :ok
        end
    end
  rescue
    e ->
      Logger.warning("EvalPersistence: update_run rescue: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("EvalPersistence: update_run exit: #{inspect(reason)}")
      :ok
  end

  @spec save_result(map(), keyword()) :: :ok | {:ok, struct()} | {:error, term()}
  def save_result(attrs, opts \\ []) when is_map(attrs) do
    backend = backend(opts)

    case backend do
      :file ->
        :ok

      :database ->
        Persistence.insert_eval_result(attrs)

      :auto ->
        if database_available?() do
          Persistence.insert_eval_result(attrs)
        else
          :ok
        end
    end
  rescue
    e ->
      Logger.warning("EvalPersistence: save_result rescue: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("EvalPersistence: save_result exit: #{inspect(reason)}")
      :ok
  end

  @spec save_results_batch([map()], keyword()) ::
          :ok | {non_neg_integer(), nil} | {:error, term()}
  def save_results_batch(results, opts \\ []) when is_list(results) do
    backend = backend(opts)

    case backend do
      :file ->
        :ok

      :database ->
        Persistence.insert_eval_results_batch(results)

      :auto ->
        if database_available?() do
          Persistence.insert_eval_results_batch(results)
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec complete_run(String.t(), map(), non_neg_integer(), non_neg_integer(), keyword()) ::
          :ok | {:ok, struct()} | {:error, term()}
  def complete_run(run_id, metrics, sample_count, duration_ms, opts \\ []) do
    update_run(
      run_id,
      %{
        status: "completed",
        metrics: metrics,
        sample_count: sample_count,
        duration_ms: duration_ms
      },
      opts
    )
  end

  @spec fail_run(String.t(), term(), keyword()) :: :ok | {:ok, struct()} | {:error, term()}
  def fail_run(run_id, error, opts \\ []) do
    update_run(
      run_id,
      %{
        status: "failed",
        error: to_string(error)
      },
      opts
    )
  end

  @spec list_runs(keyword(), keyword()) :: {:ok, [map() | struct()]} | {:error, term()}
  def list_runs(filters \\ [], opts \\ []) do
    backend = backend(opts)

    case backend do
      :file ->
        file_list(filters, opts)

      :database ->
        Persistence.list_eval_runs(filters)

      :auto ->
        if database_available?() do
          Persistence.list_eval_runs(filters)
        else
          file_list(filters, opts)
        end
    end
  rescue
    _ -> file_list(filters, opts)
  catch
    :exit, _ -> file_list(filters, opts)
  end

  @spec get_run(String.t(), keyword()) :: {:ok, map() | struct()} | {:error, term()}
  def get_run(run_id, opts \\ []) when is_binary(run_id) do
    backend = backend(opts)

    case backend do
      :file ->
        FileStore.load_run(run_id, file_opts(opts))

      :database ->
        Persistence.get_eval_run(run_id)

      :auto ->
        if database_available?() do
          Persistence.get_eval_run(run_id)
        else
          FileStore.load_run(run_id, file_opts(opts))
        end
    end
  rescue
    _ -> FileStore.load_run(run_id, file_opts(opts))
  catch
    :exit, _ -> FileStore.load_run(run_id, file_opts(opts))
  end

  @spec compare_models(String.t(), [String.t()], keyword()) ::
          {:ok, [map() | struct()]} | {:error, term()}
  def compare_models(domain, models, opts \\ [])
      when is_binary(domain) and is_list(models) do
    backend = backend(opts)

    case backend do
      :file ->
        {:ok, []}

      :database ->
        Persistence.eval_model_comparison(domain, models)

      :auto ->
        if database_available?() do
          Persistence.eval_model_comparison(domain, models)
        else
          {:ok, []}
        end
    end
  rescue
    _ -> {:ok, []}
  catch
    :exit, _ -> {:ok, []}
  end

  # --- Private ---

  defp backend(opts) do
    case Keyword.get(opts, :backend, :auto) do
      :auto -> :auto
      :database -> :database
      :file -> :file
      _ -> :auto
    end
  end

  defp file_opts(opts) do
    Keyword.take(opts, [:dir])
  end

  defp file_create(attrs, opts) do
    slug = run_slug(attrs)
    # Historical contract: ignore file write outcome and still return {:ok, attrs}.
    # Hardening commit will propagate write failures.
    _ = FileStore.save_run(slug, attrs, file_opts(opts))
    {:ok, attrs}
  end

  defp file_list(filters, opts) do
    list_opts =
      opts
      |> file_opts()
      |> Keyword.merge(Keyword.take(filters, [:model, :provider]))

    case FileStore.list_runs(list_opts) do
      runs when is_list(runs) -> {:ok, runs}
      other -> other
    end
  end

  defp run_slug(%{id: id}) when is_binary(id), do: id
  defp run_slug(%{"id" => id}) when is_binary(id), do: id

  defp run_slug(%{model: model, domain: domain})
       when is_binary(model) and is_binary(domain) do
    generate_run_id(model, domain)
  end

  defp run_slug(%{"model" => model, "domain" => domain})
       when is_binary(model) and is_binary(domain) do
    generate_run_id(model, domain)
  end

  defp run_slug(_), do: "eval-#{System.os_time(:millisecond)}"
end
