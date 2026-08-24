defmodule Arbor.Agent.Eval.ProviderRoutePin do
  @moduledoc """
  Build an eval-scoped ProviderRouter pin for `{model, provider}`.

  Catalog membership is not enough. Two further allowlists sit on top:

  1. `RouteCatalog.entry/1` synthesizes unknown model ids as provider
     `:legacy`. A scoreboard row for the real provider then never matches.
  2. `RouteConcurrency.acquire/3` returns `:unconfigured_route` for any
     provider absent from the three policy maps.

  Either gap becomes `:no_eligible_routes` after `RoutePlan` drops the
  exclusion summary. Pinning the scoreboard without both overlays is how
  tier 2 measured nothing.

  This is a harness decision, not a production promotion. The returned maps
  are applied by the Mix task *before* app start so `RouteConcurrency` reads
  them at init. Policy values copy the reviewed profile (`concurrency 2`,
  spend ceiling `1.0`, capacity `"available"`). Do not use `0.0` or
  `"unknown"` — those are themselves exclusion reasons.
  """

  @runtime "arbor"
  @concurrency_limit 2
  @spend_ceiling 1.0
  @capacity_state "available"

  @type policy_snapshot :: %{
          optional(:concurrency) => map(),
          optional(:ceilings) => map(),
          optional(:capacity) => map()
        }

  @type pin :: %{
          profile: map(),
          concurrency: map(),
          ceilings: map(),
          capacity: map(),
          catalog_overlays: map(),
          probe_ids: [String.t()]
        }

  @doc """
  Construct the pinned profile and merged policy maps.

  `current` is the already-loaded Application env for the three policy keys.
  Existing providers are preserved; the pinned provider is written with
  string keys (and any atom-key duplicate for that provider is dropped so
  `RouteConcurrencyCore.normalize_limits/1` does not reject the map).
  """
  @spec build(String.t(), atom() | String.t(), policy_snapshot(), keyword()) :: pin()
  def build(model, provider, current \\ %{}, opts \\ [])
      when is_binary(model) and model != "" do
    provider_id = to_string(provider)
    now = Keyword.get(opts, :now)

    %{
      profile: profile(model, provider_id, now),
      concurrency:
        put_provider(current[:concurrency], provider_id, %{@runtime => @concurrency_limit}),
      ceilings: put_provider(current[:ceilings], provider_id, @spend_ceiling),
      capacity: put_provider(current[:capacity], provider_id, @capacity_state),
      # RouteCatalog.entry/1 synthesizes unknown ids as provider :legacy.
      # A scoreboard row for opencode_zen then never matches, and selection
      # returns :no_eligible_routes with no mention of the pin. Overlay the
      # pinned provider onto that catalog entry (eval-scoped).
      catalog_overlays: %{
        model => %{provider: provider_id, auth: provider_auth(provider_id)}
      },
      # Heartbeat LLM dispatch does not inherit Mix-task process dictionary,
      # so `with_probe_models/2` never reaches admit. TaskEval registers
      # these ids against the eval agent_id — measurement, not an
      # admission.json write and not a VM-global Application env pin.
      probe_ids: probe_ids(provider_id, model)
    }
  end

  defp probe_ids("opencode_zen", model), do: [model]
  defp probe_ids(_provider_id, _model), do: []

  defp provider_auth(provider_id) do
    cond do
      String.ends_with?(provider_id, "_oauth") -> "oauth"
      provider_id in ["opencode_zen", "ollama", "lm_studio"] -> "none"
      true -> "api_key"
    end
  end

  defp profile(model, provider_id, now) do
    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog_model_ids: [model],
      scoreboard: [
        %{
          model: model,
          provider: provider_id,
          runtime: @runtime,
          # Routing input for the model under test — not quality evidence.
          # Tier 2's verdict is the trial result, never these numbers.
          score: 1.0,
          dangerous_misses: 0,
          format_failure_rate: 0.0,
          variance: 0.0,
          marginal_cost: 0.0,
          latency_ms: 1.0,
          eval_run_ref: "eval-under-test",
          last_verified: last_verified(now)
        }
      ]
    }
  end

  defp last_verified(%DateTime{} = now), do: DateTime.to_iso8601(now)
  defp last_verified(now) when is_binary(now) and now != "", do: now
  defp last_verified(_), do: "eval-under-test"

  defp put_provider(map, provider_id, value) do
    map
    |> as_map()
    |> drop_provider_key(provider_id)
    |> Map.put(provider_id, value)
  end

  defp as_map(map) when is_map(map) and not is_struct(map), do: map
  defp as_map(_), do: %{}

  defp drop_provider_key(map, provider_id) do
    map
    |> Map.delete(provider_id)
    |> delete_existing_atom_key(provider_id)
  end

  defp delete_existing_atom_key(map, provider_id) do
    case Arbor.Common.SafeAtom.to_existing(provider_id) do
      {:ok, atom} -> Map.delete(map, atom)
      _ -> map
    end
  end
end
