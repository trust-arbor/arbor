defmodule Arbor.KernelRuntime.ActivationOnlyProfile.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.KernelRuntime.ActivationOnlyProfile.Core

  @moduletag :fast

  @forbidden_impurity [
    ~r/DateTime\.utc_now/,
    ~r/System\.(monotonic|os|system)_time/,
    ~r/:rand\./,
    ~r/:erlang\.unique_integer/,
    ~r/\bmake_ref\s*\(/,
    ~r/Application\.(get_env|fetch_env|put_env)/,
    ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
    ~r/:ets\./,
    ~r/\bLogger\./,
    ~r/\bProcess\.(send|send_after|monitor|spawn)/,
    ~r/\bFile\.(read|write|open|rm|ls)/,
    ~r/String\.to_atom/
  ]

  describe "project/1" do
    test "admits only inert Activation and owner-token ProtectedRegistry as conformant and blocked" do
      assert {:ok, document} = Core.project(admitted_candidate())
      assert document["schema"] == Core.schema()
      assert document["version"] == 1
      assert document["profile"] == Core.profile_name()
      assert document["evidence_status"] == "conformant"
      assert document["architecture_status"] == "blocked"

      assert document["children"] == [
               "Arbor.Common.Extension.Activation",
               "Arbor.Common.Extension.ProtectedRegistry"
             ]

      assert document["facilities"] == []
      assert document["findings"] == []
      refute Map.has_key?(document, "observations")
      assert {:ok, ^document} = Core.project(document)
    end

    test "blocks the current KernelRuntime.Application inventory with explicit findings" do
      assert {:ok, document} = Core.project(current_start_candidate())
      assert document["evidence_status"] == "conformant"
      assert document["architecture_status"] == "blocked"
      assert document["children"] == [
               "Arbor.Common.Application",
               "Arbor.Monitor.Application",
               "Arbor.Signals.Application"
             ]

      assert "oauth_and_network_pools" in document["facilities"]
      assert "full_signals_monitor_and_os_mon" in document["facilities"]

      subjects = Enum.map(document["findings"], &{&1["id"], &1["subject"]})

      assert {"forbidden_facility_present", "oauth_and_network_pools"} in subjects
      assert {"forbidden_facility_present", "full_signals_monitor_and_os_mon"} in subjects
      assert {"unexpected_first_party_started", "Arbor.Common.Application"} in subjects
      assert {"unexpected_first_party_started", "Arbor.Signals.Application"} in subjects
      assert {"unexpected_first_party_started", "Arbor.Monitor.Application"} in subjects

      assert Enum.all?(document["findings"], fn finding ->
               finding["owner"] == Core.finding_owner() and finding["severity"] == "blocker"
             end)
    end

    test "reports public Common ETS registries and cognition-stack facilities" do
      candidate =
        admitted_candidate()
        |> Map.put("children", [
          "Arbor.Common.NodeRegistry",
          "Arbor.Common.ReadableRegistry",
          "Arbor.Common.OAuth.HttpClient.Pool",
          "arbor_llm",
          "arbor_shell",
          "arbor_dashboard"
        ])

      assert {:ok, document} = Core.project(candidate)
      assert document["architecture_status"] == "blocked"

      subjects = Enum.map(document["findings"], &{&1["id"], &1["subject"]})

      assert {"forbidden_facility_present", "public_ets_authority"} in subjects
      assert {"forbidden_facility_present", "oauth_and_network_pools"} in subjects
      assert {"forbidden_facility_present", "llm_and_model_calls"} in subjects
      assert {"forbidden_facility_present", "shell_execution_backends"} in subjects
      assert {"forbidden_facility_present", "dashboard_voice_gateway_and_cognition"} in subjects
    end

    test "re-derives findings and ignores injected derived keys" do
      assert {:ok, blocked} = Core.project(current_start_candidate())
      assert blocked["findings"] != []

      injected =
        blocked
        |> Map.put("architecture_status", "ready")
        |> Map.put("findings", [])
        |> Map.put("observations", %{"os_pid" => 1})

      assert {:ok, ^blocked} = Core.project(injected)
    end

    test "drops observations and sorts closed lists" do
      candidate =
        admitted_candidate()
        |> Map.put("observations", %{"boot_time_us" => 12})
        |> Map.put("children", [
          "Arbor.Common.Extension.ProtectedRegistry",
          "Arbor.Common.Extension.Activation"
        ])
        |> Map.put("facilities", ["shell_execution_backends", "oauth_and_network_pools"])

      assert {:ok, document} = Core.project(candidate)
      refute Map.has_key?(document, "observations")

      assert document["children"] == [
               "Arbor.Common.Extension.Activation",
               "Arbor.Common.Extension.ProtectedRegistry"
             ]

      assert document["facilities"] == ["oauth_and_network_pools", "shell_execution_backends"]
      assert Enum.map(document["findings"], & &1["subject"]) ==
               ["oauth_and_network_pools", "shell_execution_backends"]
    end

    test "rejects extra, missing, unknown, and malformed fields" do
      assert {:error, :closed_keys} = Core.project(Map.put(admitted_candidate(), "hook", true))
      assert {:error, :closed_keys} = Core.project(Map.delete(admitted_candidate(), "children"))
      assert {:error, :invalid_candidate} = Core.project(:nope)
      assert {:error, :invalid_candidate} = Core.project(Date.utc_today())

      assert {:error, :exact_mismatch} =
               Core.project(Map.put(admitted_candidate(), "schema", "arbor.other.v1"))

      assert {:error, {:invalid_field, "children", :not_a_list}} =
               Core.project(Map.put(admitted_candidate(), "children", "nope"))

      assert {:error, {:invalid_field, "children", :duplicate}} =
               Core.project(
                 Map.put(admitted_candidate(), "children", [
                   "Arbor.Common.Extension.Activation",
                   "Arbor.Common.Extension.Activation"
                 ])
               )

      assert {:error, {:invalid_field, "facilities", :invalid_member}} =
               Core.project(Map.put(admitted_candidate(), "facilities", ["made_up"]))

      improper = ["Arbor.Common.Extension.Activation" | :not_a_list]

      assert {:error, {:invalid_field, "children", :improper_list}} =
               Core.project(Map.put(admitted_candidate(), "children", improper))
    end

    test "projects the combined children and facilities maxima without overflowing findings" do
      children = Enum.map(1..64, &"unexpected_child_#{&1}")
      facilities = known_facilities()

      assert {:ok, document} =
               Core.project(%{
                 admitted_candidate()
                 | "children" => children,
                   "facilities" => facilities
               })

      assert length(document["children"]) == 64
      assert document["facilities"] == Enum.sort(facilities)
      assert length(document["findings"]) == 64 + length(facilities)
      assert document["architecture_status"] == "blocked"

      one_facility = ["oauth_and_network_pools"]

      assert {:ok, sixty_five} =
               Core.project(%{
                 admitted_candidate()
                 | "children" => children,
                   "facilities" => one_facility
               })

      assert length(sixty_five["findings"]) == 65
    end

    test "rejects list, token, key-style, and exact-value boundary failures" do
      assert {:error, {:invalid_field, "children", :unbounded}} =
               Core.project(%{
                 admitted_candidate()
                 | "children" => Enum.map(1..65, &"unexpected_child_#{&1}")
               })

      assert {:error, {:invalid_field, "facilities", :unbounded}} =
               Core.project(%{
                 admitted_candidate()
                 | "facilities" => Enum.map(1..33, &"facility_#{&1}")
               })

      assert {:error, {:invalid_field, "children", :unbounded}} =
               Core.project(%{
                 admitted_candidate()
                 | "children" => [String.duplicate("c", 257)]
               })

      assert {:error, {:invalid_field, "children", :empty_string}} =
               Core.project(%{admitted_candidate() | "children" => [""]})

      assert {:error, {:invalid_field, "children", :invalid_string}} =
               Core.project(%{admitted_candidate() | "children" => ["has\0null"]})

      assert {:error, {:invalid_field, "children", :invalid_utf8}} =
               Core.project(%{admitted_candidate() | "children" => [<<0xFF>>]})

      assert {:error, {:invalid_field, "children", :not_a_string}} =
               Core.project(%{admitted_candidate() | "children" => [:not_a_string]})

      assert {:error, :non_string_keys} = Core.project(atom_candidate())

      mixed =
        admitted_candidate()
        |> Map.delete("schema")
        |> Map.put(:schema, Core.schema())

      assert {:error, :mixed_keys} = Core.project(mixed)

      assert {:error, :exact_mismatch} =
               Core.project(%{admitted_candidate() | "version" => 2})

      assert {:error, :exact_mismatch} =
               Core.project(%{admitted_candidate() | "profile" => "safe_recovery"})

      assert {:error, :invalid_candidate} = Core.project(%Date{year: 2026, month: 8, day: 17})
    end
  end

  test "the core source stays free of Process, IO, Application, and time" do
    path =
      Path.expand(
        "../../../../lib/arbor/kernel_runtime/activation_only_profile/core.ex",
        __DIR__
      )

    assert File.exists?(path)
    src = File.read!(path)

    Enum.each(@forbidden_impurity, fn re ->
      refute Regex.match?(re, src),
             "impure pattern #{inspect(re.source)} found in #{Path.basename(path)}"
    end)
  end

  defp admitted_candidate do
    %{
      "schema" => Core.schema(),
      "version" => 1,
      "profile" => Core.profile_name(),
      "children" => [
        "Arbor.Common.Extension.Activation",
        "Arbor.Common.Extension.ProtectedRegistry"
      ],
      "facilities" => []
    }
  end

  defp current_start_candidate do
    %{
      "schema" => Core.schema(),
      "version" => 1,
      "profile" => Core.profile_name(),
      "children" => [
        "Arbor.Common.Application",
        "Arbor.Signals.Application",
        "Arbor.Monitor.Application"
      ],
      "facilities" => []
    }
  end

  defp atom_candidate do
    %{
      schema: Core.schema(),
      version: 1,
      profile: Core.profile_name(),
      children: [],
      facilities: []
    }
  end

  defp known_facilities do
    [
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
    ]
  end
end
