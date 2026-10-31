defmodule Arbor.LLM.ExecutionProviderIdentity do
  @moduledoc false
  alias Arbor.LLM.ProviderRegistry

  # Metadata only: never send a prompt, warm up/unload a model or fetch weights.
  # Ollama reports a weight digest. LM Studio reports a loaded instance's model
  # key, variant and configuration, but no weight digest. Keep that distinction
  # explicit: a reported metadata digest is never a weight-integrity claim.
  def capture(provider, model) when is_binary(provider) and is_binary(model) do
    base_url = ProviderRegistry.default_base_url(provider)

    identity = %{
      "provider" => provider,
      "model" => model,
      "endpoint_digest" => digest(base_url),
      "artifact_state" => "unreported",
      "artifact_digest" => nil
    }

    canonical = ProviderRegistry.normalize(provider)

    cond do
      canonical == "ollama" ->
        with true <- is_binary(base_url),
             url =
               String.replace_suffix(String.trim_trailing(base_url, "/"), "/v1", "") <>
                 "/api/tags",
             {:ok, %{status: 200, body: %{"models" => models}}} <-
               Req.get(url, receive_timeout: 2_000, retry: false, redirect: false),
             true <- is_list(models) and length(models) <= 1_024,
             entry when is_map(entry) <- Enum.find(models, &model_match?(&1, model)),
             artifact when is_binary(artifact) <- entry["digest"],
             true <- Regex.match?(~r/\A(?:sha256:)?[0-9a-f]{64}\z/, artifact) do
          {:ok, %{identity | "artifact_state" => "reported", "artifact_digest" => artifact}}
        else
          _ -> {:error, :model_serving_identity_unavailable}
        end

      canonical == "lm_studio" ->
        lm_studio_identity(identity, base_url, model)

      true ->
        {:ok, identity}
    end
  rescue
    _ -> {:error, :model_serving_identity_unavailable}
  catch
    _, _ -> {:error, :model_serving_identity_unavailable}
  end

  def capture(_, _), do: {:error, :model_serving_identity_unavailable}

  defp lm_studio_identity(identity, base_url, model) do
    with true <- is_binary(base_url),
         url =
           String.replace_suffix(String.trim_trailing(base_url, "/"), "/v1", "") <>
             "/api/v1/models",
         {:ok, %{status: 200, body: %{"models" => models}}} <-
           Req.get(url, receive_timeout: 2_000, retry: false, redirect: false),
         true <- is_list(models) and length(models) <= 1_024,
         [{entry, instance}] <-
           for(
             entry <- models,
             is_map(entry),
             instance <- Map.get(entry, "loaded_instances", []),
             is_map(instance),
             instance["id"] == model,
             do: {entry, instance}
           ),
         true <- entry["type"] == "llm" and is_binary(entry["key"]),
         serving =
           Map.take(
             entry,
             ~w(key architecture format selected_variant quantization size_bytes capabilities)
           )
           |> Map.put("loaded_instance", Map.take(instance, ~w(id config))),
         true <- :erlang.external_size(serving) <= 65_536 do
      {:ok, Map.put(identity, "serving_metadata", serving)}
    else
      _ -> {:error, :model_serving_identity_unavailable}
    end
  end

  defp model_match?(entry, model) when is_map(entry),
    do:
      entry["name"] in [model, model <> ":latest"] or
        entry["model"] in [model, model <> ":latest"]

  defp model_match?(_, _), do: false

  defp digest(value) when is_binary(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp digest(_), do: nil
end
