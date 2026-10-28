defmodule Arbor.Persistence.Eval.Store do
  @moduledoc false

  # High-level eval run persistence: Postgres when available, JSON file fallback
  # only when the database is actually unavailable. Public access is via
  # Arbor.Persistence only.
  #
  # :auto falls back to file solely for database unavailability. Changeset,
  # constraint, and other DB failures — and all file write failures — propagate
  # (no false success).

  require Logger

  alias Arbor.Persistence
  alias Arbor.Persistence.Eval.{FileStore, RunIdentity}
  alias Arbor.Persistence.Repo

  @type backend() :: :auto | :database | :file

  @max_slug_model 40
  @max_slug_domain 32

  @spec database_available?() :: boolean()
  def database_available? do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Generate a unique run ID by slugging and bounding both model and domain into
  the FileStore closed ASCII filename-component grammar.
  """
  @spec generate_run_id(String.t(), String.t()) :: String.t()
  def generate_run_id(model, domain) when is_binary(model) and is_binary(domain) do
    model_slug = slug_component(model, @max_slug_model)
    domain_slug = slug_component(domain, @max_slug_domain)
    date = Date.utc_today() |> Date.to_iso8601()
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    id = "#{model_slug}-#{domain_slug}-#{date}-#{suffix}"

    case FileStore.validate_run_id(id) do
      :ok ->
        id

      {:error, :invalid_run_id} ->
        # Extremely defensive fallback — always grammar-valid
        "eval-#{date}-#{suffix}"
    end
  end

  def generate_run_id(model, domain) do
    generate_run_id(to_string(model || "model"), to_string(domain || "domain"))
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
              Logger.debug("EvalPersistence: created run #{inspect(attrs[:id])} in Postgres")
              ok

            {:error, reason} = err ->
              Logger.warning(
                "EvalPersistence: DB insert failed (not falling back): #{inspect(reason)}"
              )

              err
          end
        else
          Logger.debug("EvalPersistence: Postgres unavailable, using JSON fallback")
          file_create(attrs, opts)
        end
    end
  end

  @spec update_run(String.t(), map(), keyword()) :: :ok | {:ok, struct()} | {:error, term()}
  def update_run(run_id, attrs, opts \\ []) when is_binary(run_id) and is_map(attrs) do
    backend = backend(opts)

    case backend do
      :file ->
        # File store does not support partial in-place updates of run rows.
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
    Keyword.take(opts, [:dir, :max_file_bytes, :max_files, :max_total_bytes])
  end

  defp file_create(attrs, opts) do
    with {:ok, slug} <- resolve_run_id(attrs),
         :ok <- FileStore.save_run(slug, Map.put(attrs, :id, slug), file_opts(opts)) do
      {:ok, Map.put(attrs, :id, slug)}
    end
  end

  defp resolve_run_id(%{id: id}) when is_binary(id) do
    case FileStore.validate_run_id(id) do
      :ok -> {:ok, id}
      {:error, _} = err -> err
    end
  end

  defp resolve_run_id(%{"id" => id}) when is_binary(id) do
    case FileStore.validate_run_id(id) do
      :ok -> {:ok, id}
      {:error, _} = err -> err
    end
  end

  defp resolve_run_id(%{model: model, domain: domain})
       when is_binary(model) and is_binary(domain) do
    {:ok, generate_run_id(model, domain)}
  end

  defp resolve_run_id(%{"model" => model, "domain" => domain})
       when is_binary(model) and is_binary(domain) do
    {:ok, generate_run_id(model, domain)}
  end

  defp resolve_run_id(_) do
    date = Date.utc_today() |> Date.to_iso8601()
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    {:ok, "eval-#{date}-#{suffix}"}
  end

  defp file_list(filters, opts) do
    list_opts =
      opts
      |> file_opts()
      |> Keyword.merge(Keyword.take(filters, [:model, :provider]))

    FileStore.list_runs(list_opts)
  end

  defp slug_component(value, max_len) when is_binary(value) and is_integer(max_len) do
    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    slug =
      case slug do
        "" -> "x"
        other -> other
      end

    slug
    |> String.slice(0, max_len)
    |> String.trim_trailing("-")
    |> case do
      "" -> "x"
      other -> other
    end
  end
end
