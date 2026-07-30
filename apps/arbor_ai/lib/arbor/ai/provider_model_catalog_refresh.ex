defmodule Arbor.AI.ProviderModelCatalogRefresh do
  @moduledoc false

  # Production-owned refresh into the supervised exact-route catalog cache.
  #
  # The public Arbor.AI facade admits only closed non-callback options. LLM test
  # seams (credential_receipt_fun, request_fun, clocks) are intentionally not
  # on the public write path — they would forge cache contents. Same-app tests
  # may call `refresh_via_llm/2` (this module) or put through
  # `ProviderModelCatalogStore` after an already-tested LLM fetch.

  alias Arbor.AI.ProviderModelCatalogStore
  alias Arbor.Contracts.LLM.ProviderModelCatalog

  @public_option_keys [:timeout_ms]
  @default_timeout_ms 15_000
  @max_timeout_ms 60_000
  @max_options 8

  @doc """
  Production refresh: exact OAuth route plus closed non-callback options only.

  Forwards at most `:timeout_ms` into `Arbor.LLM.oauth_model_catalog/2`. Rejects
  any callback, clock, or unknown option before network/credential I/O.
  """
  @spec refresh(atom() | String.t(), keyword()) ::
          {:ok, ProviderModelCatalog.t()} | {:error, term()}
  def refresh(route, opts \\ [])

  def refresh(route, opts) when is_list(opts) do
    with {:ok, llm_opts} <- admit_public_opts(opts) do
      do_refresh(route, llm_opts)
    end
  end

  def refresh(_route, _opts), do: {:error, :keyword_options_required}

  @doc false
  # Same-app tests only. Not part of the public Arbor.AI facade. Allows the
  # already-tested LLM injector surface so refresh→publish can be exercised
  # without live credentials; must never be re-exported on Arbor.AI.
  @spec refresh_via_llm(atom() | String.t(), keyword()) ::
          {:ok, ProviderModelCatalog.t()} | {:error, term()}
  def refresh_via_llm(route, opts \\ [])

  def refresh_via_llm(route, opts) when is_list(opts) do
    do_refresh(route, opts)
  end

  def refresh_via_llm(_route, _opts), do: {:error, :keyword_options_required}

  @doc false
  # Same-app tests: publish one already-validated catalog without network.
  @spec publish(ProviderModelCatalog.t() | map() | keyword()) ::
          {:ok, ProviderModelCatalog.t()} | {:error, term()}
  def publish(%ProviderModelCatalog{} = catalog) do
    case ProviderModelCatalogStore.put_sync(catalog) do
      :ok -> {:ok, catalog}
      {:error, :rejected} -> {:error, :catalog_publish_rejected}
      {:error, :unavailable} -> {:error, :catalog_store_unavailable}
    end
  end

  def publish(attrs) when is_map(attrs) or is_list(attrs) do
    case ProviderModelCatalog.new(attrs) do
      {:ok, catalog} -> publish(catalog)
      {:error, _} -> {:error, :catalog_publish_rejected}
    end
  rescue
    _ -> {:error, :catalog_publish_rejected}
  end

  def publish(_catalog), do: {:error, :catalog_publish_rejected}

  defp do_refresh(route, llm_opts) when is_list(llm_opts) do
    with {:ok, catalog} <- Arbor.LLM.oauth_model_catalog(route, llm_opts),
         :ok <- ProviderModelCatalogStore.put_sync(catalog) do
      {:ok, catalog}
    else
      {:error, :rejected} -> {:error, :catalog_publish_rejected}
      {:error, :unavailable} -> {:error, :catalog_store_unavailable}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :catalog_refresh_failed}
  catch
    :exit, _ -> {:error, :catalog_refresh_failed}
    _, _ -> {:error, :catalog_refresh_failed}
  end

  defp admit_public_opts(opts) when is_list(opts) do
    with :ok <- proper_keyword_list?(opts),
         :ok <- reject_unknown_and_callbacks(opts),
         {:ok, timeout_ms} <- admit_timeout_ms(opts) do
      {:ok, [timeout_ms: timeout_ms]}
    else
      :error -> {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_options}
  catch
    _, _ -> {:error, :invalid_options}
  end

  defp proper_keyword_list?(list), do: proper_keyword_list?(list, 0)

  defp proper_keyword_list?([], _n), do: :ok

  defp proper_keyword_list?([{key, _value} | rest], n)
       when is_atom(key) and n < @max_options do
    proper_keyword_list?(rest, n + 1)
  end

  defp proper_keyword_list?(_, _), do: :error

  defp reject_unknown_and_callbacks(opts) do
    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      cond do
        key not in @public_option_keys ->
          {:halt, :error}

        is_function(value) ->
          {:halt, :error}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp admit_timeout_ms(opts) do
    case Keyword.fetch(opts, :timeout_ms) do
      :error ->
        {:ok, @default_timeout_ms}

      {:ok, value}
      when is_integer(value) and value >= 1 and value <= @max_timeout_ms ->
        {:ok, value}

      _ ->
        :error
    end
  end

end
