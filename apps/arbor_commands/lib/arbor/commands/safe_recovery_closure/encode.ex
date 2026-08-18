defmodule Arbor.Commands.SafeRecoveryClosure.Encode do
  @moduledoc """
  Strict canonical JSON and a domain-separated digest for the E0B3A
  fresh-VM executable-closure evidence.

  Pure: no filesystem, process, or application-env access.
  """

  @schema "arbor.packaging.safe_recovery_closure.evidence.v1"
  @domain "arbor.packaging.safe_recovery_closure.evidence.v1\0"
  @version 1
  @profile_name "safe_recovery"
  @digest_re ~r/\A[0-9a-f]{64}\z/

  @candidate_keys [
    "artifact",
    "artifact_applications",
    "post_start",
    "pre_start",
    "profile",
    "schema",
    "selected_applications",
    "shutdown",
    "version"
  ]

  @evidence_keys [
    "architecture_status",
    "artifact",
    "artifact_applications",
    "closure_status",
    "evidence_status",
    "findings",
    "post_start",
    "pre_start",
    "profile",
    "schema",
    "selected_applications",
    "shutdown",
    "version"
  ]

  @profile_keys ["digest", "name"]
  @artifact_keys ["payload_tree_digest"]
  @app_keys ["class", "name"]
  @snapshot_keys [
    "applications",
    "ets_tables",
    "listeners",
    "logger_handlers",
    "modules",
    "nifs",
    "ports",
    "registered_names",
    "supervisors",
    "telemetry_handlers"
  ]
  @started_app_keys ["name", "state"]
  @module_keys ["application", "module"]
  @ets_keys ["heir", "name", "owner_application", "protection"]
  @port_keys ["name", "owner_application"]
  @supervisor_keys ["children", "name"]
  @listener_keys ["kind", "owner_application"]
  @shutdown_keys ["remaining_names", "status"]
  @finding_keys ["id", "owner", "severity", "subject"]

  @app_classes MapSet.new([
                 "runtime",
                 "selected_first_party",
                 "third_party",
                 "unexpected_first_party"
               ])
  @app_states MapSet.new(["started"])
  @protections MapSet.new(["private", "protected", "public"])
  @heirs MapSet.new(["none", "named"])
  @listener_kinds MapSet.new(["accept", "connect", "listen"])
  @shutdown_statuses MapSet.new(["bounded", "failed"])
  @closure_statuses MapSet.new(["closed", "open"])
  @severities MapSet.new(["blocker"])
  @finding_ids MapSet.new([
                 "forbidden_facility_present",
                 "selected_start_failed",
                 "third_party_started",
                 "unbounded_shutdown",
                 "unexpected_first_party_started",
                 "unexplained_module"
               ])

  @max_applications 128
  @max_modules 4_096
  @max_names 512
  @unique_facility_ids 6
  @max_shutdown_findings 1
  @selected_first_party_count 4
  @max_findings @max_applications + @unique_facility_ids + @max_modules +
                  @max_shutdown_findings + @selected_first_party_count
  @max_string 256

  @type validation_error :: {:error, atom()} | {:error, {:invalid_field, String.t(), atom()}}

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec domain() :: binary()
  def domain, do: @domain

  @spec version() :: pos_integer()
  def version, do: @version

  @spec profile_name() :: String.t()
  def profile_name, do: @profile_name

  @spec finding_owner() :: String.t()
  def finding_owner, do: "e0b3_fresh_vm_executable_closure"

  @spec validate_candidate(map()) :: :ok | validation_error()
  def validate_candidate(candidate) when is_map(candidate) and not is_struct(candidate) do
    with :ok <- exact_keys(candidate, @candidate_keys),
         :ok <- exact(candidate["schema"], @schema),
         :ok <- exact(candidate["version"], @version),
         :ok <- validate_shared_fields(candidate) do
      :ok
    end
  end

  def validate_candidate(_), do: {:error, :invalid_candidate}

  @spec validate_evidence(map()) :: :ok | validation_error()
  def validate_evidence(evidence) when is_map(evidence) and not is_struct(evidence) do
    with :ok <- exact_keys(evidence, @evidence_keys),
         :ok <- exact(evidence["schema"], @schema),
         :ok <- exact(evidence["version"], @version),
         :ok <- member(evidence["evidence_status"], MapSet.new(["conformant"])),
         :ok <- member(evidence["architecture_status"], MapSet.new(["blocked"])),
         :ok <- member(evidence["closure_status"], @closure_statuses),
         :ok <- validate_shared_fields(evidence),
         :ok <- validate_findings(evidence["findings"]) do
      :ok
    end
  end

  def validate_evidence(_), do: {:error, :invalid_evidence}

  defp validate_shared_fields(document) do
    with :ok <- validate_profile(document["profile"]),
         :ok <- validate_artifact(document["artifact"]),
         :ok <- validate_name_list(document["selected_applications"]),
         :ok <- validate_artifact_apps(document["artifact_applications"]),
         :ok <- validate_named_snapshot(document["pre_start"], "pre_start"),
         :ok <- validate_named_snapshot(document["post_start"], "post_start"),
         :ok <- validate_shutdown(document["shutdown"]) do
      :ok
    end
  end

  defp validate_named_snapshot(snapshot, field) do
    case validate_snapshot(snapshot) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_field, field, reason}}
    end
  end

  @spec evidence_digest(map()) :: {:ok, String.t()} | validation_error()
  def evidence_digest(evidence) when is_map(evidence) do
    with :ok <- validate_evidence(evidence),
         {:ok, json} <- canonical_json(evidence) do
      {:ok, framed_digest(@domain, json)}
    end
  end

  def evidence_digest(_), do: {:error, :invalid_evidence}

  @spec canonical_json(term()) :: {:ok, binary()} | validation_error()
  def canonical_json(value) do
    case Jason.encode(order_value(value)) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @spec framed_digest(binary(), binary()) :: String.t()
  def framed_digest(domain, json) when is_binary(domain) and is_binary(json) do
    :crypto.hash(:sha256, [domain, <<byte_size(json)::unsigned-big-64>>, json])
    |> Base.encode16(case: :lower)
  end

  defp validate_profile(profile) when is_map(profile) do
    with :ok <- exact_keys(profile, @profile_keys),
         :ok <- exact(profile["name"], @profile_name),
         :ok <- digest(profile["digest"]) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_field, "profile", reason}}
    end
  end

  defp validate_profile(_), do: {:error, {:invalid_field, "profile", :invalid_map}}

  defp validate_artifact(artifact) when is_map(artifact) do
    with :ok <- exact_keys(artifact, @artifact_keys),
         :ok <- digest(artifact["payload_tree_digest"]) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_field, "artifact", reason}}
    end
  end

  defp validate_artifact(_), do: {:error, {:invalid_field, "artifact", :invalid_map}}

  defp validate_name_list(list) when is_list(list) do
    with :ok <- bound(list, @max_applications),
         :ok <- unique_strings(list) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_field, "selected_applications", reason}}
    end
  end

  defp validate_name_list(_), do: {:error, {:invalid_field, "selected_applications", :not_a_list}}

  defp validate_artifact_apps(list) when is_list(list) do
    with :ok <- bound(list, @max_applications),
         :ok <- all_maps(list, @app_keys, &admit_artifact_app/1),
         :ok <- unique_strings(Enum.map(list, & &1["name"])) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_field, "artifact_applications", reason}}
    end
  end

  defp validate_artifact_apps(_),
    do: {:error, {:invalid_field, "artifact_applications", :not_a_list}}

  defp admit_artifact_app(app) do
    with :ok <- token(app["name"]),
         :ok <- member(app["class"], @app_classes) do
      :ok
    end
  end

  defp validate_snapshot(snapshot) when is_map(snapshot) do
    with :ok <- exact_keys(snapshot, @snapshot_keys),
         :ok <- all_maps(snapshot["applications"], @started_app_keys, &admit_started_app/1),
         :ok <- bound(snapshot["applications"], @max_applications),
         :ok <- all_maps(snapshot["modules"], @module_keys, &admit_module/1),
         :ok <- bound(snapshot["modules"], @max_modules),
         :ok <- unique_strings(snapshot["registered_names"]),
         :ok <- bound(snapshot["registered_names"], @max_names),
         :ok <- all_maps(snapshot["supervisors"], @supervisor_keys, &admit_supervisor/1),
         :ok <- bound(snapshot["supervisors"], @max_names),
         :ok <- all_maps(snapshot["ets_tables"], @ets_keys, &admit_ets/1),
         :ok <- bound(snapshot["ets_tables"], @max_names),
         :ok <- all_maps(snapshot["ports"], @port_keys, &admit_named/1),
         :ok <- bound(snapshot["ports"], @max_names),
         :ok <- unique_strings(snapshot["nifs"]),
         :ok <- bound(snapshot["nifs"], @max_names),
         :ok <- unique_strings(snapshot["logger_handlers"]),
         :ok <- bound(snapshot["logger_handlers"], @max_names),
         :ok <- unique_strings(snapshot["telemetry_handlers"]),
         :ok <- bound(snapshot["telemetry_handlers"], @max_names),
         :ok <- all_maps(snapshot["listeners"], @listener_keys, &admit_listener/1),
         :ok <- bound(snapshot["listeners"], @max_names) do
      :ok
    end
  end

  defp validate_snapshot(_), do: {:error, :invalid_snapshot}

  defp admit_started_app(app) do
    with :ok <- token(app["name"]),
         :ok <- member(app["state"], @app_states) do
      :ok
    end
  end

  defp admit_module(entry) do
    with :ok <- token(entry["module"]),
         :ok <- token(entry["application"]) do
      :ok
    end
  end

  defp admit_supervisor(entry) do
    with :ok <- token(entry["name"]),
         :ok <- unique_strings(entry["children"]),
         :ok <- bound(entry["children"], @max_names) do
      :ok
    end
  end

  defp admit_ets(entry) do
    with :ok <- token(entry["name"]),
         :ok <- token(entry["owner_application"]),
         :ok <- member(entry["protection"], @protections),
         :ok <- member(entry["heir"], @heirs) do
      :ok
    end
  end

  defp admit_named(entry) do
    with :ok <- token(entry["name"]),
         :ok <- token(entry["owner_application"]) do
      :ok
    end
  end

  defp admit_listener(entry) do
    with :ok <- member(entry["kind"], @listener_kinds),
         :ok <- token(entry["owner_application"]) do
      :ok
    end
  end

  defp validate_shutdown(shutdown) when is_map(shutdown) do
    with :ok <- exact_keys(shutdown, @shutdown_keys),
         :ok <- member(shutdown["status"], @shutdown_statuses),
         :ok <- unique_strings(shutdown["remaining_names"]),
         :ok <- bound(shutdown["remaining_names"], @max_names) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_field, "shutdown", reason}}
    end
  end

  defp validate_shutdown(_), do: {:error, {:invalid_field, "shutdown", :invalid_map}}

  defp validate_findings(list) when is_list(list) do
    with :ok <- bound(list, @max_findings),
         :ok <- all_maps(list, @finding_keys, &admit_finding/1) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_field, "findings", reason}}
    end
  end

  defp validate_findings(_), do: {:error, {:invalid_field, "findings", :not_a_list}}

  defp admit_finding(finding) do
    with :ok <- member(finding["id"], @finding_ids),
         :ok <- exact(finding["owner"], finding_owner()),
         :ok <- member(finding["severity"], @severities),
         :ok <- token(finding["subject"]) do
      :ok
    end
  end

  defp all_maps(list, keys, fun) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case item do
        map when is_map(map) and not is_struct(map) ->
          case exact_keys(map, keys) do
            :ok ->
              case fun.(map) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            error ->
              {:halt, error}
          end

        _other ->
          {:halt, {:error, :invalid_map}}
      end
    end)
  end

  defp all_maps(_, _, _), do: {:error, :not_a_list}

  defp exact_keys(map, keys) do
    actual = map |> Map.keys() |> Enum.sort()
    expected = Enum.sort(keys)

    cond do
      actual == expected -> :ok
      true -> {:error, :closed_keys}
    end
  end

  defp exact(value, value), do: :ok
  defp exact(_, _), do: {:error, :exact_mismatch}

  defp member(value, set) do
    if MapSet.member?(set, value), do: :ok, else: {:error, :invalid_member}
  end

  defp digest(value) when is_binary(value) do
    if Regex.match?(@digest_re, value), do: :ok, else: {:error, :invalid_digest}
  end

  defp digest(_), do: {:error, :not_a_string}

  defp token(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty_string}
      byte_size(value) > @max_string -> {:error, :unbounded}
      String.contains?(value, <<0>>) -> {:error, :invalid_string}
      true -> :ok
    end
  end

  defp token(_), do: {:error, :not_a_string}

  defp unique_strings(list) when is_list(list) do
    with :ok <-
           Enum.reduce_while(list, :ok, fn item, :ok ->
             case token(item) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end) do
      if Enum.uniq(list) == list, do: :ok, else: {:error, :duplicate}
    end
  end

  defp unique_strings(_), do: {:error, :not_a_list}

  defp bound(list, max) when is_list(list) and is_integer(max) do
    if length(list) <= max, do: :ok, else: {:error, :unbounded}
  end

  defp bound(_, _), do: {:error, :not_a_list}

  defp order_value(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new(fn {key, value} -> {key, order_value(value)} end)
  end

  defp order_value(list) when is_list(list), do: Enum.map(list, &order_value/1)
  defp order_value(other), do: other
end
