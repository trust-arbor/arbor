defmodule Arbor.AI.ProviderRouteReadinessCore do
  @moduledoc """
  Pure readiness decision for the strict provider-route profile.

  The shell supplies already-observed policy, durable replay, OAuth health,
  catalog, credential generation, and clock facts. This core performs no config,
  process, network, persistence, or clock IO. Its only output is a closed
  JSON-clean readiness map.

  Durable replay gates every catalog decision. Once replay is complete, catalog
  failures have deterministic precedence: malformed evidence, credential
  generation mismatch, stale evidence, then missing evidence. A catalog may be
  observed up to 60 seconds ahead of the injected clock to tolerate bounded
  sequential-observer skew; anything further ahead is malformed evidence.
  """

  alias Arbor.AI.Runtime.ProviderModelCatalogEvidence

  @schema_version 1
  @routes ["openai_oauth", "xai_oauth"]
  @max_routes length(@routes)
  @max_generation 1_000_000_000_000

  @required_fact_fields [
    :policy_enabled,
    :required_routes,
    :durable_replay,
    :auth_health,
    :catalog_snapshot,
    :credential_generations
  ]

  @fact_fields @required_fact_fields ++ [:refresh_outcomes]

  @durable_states %{
    "complete" => :complete,
    "pending" => :pending,
    "unavailable" => :unavailable,
    "malformed" => :malformed_or_incomplete,
    "incomplete" => :malformed_or_incomplete
  }

  @issue_precedence [
    "oauth_health_permanent",
    "oauth_health_transient",
    "catalog_refresh_permanent",
    "catalog_malformed",
    "catalog_generation_mismatch",
    "catalog_stale",
    "catalog_refresh_transient",
    "catalog_missing"
  ]

  @permanent_refresh_reasons [
    :oauth_login_required,
    :oauth_credential_migration_required,
    :oauth_relogin_required,
    :oauth_source_reauthentication_required,
    :oauth_source_owned_unsupported,
    :oauth_source_unsupported,
    :oauth_credential_invalid,
    :oauth_source_credential_invalid,
    :invalid_credential_receipt
  ]

  @permanent_health_statuses ~w(
    login_required migration_required relogin_required source_unsupported invalid
  )
  @transient_health_statuses ~w(
    expired source_unavailable store_unreadable unavailable malformed
  )

  @type readiness_result :: %{
          required(String.t()) => pos_integer() | boolean() | String.t() | [String.t()] | nil
        }

  @doc "Return one closed, JSON-clean readiness decision from injected facts."
  @spec evaluate(term(), term()) :: readiness_result()
  def evaluate(facts, now) do
    with {:ok, now} <- normalize_now(now),
         {:ok, facts} <- normalize_facts(facts),
         {:ok, enabled?} <- normalize_enabled(facts.policy_enabled) do
      if enabled? do
        evaluate_enabled(facts, now)
      else
        result("disabled", false, [], [], now)
      end
    else
      _ -> malformed_result(now)
    end
  rescue
    _ -> malformed_result(now)
  catch
    _, _ -> malformed_result(now)
  end

  @doc "Classify a refresh result into a closed retry policy fact."
  @spec classify_refresh_result(term()) :: String.t()
  def classify_refresh_result({:ok, _}), do: "success"

  def classify_refresh_result({:error, reason}),
    do: if(permanent_refresh_reason?(reason), do: "permanent", else: "transient")

  def classify_refresh_result(_), do: "transient"

  @doc false
  @spec classify_auth_health(term()) :: :ready | :permanent | :transient | :malformed
  def classify_auth_health("ready"), do: :ready

  def classify_auth_health(status) when status in @permanent_health_statuses,
    do: :permanent

  def classify_auth_health(status) when status in @transient_health_statuses,
    do: :transient

  def classify_auth_health(_status), do: :malformed

  defp permanent_refresh_reason?(reason) when reason in @permanent_refresh_reasons, do: true

  defp permanent_refresh_reason?({tag, reason}) when is_atom(tag),
    do: tag in [:oauth_error, :oauth_model_catalog_failed] and permanent_refresh_reason?(reason)

  defp permanent_refresh_reason?(%{code: code}) when is_atom(code),
    do: code in [:unauthorized, :invalid_credential_receipt, :source_reauthentication_required]

  defp permanent_refresh_reason?(_), do: false

  defp evaluate_enabled(facts, now) do
    with {:ok, routes} <- normalize_required_routes(facts.required_routes),
         {:ok, durable_status} <- normalize_durable_replay(facts.durable_replay) do
      case durable_status do
        :complete ->
          evaluate_catalogs(facts, routes, now)

        :pending ->
          result("durable_replay_pending", false, routes, routes, now)

        :unavailable ->
          result("durable_replay_unavailable", false, routes, routes, now)

        :malformed_or_incomplete ->
          result(
            "durable_replay_malformed_or_incomplete",
            false,
            routes,
            routes,
            now
          )
      end
    else
      _ -> malformed_result(now)
    end
  end

  defp evaluate_catalogs(_facts, [], now), do: result("ready", true, [], [], now)

  defp evaluate_catalogs(facts, routes, now) do
    with {:ok, snapshot_status, catalogs} <- normalize_catalog_snapshot(facts.catalog_snapshot) do
      case snapshot_status do
        :refresh_pending ->
          result("catalog_refresh_pending", false, routes, routes, now)

        :unavailable ->
          result("catalog_store_unavailable", false, routes, routes, now)

        :malformed ->
          result("catalog_malformed", false, routes, routes, now)

        :available ->
          with {:ok, health} <- normalize_health_map(facts.auth_health),
               {:ok, generations} <- normalize_generation_map(facts.credential_generations),
               {:ok, refresh_outcomes} <- normalize_refresh_outcomes(facts.refresh_outcomes) do
            decide_route_issues(
              routes,
              health,
              catalogs,
              generations,
              refresh_outcomes,
              now
            )
          else
            _ -> malformed_result(now)
          end
      end
    else
      {:error, :catalog_malformed} ->
        result("catalog_malformed", false, routes, routes, now)

      _ ->
        malformed_result(now)
    end
  end

  defp decide_route_issues(routes, health, catalogs, generations, refresh_outcomes, now) do
    issues =
      Map.new(routes, fn route ->
        {route, route_issue(route, health, catalogs, generations, refresh_outcomes, now)}
      end)

    blocking_routes =
      routes
      |> Enum.reject(&(Map.fetch!(issues, &1) == "ready"))
      |> canonical_route_order()

    state =
      Enum.find(@issue_precedence, fn candidate ->
        Enum.any?(issues, fn {_route, issue} -> issue == candidate end)
      end) || "ready"

    result(state, state == "ready", routes, blocking_routes, now)
  end

  defp route_issue(route, health, catalogs, generations, refresh_outcomes, now) do
    if Map.get(refresh_outcomes, route) == "permanent" do
      "catalog_refresh_permanent"
    else
      case classify_auth_health(Map.get(health, route)) do
        :ready -> catalog_issue(route, catalogs, generations, refresh_outcomes, now)
        :permanent -> "oauth_health_permanent"
        :transient -> "oauth_health_transient"
        :malformed -> "oauth_health_transient"
      end
    end
  end

  defp catalog_issue(route, catalogs, generations, refresh_outcomes, now) do
    outcome = Map.get(refresh_outcomes, route)

    if outcome == "permanent" do
      "catalog_refresh_permanent"
    else
      case Map.fetch(catalogs, route) do
        :error ->
          if outcome == "transient", do: "catalog_refresh_transient", else: "catalog_missing"

        {:ok, attrs} ->
          case ProviderModelCatalogEvidence.assess(
                 attrs,
                 route,
                 expected_backend(route),
                 "arbor",
                 Map.get(generations, route),
                 now
               ) do
            {:ok, _catalog} ->
              "ready"

            {:error, :generation_mismatch} ->
              if outcome == "transient",
                do: "catalog_refresh_transient",
                else: "catalog_generation_mismatch"

            {:error, :stale} ->
              if outcome == "transient", do: "catalog_refresh_transient", else: "catalog_stale"

            {:error, _reason} ->
              "catalog_malformed"
          end
      end
    end
  end

  defp expected_backend("openai_oauth"), do: "openai"
  defp expected_backend("xai_oauth"), do: "xai"

  defp normalize_facts(facts) when is_map(facts) and not is_struct(facts) do
    case Map.has_key?(facts, :refresh_outcomes) or Map.has_key?(facts, "refresh_outcomes") do
      true ->
        normalize_object(facts, @fact_fields)

      false ->
        with {:ok, normalized} <- normalize_object(facts, @required_fact_fields) do
          {:ok, Map.put(normalized, :refresh_outcomes, %{})}
        end
    end
  end

  defp normalize_facts(_), do: {:error, :malformed}

  defp normalize_now(%DateTime{utc_offset: 0, std_offset: 0, calendar: Calendar.ISO} = now),
    do: {:ok, now}

  defp normalize_now(_), do: {:error, :malformed}

  defp normalize_enabled(enabled?) when is_boolean(enabled?), do: {:ok, enabled?}
  defp normalize_enabled(_), do: {:error, :malformed}

  defp normalize_required_routes(routes) when is_list(routes) do
    collect_routes(routes, MapSet.new(), 0)
  end

  defp normalize_required_routes(_), do: {:error, :malformed}

  defp collect_routes([], seen, _count) do
    {:ok, seen |> MapSet.to_list() |> canonical_route_order()}
  end

  defp collect_routes(_routes, _seen, count) when count >= @max_routes,
    do: {:error, :malformed}

  defp collect_routes([route | rest], seen, count) when route in @routes do
    if MapSet.member?(seen, route) do
      {:error, :malformed}
    else
      collect_routes(rest, MapSet.put(seen, route), count + 1)
    end
  end

  defp collect_routes(_routes, _seen, _count), do: {:error, :malformed}

  defp normalize_durable_replay(value) do
    with {:ok, normalized} <- normalize_object(value, [:status]),
         status when is_binary(status) <- normalized.status,
         {:ok, state} <- Map.fetch(@durable_states, status) do
      {:ok, state}
    else
      _ -> {:ok, :malformed_or_incomplete}
    end
  end

  defp normalize_catalog_snapshot(value) do
    with {:ok, normalized} <- normalize_object(value, [:status, :catalogs]),
         true <- is_map(normalized.catalogs) and not is_struct(normalized.catalogs),
         :ok <- validate_route_keyed_map(normalized.catalogs) do
      case normalized.status do
        "refresh_pending" -> {:ok, :refresh_pending, normalized.catalogs}
        "available" -> {:ok, :available, normalized.catalogs}
        "unavailable" -> {:ok, :unavailable, normalized.catalogs}
        "malformed" -> {:ok, :malformed, normalized.catalogs}
        _ -> {:error, :catalog_malformed}
      end
    else
      _ -> {:error, :catalog_malformed}
    end
  end

  defp normalize_generation_map(generations)
       when is_map(generations) and not is_struct(generations) do
    with :ok <- validate_route_keyed_map(generations),
         true <-
           Enum.all?(generations, fn {_route, generation} ->
             is_integer(generation) and generation >= 0 and generation <= @max_generation
           end) do
      {:ok, generations}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_generation_map(_), do: {:error, :malformed}

  defp normalize_health_map(health) when is_map(health) and not is_struct(health) do
    with :ok <- validate_route_keyed_map(health),
         true <-
           Enum.all?(health, fn {_route, status} ->
             classify_auth_health(status) != :malformed
           end) do
      {:ok, health}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_health_map(_health), do: {:error, :malformed}

  defp normalize_refresh_outcomes(outcomes)
       when is_map(outcomes) and not is_struct(outcomes) and map_size(outcomes) <= @max_routes do
    with :ok <- validate_route_keyed_map(outcomes),
         true <-
           Enum.all?(outcomes, fn {_route, outcome} -> outcome in ["transient", "permanent"] end) do
      {:ok, outcomes}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_refresh_outcomes(_), do: {:error, :malformed}

  defp validate_route_keyed_map(map) when map_size(map) <= @max_routes do
    if Enum.all?(Map.keys(map), &(&1 in @routes)), do: :ok, else: {:error, :malformed}
  end

  defp validate_route_keyed_map(_), do: {:error, :malformed}

  defp normalize_object(value, fields) when is_map(value) and not is_struct(value) do
    entries = Enum.map(value, &normalize_entry(&1, fields))
    expected_names = fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()

    with true <- map_size(value) == length(fields),
         true <- Enum.all?(entries, &match?({:ok, _, _}, &1)),
         names = Enum.map(entries, &elem(&1, 1)),
         true <- length(Enum.uniq(names)) == length(names),
         true <- Enum.sort(names) == expected_names do
      {:ok,
       Map.new(entries, fn {:ok, name, entry_value} ->
         {Enum.find(fields, &(Atom.to_string(&1) == name)), entry_value}
       end)}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_object(_value, _fields), do: {:error, :malformed}

  defp normalize_entry({key, value}, fields) when is_atom(key) do
    normalize_named_entry(Atom.to_string(key), value, fields)
  end

  defp normalize_entry({key, value}, fields) when is_binary(key) do
    normalize_named_entry(key, value, fields)
  end

  defp normalize_entry(_entry, _fields), do: :error

  defp normalize_named_entry(name, value, fields) do
    if String.valid?(name) and Enum.any?(fields, &(Atom.to_string(&1) == name)) do
      {:ok, name, value}
    else
      :error
    end
  end

  defp canonical_route_order(routes) do
    Enum.filter(@routes, &(&1 in routes))
  end

  defp malformed_result(now) do
    checked_at =
      case normalize_now(now) do
        {:ok, valid} -> DateTime.to_iso8601(valid)
        {:error, :malformed} -> nil
      end

    %{
      "version" => @schema_version,
      "state" => "malformed_input",
      "ready" => false,
      "required_routes" => [],
      "blocking_routes" => [],
      "checked_at" => checked_at
    }
  end

  defp result(state, ready?, required_routes, blocking_routes, now) do
    %{
      "version" => @schema_version,
      "state" => state,
      "ready" => ready?,
      "required_routes" => required_routes,
      "blocking_routes" => blocking_routes,
      "checked_at" => DateTime.to_iso8601(now)
    }
  end
end
