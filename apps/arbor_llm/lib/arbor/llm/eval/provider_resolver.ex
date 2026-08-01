defmodule Arbor.LLM.Eval.ProviderResolver do
  @moduledoc false

  alias Arbor.Contracts.LLM.OAuthHealth
  alias Arbor.LLM.{ExternalTerm, ProviderCatalog}

  @oauth_adapter Arbor.LLM.Adapter.OAuthResponses

  @type resolution :: %{
          provider: String.t(),
          source: :oauth | :catalog,
          adapter_module: module()
        }

  @type resolution_error ::
          {:unknown_eval_provider, String.t(), [String.t()]}
          | {:eval_provider_unavailable, String.t(), {:oauth_status, String.t()}}
          | {:eval_provider_unavailable, String.t(), {:oauth_health, term()}}
          | {:eval_provider_unavailable, String.t(), :catalog_check_failed}
          | {:invalid_eval_provider, :non_empty_string_required}
          | {:invalid_eval_provider_options, :keyword_required | :unsupported | :boolean_required}

  @spec resolve_transport(String.t()) :: {:ok, resolution()} | {:error, resolution_error()}
  def resolve_transport(provider) do
    with :ok <- validate_provider(provider),
         {:ok, entry} <- lookup(provider, []) do
      case entry do
        %{source: :oauth, status: "ready"} ->
          {:ok, Map.take(entry, [:provider, :source, :adapter_module])}

        %{source: :oauth, status: status} ->
          {:error, {:eval_provider_unavailable, provider, {:oauth_status, status}}}

        %{source: :catalog} ->
          {:ok, Map.take(entry, [:provider, :source, :adapter_module])}
      end
    end
  end

  @spec preflight(String.t(), keyword()) :: :ok | {:error, resolution_error()}
  def preflight(provider, opts \\ []) do
    with :ok <- validate_provider(provider),
         :ok <- validate_opts(opts),
         {:ok, entry} <- lookup(provider, opts) do
      case entry do
        %{source: :oauth, status: "ready"} ->
          :ok

        %{source: :oauth, status: status} ->
          {:error, {:eval_provider_unavailable, provider, {:oauth_status, status}}}

        %{source: :catalog, available?: true} ->
          :ok

        %{source: :catalog, available?: false} ->
          {:error, {:eval_provider_unavailable, provider, :catalog_check_failed}}
      end
    end
  rescue
    exception ->
      {:error,
       {:eval_provider_unavailable, provider, {:oauth_health, ExternalTerm.exception(exception)}}}
  catch
    kind, reason ->
      {:error,
       {:eval_provider_unavailable, provider,
        {:oauth_health, {kind, ExternalTerm.sanitize(reason)}}}}
  end

  defp lookup(provider, opts) do
    if provider in OAuthHealth.routes() do
      lookup_oauth(provider)
    else
      lookup_catalog(provider, opts)
    end
  end

  defp lookup_oauth(provider) do
    case Arbor.LLM.oauth_health(provider) do
      {:ok, %OAuthHealth{route: ^provider, status: status}} ->
        {:ok,
         %{
           provider: provider,
           source: :oauth,
           adapter_module: @oauth_adapter,
           status: status
         }}

      {:error, reason} ->
        {:error,
         {:eval_provider_unavailable, provider, {:oauth_health, ExternalTerm.sanitize(reason)}}}
    end
  end

  defp lookup_catalog(provider, opts) do
    catalog = ProviderCatalog.all(opts)

    case Enum.find(catalog, &(&1.provider == provider)) do
      nil ->
        known =
          catalog
          |> Enum.map(& &1.provider)
          |> Kernel.++(OAuthHealth.routes())
          |> Enum.uniq()
          |> Enum.sort()

        {:error, {:unknown_eval_provider, provider, known}}

      entry ->
        {:ok,
         %{
           provider: provider,
           source: :catalog,
           adapter_module: entry.adapter_module,
           available?: entry.available?
         }}
    end
  end

  defp validate_provider(provider) when is_binary(provider) and provider != "", do: :ok

  defp validate_provider(_provider),
    do: {:error, {:invalid_eval_provider, :non_empty_string_required}}

  defp validate_opts(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_eval_provider_options, :keyword_required}}

      Keyword.keys(opts) -- [:force_refresh] != [] ->
        {:error, {:invalid_eval_provider_options, :unsupported}}

      not is_boolean(Keyword.get(opts, :force_refresh, false)) ->
        {:error, {:invalid_eval_provider_options, :boolean_required}}

      true ->
        :ok
    end
  end

  defp validate_opts(_opts), do: {:error, {:invalid_eval_provider_options, :keyword_required}}
end
