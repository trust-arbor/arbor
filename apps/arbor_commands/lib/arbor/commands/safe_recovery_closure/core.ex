defmodule Arbor.Commands.SafeRecoveryClosure.Core do
  @moduledoc """
  Pure construct core for E0B3A fresh-VM executable-closure evidence.

  `project/1` admits a closed in-memory candidate or a previously
  projected evidence document, drops volatile observation fields and
  derived status/finding keys, derives findings, and returns a
  string-keyed canonical evidence document. No filesystem, Git, peer,
  cookie, or process state is consulted.
  """

  alias Arbor.Commands.SafeRecoveryClosure.Encode

  @optional_drop ["observations"]

  @derived_keys [
    "architecture_status",
    "closure_status",
    "evidence_status",
    "findings"
  ]

  @facility_apps %{
    "arbor_agent" => "dashboard_voice_gateway_and_cognition",
    "arbor_ai" => "dashboard_voice_gateway_and_cognition",
    "arbor_dashboard" => "dashboard_voice_gateway_and_cognition",
    "arbor_gateway" => "dashboard_voice_gateway_and_cognition",
    "arbor_llm" => "llm_and_model_calls",
    "arbor_monitor" => "full_signals_monitor_and_os_mon",
    "arbor_orchestrator" => "dashboard_voice_gateway_and_cognition",
    "arbor_sandbox" => "skill_plugin_scan_and_git_fetch",
    "arbor_shell" => "shell_execution_backends",
    "arbor_signals" => "full_signals_monitor_and_os_mon",
    "arbor_voice" => "dashboard_voice_gateway_and_cognition",
    "ecto" => "postgres_sqlite_and_vector_providers",
    "ecto_sql" => "postgres_sqlite_and_vector_providers",
    "exqlite" => "postgres_sqlite_and_vector_providers",
    "os_mon" => "full_signals_monitor_and_os_mon",
    "postgrex" => "postgres_sqlite_and_vector_providers",
    "sqlite_vec" => "postgres_sqlite_and_vector_providers"
  }

  @doc "Closed evidence schema identifier."
  @spec schema() :: String.t()
  def schema, do: Encode.schema()

  @doc "Admit a closed candidate and return canonical closure evidence."
  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(candidate) when is_map(candidate) and not is_struct(candidate) do
    with {:ok, admitted} <- admit_candidate(candidate),
         evidence <- assemble(admitted),
         :ok <- Encode.validate_evidence(evidence) do
      {:ok, evidence}
    end
  end

  def project(_), do: {:error, :invalid_candidate}

  defp admit_candidate(candidate) do
    dropped = Map.drop(candidate, @optional_drop ++ @derived_keys)

    case Encode.validate_candidate(dropped) do
      :ok -> {:ok, dropped}
      error -> error
    end
  end

  defp assemble(candidate) do
    findings = derive_findings(candidate)

    closure =
      if findings == [] and candidate["shutdown"]["status"] == "bounded",
        do: "closed",
        else: "open"

    %{
      "schema" => Encode.schema(),
      "version" => Encode.version(),
      "profile" => candidate["profile"],
      "artifact" => candidate["artifact"],
      "selected_applications" => Enum.sort(candidate["selected_applications"]),
      "artifact_applications" =>
        Enum.sort_by(candidate["artifact_applications"], &{&1["name"], &1["class"]}),
      "pre_start" => sort_snapshot(candidate["pre_start"]),
      "post_start" => sort_snapshot(candidate["post_start"]),
      "shutdown" => %{
        "status" => candidate["shutdown"]["status"],
        "remaining_names" => Enum.sort(candidate["shutdown"]["remaining_names"])
      },
      "findings" => findings,
      "evidence_status" => "conformant",
      "architecture_status" => "blocked",
      "closure_status" => closure
    }
  end

  defp derive_findings(candidate) do
    classes = Map.new(candidate["artifact_applications"], &{&1["name"], &1["class"]})
    selected = MapSet.new(candidate["selected_applications"])
    started = started_names(candidate["post_start"])

    class_findings =
      started
      |> Enum.flat_map(fn name ->
        case Map.get(classes, name) do
          "unexpected_first_party" ->
            [finding("unexpected_first_party_started", name)]

          "third_party" ->
            [finding("third_party_started", name)]

          _other ->
            []
        end
      end)

    facility_findings =
      started
      |> Enum.flat_map(fn name ->
        case Map.get(@facility_apps, name) do
          nil -> []
          facility -> [finding("forbidden_facility_present", facility)]
        end
      end)
      |> Enum.uniq_by(& &1["subject"])

    module_findings =
      candidate["post_start"]["modules"]
      |> Enum.flat_map(fn entry ->
        app = entry["application"]

        cond do
          MapSet.member?(selected, app) ->
            []

          Map.get(classes, app) == "runtime" ->
            []

          true ->
            [finding("unexplained_module", entry["module"])]
        end
      end)

    shutdown_findings =
      if candidate["shutdown"]["status"] == "bounded" do
        []
      else
        [finding("unbounded_shutdown", "shutdown")]
      end

    start_findings =
      candidate["selected_applications"]
      |> Enum.reject(&(&1 in started))
      |> Enum.map(&finding("selected_start_failed", &1))

    (class_findings ++
       facility_findings ++
       module_findings ++
       shutdown_findings ++
       start_findings)
    |> Enum.sort_by(&{&1["id"], &1["subject"]})
  end

  defp finding(id, subject) do
    %{
      "id" => id,
      "owner" => Encode.finding_owner(),
      "severity" => "blocker",
      "subject" => subject
    }
  end

  defp started_names(%{"applications" => apps}) do
    apps
    |> Enum.filter(&(&1["state"] == "started"))
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  defp sort_snapshot(snapshot) do
    %{
      "applications" => Enum.sort_by(snapshot["applications"], & &1["name"]),
      "modules" => Enum.sort_by(snapshot["modules"], &{&1["module"], &1["application"]}),
      "registered_names" => Enum.sort(snapshot["registered_names"]),
      "supervisors" =>
        snapshot["supervisors"]
        |> Enum.map(&%{&1 | "children" => Enum.sort(&1["children"])})
        |> Enum.sort_by(& &1["name"]),
      "ets_tables" => Enum.sort_by(snapshot["ets_tables"], & &1["name"]),
      "ports" => Enum.sort_by(snapshot["ports"], & &1["name"]),
      "nifs" => Enum.sort(snapshot["nifs"]),
      "logger_handlers" => Enum.sort(snapshot["logger_handlers"]),
      "telemetry_handlers" => Enum.sort(snapshot["telemetry_handlers"]),
      "listeners" => Enum.sort_by(snapshot["listeners"], &{&1["kind"], &1["owner_application"]})
    }
  end
end
