defmodule Arbor.AI.AcpSession.Readiness.Internal do
  @moduledoc false

  alias Arbor.AI.AcpSession.Config
  alias Arbor.Contracts.LLM.ProviderObservation

  @ttl_seconds 30
  @source "acp_provider_readiness"
  @runtime "acp"
  @unknown_provider "unknown"

  @type options :: [
          clock: (-> DateTime.t()),
          observation:
            :available | {:error, :missing_executable | :missing_module | :invalid_config},
          executable_checker: (String.t() -> term()),
          module_checker: (module() -> boolean())
        ]

  @spec observe(term(), term(), options()) :: map()
  def observe(provider, requested_model, opts) when is_list(opts) do
    {observed_at, expires_at} = timestamps(opts)

    with {:ok, provider_atom, provider_kind} <- resolve_provider(provider),
         {:ok, strategy} <- model_strategy(provider_atom),
         {:ok, requested_model_id, launch_bound_model_id} <-
           model_ids(provider_atom, strategy, requested_model),
         {:ok, resolved} <- resolve_config(provider_atom),
         {:ok, availability} <- availability(provider_kind, resolved, opts) do
      build_envelope(%{
        provider: Atom.to_string(provider_atom),
        source: @source,
        runtime: @runtime,
        observed_at: observed_at,
        expires_at: expires_at,
        availability: availability,
        auth_health: "unknown",
        model_catalog_membership: "unknown",
        quota_state: "unknown",
        subscription_capacity_state: "unknown",
        requested_model_id: requested_model_id,
        launch_bound_model_id: launch_bound_model_id
      })
    else
      {:error, :unknown_provider} ->
        failure_envelope(
          provider_label(provider),
          observed_at,
          expires_at,
          "unknown",
          "provider is not registered"
        )

      {:error, :model_mismatch} ->
        failure_envelope(
          provider_label(provider),
          observed_at,
          expires_at,
          "model_mismatch",
          "requested model does not match launch-bound model",
          model_fields(provider, requested_model)
        )

      {:error, :invalid_config} ->
        failure_envelope(
          provider_label(provider),
          observed_at,
          expires_at,
          "protocol_error",
          "provider configuration is invalid",
          model_fields(provider, requested_model)
        )

      {:error, :missing_executable} ->
        failure_envelope(
          provider_label(provider),
          observed_at,
          expires_at,
          "transport_error",
          "provider executable is unavailable",
          model_fields(provider, requested_model)
        )

      {:error, :missing_module} ->
        failure_envelope(
          provider_label(provider),
          observed_at,
          expires_at,
          "protocol_error",
          "provider adapter is unavailable",
          model_fields(provider, requested_model)
        )

      {:error, :invalid_requested_model} ->
        failure_envelope(
          provider_label(provider),
          observed_at,
          expires_at,
          "model_absent",
          "requested model is invalid",
          model_fields(provider, requested_model)
        )
    end
  end

  defp resolve_provider(provider) when is_atom(provider) do
    case safe_provider_list() do
      {:ok, providers} ->
        case Enum.find(providers, fn {candidate, _kind} -> candidate == provider end) do
          {^provider, kind} -> {:ok, provider, kind}
          nil -> {:error, :unknown_provider}
        end

      :error ->
        {:error, :unknown_provider}
    end
  end

  defp resolve_provider(provider) when is_binary(provider) and byte_size(provider) <= 512 do
    if String.valid?(provider) do
      case safe_provider_list() do
        {:ok, providers} ->
          case Enum.find(providers, fn {candidate, _kind} ->
                 is_atom(candidate) and Atom.to_string(candidate) == provider
               end) do
            {provider_atom, kind} -> {:ok, provider_atom, kind}
            nil -> {:error, :unknown_provider}
          end

        :error ->
          {:error, :unknown_provider}
      end
    else
      {:error, :unknown_provider}
    end
  end

  defp resolve_provider(_provider), do: {:error, :unknown_provider}

  defp safe_provider_list do
    providers = Config.list_providers()

    if is_list(providers) and Enum.all?(providers, &valid_provider_entry?/1),
      do: {:ok, providers},
      else: :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp valid_provider_entry?({provider, kind})
       when is_atom(provider) and kind in [:native, :adapted, :custom], do: true

  defp valid_provider_entry?(_entry), do: false

  defp model_strategy(provider) do
    case Config.model_selection_strategy(provider) do
      :dynamic ->
        {:ok, :dynamic}

      {:launch_bound, model} when is_binary(model) and byte_size(model) <= 512 ->
        {:ok, {:launch_bound, model}}

      _ ->
        {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :invalid_config}
  catch
    _, _ -> {:error, :invalid_config}
  end

  defp model_ids(provider, strategy, requested_model) do
    case safe_validate_requested_model(provider, requested_model) do
      :ok ->
        case strategy do
          :dynamic ->
            {:ok, safe_requested_model(requested_model), nil}

          {:launch_bound, launch_model} ->
            requested_model_id = safe_requested_model(requested_model) || launch_model
            {:ok, requested_model_id, launch_model}
        end

      {:error, :invalid_grok_model} ->
        {:error, :model_mismatch}

      {:error, :invalid_requested_model} ->
        {:error, :invalid_requested_model}

      _ ->
        {:error, :invalid_config}
    end
  end

  defp safe_validate_requested_model(provider, requested_model) do
    with :ok <- validate_requested_model_input(requested_model),
         :ok <- Config.validate_requested_model(provider, requested_model) do
      :ok
    end
  rescue
    _ -> {:error, :invalid_config}
  catch
    _, _ -> {:error, :invalid_config}
  end

  defp validate_requested_model_input(nil), do: :ok

  defp validate_requested_model_input(model)
       when is_binary(model) and byte_size(model) <= 512 do
    if String.valid?(model) and String.trim(model) != "" and
         not String.match?(model, ~r/[\x00-\x1F\x7F]/),
       do: :ok,
       else: {:error, :invalid_requested_model}
  end

  defp validate_requested_model_input(_model), do: {:error, :invalid_requested_model}

  defp safe_requested_model(nil), do: nil

  defp safe_requested_model(model) when is_binary(model) and byte_size(model) <= 512 do
    if String.valid?(model) and String.trim(model) != "" and
         not String.match?(model, ~r/[\x00-\x1F\x7F]/),
       do: model,
       else: nil
  end

  defp safe_requested_model(model) when is_atom(model), do: Atom.to_string(model)
  defp safe_requested_model(_model), do: nil

  defp model_fields(provider, requested_model) do
    provider =
      case resolve_provider(provider) do
        {:ok, provider_atom, _kind} -> provider_atom
        {:error, _reason} -> provider
      end

    case model_strategy(provider) do
      {:ok, :dynamic} ->
        case safe_requested_model(requested_model) do
          nil -> []
          model -> [requested_model_id: model]
        end

      {:ok, {:launch_bound, launch_model}} ->
        case requested_model do
          nil ->
            [requested_model_id: launch_model, launch_bound_model_id: launch_model]

          model when is_binary(model) and byte_size(model) <= 512 ->
            [requested_model_id: model, launch_bound_model_id: launch_model]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp resolve_config(provider) do
    case Config.resolve(provider, []) do
      {:ok, resolved} when is_list(resolved) -> {:ok, resolved}
      {:error, _reason} -> {:error, :invalid_config}
      _ -> {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :invalid_config}
  catch
    _, _ -> {:error, :invalid_config}
  end

  defp availability(_provider_kind, resolved, opts) do
    case Keyword.fetch(opts, :observation) do
      {:ok, observation} -> normalize_observation(observation)
      :error -> probe_resolved_config(resolved, opts)
    end
  end

  defp probe_resolved_config(resolved, opts) do
    cond do
      Keyword.has_key?(resolved, :command) ->
        probe_native(resolved, opts)

      Keyword.has_key?(resolved, :transport_mod) or Keyword.has_key?(resolved, :adapter) ->
        probe_adapted(resolved, opts)

      true ->
        {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :invalid_config}
  catch
    _, _ -> {:error, :invalid_config}
  end

  defp probe_native(resolved, opts) do
    with {:ok, executable} <- executable_from(Keyword.get(resolved, :command)),
         true <- executable_available?(executable, opts) do
      {:ok, "degraded"}
    else
      false -> {:error, :missing_executable}
      {:error, _} -> {:error, :invalid_config}
    end
  end

  defp executable_from([executable | args])
       when is_binary(executable) and byte_size(executable) > 0 and is_list(args) do
    if Enum.all?(args, &(is_binary(&1) and byte_size(&1) > 0)),
      do: {:ok, executable},
      else: {:error, :invalid_config}
  end

  defp executable_from(_command), do: {:error, :invalid_config}

  defp executable_available?(executable, opts) do
    checker = Keyword.get(opts, :executable_checker, &System.find_executable/1)
    is_function(checker, 1) and checker.(executable) not in [nil, false]
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp probe_adapted(resolved, opts) do
    with {:ok, transport} <- module_from(resolved, :transport_mod),
         {:ok, adapter} <- module_from(resolved, :adapter),
         true <- Keyword.has_key?(resolved, :adapter_opts),
         true <- is_list(Keyword.get(resolved, :adapter_opts)),
         true <- module_available?(transport, opts),
         true <- module_available?(adapter, opts) do
      {:ok, "degraded"}
    else
      false -> {:error, :missing_module}
      {:error, :invalid_config} -> {:error, :invalid_config}
    end
  end

  defp module_from(resolved, key) do
    case Keyword.get(resolved, key) do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_config}
    end
  end

  defp module_available?(module, opts) do
    checker = Keyword.get(opts, :module_checker, &Code.ensure_loaded?/1)
    is_function(checker, 1) and checker.(module) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp normalize_observation(:available), do: {:ok, "degraded"}
  defp normalize_observation(:degraded), do: {:ok, "degraded"}
  defp normalize_observation({:error, :missing_executable}), do: {:error, :missing_executable}
  defp normalize_observation({:error, :missing_module}), do: {:error, :missing_module}
  defp normalize_observation({:error, :invalid_config}), do: {:error, :invalid_config}
  defp normalize_observation(_observation), do: {:error, :invalid_config}

  defp build_envelope(attrs) do
    with {:ok, observation} <- ProviderObservation.normalize(attrs),
         {:ok, digest} <- ProviderObservation.digest(observation) do
      %{"observation" => observation, "digest" => digest}
    else
      _ ->
        failure_envelope(
          @unknown_provider,
          attrs.observed_at,
          attrs.expires_at,
          "unknown",
          "readiness observation unavailable"
        )
    end
  end

  defp failure_envelope(provider, observed_at, expires_at, code, message, extras \\ []) do
    attrs =
      %{
        provider: provider,
        source: @source,
        runtime: @runtime,
        observed_at: observed_at,
        expires_at: expires_at,
        availability: "unavailable",
        auth_health: "unknown",
        model_catalog_membership: "unknown",
        quota_state: "unknown",
        subscription_capacity_state: "unknown",
        failure_code: code,
        failure_message: message
      }
      |> Map.merge(Map.new(extras))

    build_envelope(attrs)
  end

  defp provider_label(provider) when is_binary(provider) and byte_size(provider) <= 512 do
    if String.valid?(provider) and String.trim(provider) != "" and
         not String.match?(provider, ~r/[\x00-\x1F\x7F]/),
       do: provider,
       else: @unknown_provider
  end

  defp provider_label(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp provider_label(_provider), do: @unknown_provider

  defp timestamps(opts) do
    now =
      case Keyword.get(opts, :clock, &DateTime.utc_now/0) do
        clock when is_function(clock, 0) -> clock.()
        _ -> DateTime.utc_now()
      end

    now = if match?(%DateTime{}, now), do: now, else: DateTime.utc_now()
    {DateTime.to_iso8601(now), DateTime.add(now, @ttl_seconds, :second) |> DateTime.to_iso8601()}
  rescue
    _ ->
      now = DateTime.utc_now()

      {DateTime.to_iso8601(now),
       DateTime.add(now, @ttl_seconds, :second) |> DateTime.to_iso8601()}
  catch
    _, _ ->
      now = DateTime.utc_now()

      {DateTime.to_iso8601(now),
       DateTime.add(now, @ttl_seconds, :second) |> DateTime.to_iso8601()}
  end
end
