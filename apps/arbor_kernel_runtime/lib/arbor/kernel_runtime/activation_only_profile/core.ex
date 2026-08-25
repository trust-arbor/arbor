defmodule Arbor.KernelRuntime.ActivationOnlyProfile.Core do
  @moduledoc """
  Pure construct core for the P1A activation-only runtime profile.

  `project/1` admits a closed in-memory candidate of Kernel Runtime
  children and facilities, derives findings, and returns a string-keyed
  canonical document. No Process, IO, Application, or time is consulted.

  `evidence_status` is always `"conformant"` and `architecture_status`
  is always `"blocked"` in this packet, including the empty-findings
  admitted set. Empty findings mean the candidate matches the profile,
  not that the runtime is ready: production Application.start stays
  unwired.
  """

  @schema "arbor.kernel_runtime.activation_only_profile.v1"
  @profile_name "activation_only"
  @version 1
  @finding_owner "p1a_safe_profile_closure"

  @optional_drop ["observations"]
  @derived_keys ["architecture_status", "evidence_status", "findings"]

  @candidate_keys ["children", "facilities", "profile", "schema", "version"]
  @document_keys [
    "architecture_status",
    "children",
    "evidence_status",
    "facilities",
    "findings",
    "profile",
    "schema",
    "version"
  ]
  @finding_keys ["id", "owner", "severity", "subject"]

  @admitted_children MapSet.new([
                       "Arbor.Common.Extension.Activation",
                       "Arbor.Common.Extension.ProtectedRegistry",
                       "Arbor.KernelRuntime.BootProfileBinding"
                     ])

  @facility_ids MapSet.new([
                  "dashboard_voice_gateway_and_cognition",
                  "dynamic_compile_eval_and_reload",
                  "full_signals_monitor_and_os_mon",
                  "llm_and_model_calls",
                  "oauth_and_network_pools",
                  "postgres_sqlite_and_vector_providers",
                  "public_ets_authority",
                  "remote_provider_rpc_before_authorization",
                  "shell_execution_backends",
                  "skill_plugin_scan_and_git_fetch",
                  "unverified_or_third_party_in_vm_code"
                ])

  @finding_ids MapSet.new([
                 "forbidden_facility_present",
                 "unexpected_first_party_started"
               ])

  @child_facilities %{
    "Arbor.Common.ActionRegistry" => "public_ets_authority",
    "Arbor.Common.Application" => "oauth_and_network_pools",
    "Arbor.Common.CodeReloader" => "dynamic_compile_eval_and_reload",
    "Arbor.Common.ComputeRegistry" => "public_ets_authority",
    "Arbor.Common.NodeRegistry" => "public_ets_authority",
    "Arbor.Common.OAuth.HttpClient.Pool" => "oauth_and_network_pools",
    "Arbor.Common.PipelineResolver" => "public_ets_authority",
    "Arbor.Common.ReadableRegistry" => "public_ets_authority",
    "Arbor.Common.SkillLibrary" => "skill_plugin_scan_and_git_fetch",
    "Arbor.Common.WriteableRegistry" => "public_ets_authority",
    "Arbor.Monitor.Application" => "full_signals_monitor_and_os_mon",
    "Arbor.Monitor.HealingSupervisor" => "full_signals_monitor_and_os_mon",
    "Arbor.Monitor.MetricsStore" => "full_signals_monitor_and_os_mon",
    "Arbor.Monitor.Poller" => "full_signals_monitor_and_os_mon",
    "Arbor.Monitor.SupervisorMonitor" => "full_signals_monitor_and_os_mon",
    "Arbor.Signals.Application" => "full_signals_monitor_and_os_mon",
    "Arbor.Signals.Bus" => "full_signals_monitor_and_os_mon",
    "Arbor.Signals.Channels" => "full_signals_monitor_and_os_mon",
    "Arbor.Signals.Relay" => "full_signals_monitor_and_os_mon",
    "Arbor.Signals.Store" => "full_signals_monitor_and_os_mon",
    "Arbor.Signals.TopicKeys" => "full_signals_monitor_and_os_mon",
    "arbor_agent" => "dashboard_voice_gateway_and_cognition",
    "arbor_ai" => "dashboard_voice_gateway_and_cognition",
    "arbor_dashboard" => "dashboard_voice_gateway_and_cognition",
    "arbor_gateway" => "dashboard_voice_gateway_and_cognition",
    "arbor_llm" => "llm_and_model_calls",
    "arbor_monitor" => "full_signals_monitor_and_os_mon",
    "arbor_orchestrator" => "dashboard_voice_gateway_and_cognition",
    "arbor_registry_pg" => "public_ets_authority",
    "arbor_sandbox" => "skill_plugin_scan_and_git_fetch",
    "arbor_shell" => "shell_execution_backends",
    "arbor_signals" => "full_signals_monitor_and_os_mon",
    "arbor_voice" => "dashboard_voice_gateway_and_cognition",
    "os_mon" => "full_signals_monitor_and_os_mon"
  }

  @max_children 64
  @max_facilities 32
  # One unexpected-child finding plus one facility finding at the list maxima.
  @max_findings 96
  @max_string 256

  @doc "Closed profile schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Closed profile name."
  @spec profile_name() :: String.t()
  def profile_name, do: @profile_name

  @doc "Owner recorded on derived findings."
  @spec finding_owner() :: String.t()
  def finding_owner, do: @finding_owner

  @doc "Admit a closed candidate and return the canonical profile document."
  @spec project(map()) :: {:ok, map()} | {:error, term()}
  def project(candidate) when is_map(candidate) and not is_struct(candidate) do
    case admit_candidate(candidate) do
      {:ok, admitted} ->
        document = assemble(admitted)

        case validate_document(document) do
          :ok -> {:ok, document}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  def project(_), do: {:error, :invalid_candidate}

  defp admit_candidate(candidate) do
    dropped = Map.drop(candidate, @optional_drop ++ @derived_keys)

    with :ok <- exact_keys(dropped, @candidate_keys),
         :ok <- exact(dropped["schema"], @schema),
         :ok <- exact(dropped["version"], @version),
         :ok <- exact(dropped["profile"], @profile_name),
         :ok <- validate_name_list(dropped["children"], @max_children, "children"),
         :ok <- validate_facility_list(dropped["facilities"]) do
      {:ok, dropped}
    end
  end

  defp assemble(candidate) do
    children = Enum.sort(candidate["children"])
    facilities = implied_facilities(children, candidate["facilities"])
    findings = derive_findings(children, facilities)

    %{
      "schema" => @schema,
      "version" => @version,
      "profile" => @profile_name,
      "children" => children,
      "facilities" => facilities,
      "findings" => findings,
      # Always conformant/blocked: empty findings are not a ready runtime.
      "evidence_status" => "conformant",
      "architecture_status" => "blocked"
    }
  end

  defp derive_findings(children, facilities) do
    child_findings =
      children
      |> Enum.reject(&MapSet.member?(@admitted_children, &1))
      |> Enum.map(&finding("unexpected_first_party_started", &1))

    facility_findings = Enum.map(facilities, &finding("forbidden_facility_present", &1))

    (child_findings ++ facility_findings)
    |> Enum.sort_by(&{&1["id"], &1["subject"]})
  end

  defp implied_facilities(children, declared) do
    implied =
      children
      |> Enum.flat_map(fn name ->
        case Map.get(@child_facilities, name) do
          nil -> []
          facility -> [facility]
        end
      end)

    Enum.sort(Enum.uniq(declared ++ implied))
  end

  defp finding(id, subject) do
    %{
      "id" => id,
      "owner" => @finding_owner,
      "severity" => "blocker",
      "subject" => subject
    }
  end

  defp validate_document(document) do
    with :ok <- exact_keys(document, @document_keys),
         :ok <- exact(document["schema"], @schema),
         :ok <- exact(document["version"], @version),
         :ok <- exact(document["profile"], @profile_name),
         :ok <- exact(document["evidence_status"], "conformant"),
         :ok <- exact(document["architecture_status"], "blocked"),
         :ok <- validate_name_list(document["children"], @max_children, "children"),
         :ok <- validate_facility_list(document["facilities"]) do
      validate_findings(document["findings"])
    end
  end

  defp validate_name_list(list, max, field) do
    case take_proper_list(list, max) do
      {:ok, items} -> wrap_field(unique_strings(items), field)
      {:error, reason} -> {:error, {:invalid_field, field, reason}}
    end
  end

  defp wrap_field(:ok, _field), do: :ok
  defp wrap_field({:error, reason}, field), do: {:error, {:invalid_field, field, reason}}

  defp validate_facility_list(list) do
    case validate_name_list(list, @max_facilities, "facilities") do
      :ok -> known_facilities(list)
      {:error, _} = error -> error
    end
  end

  defp known_facilities(list) do
    Enum.reduce_while(list, :ok, fn id, :ok ->
      if MapSet.member?(@facility_ids, id) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_field, "facilities", :invalid_member}}}
      end
    end)
  end

  defp validate_findings(list) do
    case take_proper_list(list, @max_findings) do
      {:ok, items} ->
        Enum.reduce_while(items, :ok, fn item, :ok ->
          case admit_finding(item) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_field, "findings", reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:invalid_field, "findings", reason}}
    end
  end

  defp admit_finding(finding) when is_map(finding) and not is_struct(finding) do
    with :ok <- exact_keys(finding, @finding_keys),
         :ok <- member(finding["id"], @finding_ids),
         :ok <- exact(finding["owner"], @finding_owner),
         :ok <- exact(finding["severity"], "blocker"),
         :ok <- token(finding["subject"]) do
      :ok
    end
  end

  defp admit_finding(_), do: {:error, :invalid_map}

  defp exact_keys(map, keys) when is_map(map) and not is_struct(map) do
    actual = Map.keys(map)

    cond do
      Enum.any?(actual, &is_atom/1) and Enum.any?(actual, &is_binary/1) ->
        {:error, :mixed_keys}

      Enum.any?(actual, &(not is_binary(&1))) ->
        {:error, :non_string_keys}

      Enum.sort(actual) == Enum.sort(keys) ->
        :ok

      true ->
        {:error, :closed_keys}
    end
  end

  defp exact_keys(_, _), do: {:error, :invalid_map}

  defp exact(value, value), do: :ok
  defp exact(_, _), do: {:error, :exact_mismatch}

  defp member(value, set) do
    if MapSet.member?(set, value), do: :ok, else: {:error, :invalid_member}
  end

  defp unique_strings(list) do
    case Enum.reduce_while(list, :ok, fn item, :ok ->
           case token(item) do
             :ok -> {:cont, :ok}
             error -> {:halt, error}
           end
         end) do
      :ok -> if Enum.uniq(list) == list, do: :ok, else: {:error, :duplicate}
      {:error, _} = error -> error
    end
  end

  defp token(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty_string}
      byte_size(value) > @max_string -> {:error, :unbounded}
      not String.valid?(value) -> {:error, :invalid_utf8}
      String.contains?(value, <<0>>) -> {:error, :invalid_string}
      true -> :ok
    end
  end

  defp token(_), do: {:error, :not_a_string}

  defp take_proper_list(list, max) when is_list(list) and is_integer(max) do
    take_proper_list(list, max, 0, [])
  end

  defp take_proper_list(_, _), do: {:error, :not_a_list}

  defp take_proper_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], max, count, acc) do
    if count >= max do
      {:error, :unbounded}
    else
      take_proper_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_proper_list(_, _, _, _), do: {:error, :improper_list}
end
