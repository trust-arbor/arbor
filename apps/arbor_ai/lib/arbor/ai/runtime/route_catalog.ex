defmodule Arbor.AI.Runtime.RouteCatalog do
  @moduledoc """
  Arbor-owned catalog overlay for `ProviderRouter` assembly.

  Reads `ModelProfile.entry/1`, then for two exact canonical ids replaces
  providers with a single OAuth Arbor `ProviderEntry` (pricing nil).
  Lookalikes and all other ids pass through unchanged.

  Exact overlays only:

    * `"gpt-5.6-sol"` → `:openai_oauth`
    * `"grok-4.5"` → `:xai_oauth`
  """

  alias Arbor.Common.ModelProfile
  alias Arbor.Contracts.LLM.ModelEntry
  alias Arbor.Contracts.LLM.ProviderEntry

  @oauth_overlays %{
    "gpt-5.6-sol" => :openai_oauth,
    "grok-4.5" => :xai_oauth
  }

  @doc """
  Return a `%ModelEntry{}` for `model_id`, with OAuth provider overlay when exact.
  """
  @spec entry(String.t()) :: ModelEntry.t()
  def entry(model_id) when is_binary(model_id) do
    base = ModelProfile.entry(model_id)

    case Map.fetch(@oauth_overlays, model_id) do
      :error ->
        base

      {:ok, provider_id} ->
        {:ok, pe} =
          ProviderEntry.new(%{
            id: provider_id,
            ref: model_id,
            auth: :oauth,
            runtimes: [:arbor],
            pricing: nil
          })

        %{base | providers: [pe]}
    end
  end

  @doc """
  Map ids through `entry/1` in order. Same envelope as the assembler default reader.
  """
  @spec entries([String.t()]) :: {:ok, [ModelEntry.t()]}
  def entries(ids) when is_list(ids) do
    {:ok, Enum.map(ids, &entry/1)}
  end
end
