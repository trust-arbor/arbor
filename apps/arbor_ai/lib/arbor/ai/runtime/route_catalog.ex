defmodule Arbor.AI.Runtime.RouteCatalog do
  @moduledoc """
  Arbor-owned catalog overlay for `ProviderRouter` assembly.

  Reads `ModelProfile.entry/1`, then for exact canonical ids replaces
  providers with a single OAuth Arbor `ProviderEntry` (pricing nil).
  Lookalikes and all other ids pass through unchanged unless the eval
  harness has pinned `:eval_route_catalog_overlays`.

  Exact OAuth overlays only:

    * `"gpt-5.6-sol"` → `:openai_oauth`
    * `"grok-4.6"` → `:xai_oauth`
    * `"grok-4.5"` → `:xai_oauth`
  """

  alias Arbor.Common.ModelProfile
  alias Arbor.Contracts.LLM.ModelEntry
  alias Arbor.Contracts.LLM.ProviderEntry

  @oauth_overlays %{
    "gpt-5.6-sol" => :openai_oauth,
    "grok-4.6" => :xai_oauth,
    "grok-4.5" => :xai_oauth
  }

  @doc """
  Return a `%ModelEntry{}` for `model_id`, with OAuth provider overlay when exact.
  """
  @spec entry(String.t()) :: ModelEntry.t()
  def entry(model_id) when is_binary(model_id) do
    base = ModelProfile.entry(model_id)

    case Map.fetch(@oauth_overlays, model_id) do
      {:ok, provider_id} ->
        overlay(base, model_id, provider_id, :oauth)

      :error ->
        case eval_overlay(model_id) do
          {:ok, provider_id, auth} -> overlay(base, model_id, provider_id, auth)
          :error -> base
        end
    end
  end

  @doc """
  Map ids through `entry/1` in order. Same envelope as the assembler default reader.
  """
  @spec entries([String.t()]) :: {:ok, [ModelEntry.t()]}
  def entries(ids) when is_list(ids) do
    {:ok, Enum.map(ids, &entry/1)}
  end

  defp overlay(base, model_id, provider_id, auth) do
    {:ok, pe} =
      ProviderEntry.new(%{
        id: provider_id,
        ref: model_id,
        auth: auth,
        runtimes: [:arbor],
        pricing: nil
      })

    %{base | providers: [pe]}
  end

  # Eval harness pin (`:eval_route_catalog_overlays`). Empty in production.
  # Unknown models otherwise synthesize as provider `:legacy`, so a scoreboard
  # pin to `{model, provider}` never matches.
  defp eval_overlay(model_id) do
    overlays = Application.get_env(:arbor_ai, :eval_route_catalog_overlays, %{})

    with true <- is_map(overlays) and not is_struct(overlays),
         {:ok, spec} <- fetch_overlay_spec(overlays, model_id),
         {:ok, provider} <- overlay_provider(spec),
         {:ok, auth} <- overlay_auth(spec) do
      {:ok, provider, auth}
    else
      _ -> :error
    end
  end

  defp fetch_overlay_spec(overlays, model_id), do: Map.fetch(overlays, model_id)

  defp overlay_provider(spec) when is_map(spec) do
    value = Map.get(spec, :provider) || Map.get(spec, "provider")

    case Arbor.Common.SafeAtom.to_existing(value) do
      {:ok, atom} when atom not in [nil, true, false] -> {:ok, atom}
      _ -> :error
    end
  end

  defp overlay_provider(_), do: :error

  @overlay_auth [:none, :oauth, :api_key, :aws, :gcp]

  defp overlay_auth(spec) when is_map(spec) do
    value = Map.get(spec, :auth) || Map.get(spec, "auth")

    case Arbor.Common.SafeAtom.to_allowed(value, @overlay_auth) do
      {:ok, auth} -> {:ok, auth}
      _ -> :error
    end
  end

  defp overlay_auth(_), do: :error
end
