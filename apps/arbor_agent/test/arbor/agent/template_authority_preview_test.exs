defmodule Arbor.Agent.TemplateAuthorityPreviewTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.Profile
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityPreview
  alias Arbor.Contracts.Security.Capability

  defmodule EffectsObserver do
    @moduledoc false
    @table :template_authority_preview_effects

    def ensure! do
      case :ets.whereis(@table) do
        :undefined ->
          _ = :ets.new(@table, [:named_table, :public, :set])
          :ets.insert(@table, {:events, []})
          :ok

        _ ->
          :ok
      end
    end

    def reset! do
      ensure!()
      :ets.insert(@table, {:events, []})
      :ok
    end

    def record(event) do
      ensure!()

      case :ets.lookup(@table, :events) do
        [{:events, events}] -> :ets.insert(@table, {:events, [event | events]})
        _ -> :ets.insert(@table, {:events, [event]})
      end

      :ok
    end

    def events do
      ensure!()

      case :ets.lookup(@table, :events) do
        [{:events, events}] -> Enum.reverse(events)
        _ -> []
      end
    end
  end

  defmodule FakeProfileStore do
    @authority_keys [
      "agent_id",
      "template",
      "initial_capabilities",
      "metadata",
      "version",
      :agent_id,
      :template,
      :initial_capabilities,
      :metadata,
      :version
    ]

    def load_profile_authority_readonly(agent_id) do
      EffectsObserver.record({:load_profile_authority_readonly, agent_id})

      case Process.get({__MODULE__, :profile}) do
        %Profile{} = profile -> {:ok, profile |> Profile.serialize() |> Map.take(@authority_keys)}
        profile when is_map(profile) -> {:ok, Map.take(profile, @authority_keys)}
        {:error, _} = err -> err
        nil -> {:error, :not_found}
        other -> other
      end
    end

    def load_profile_readonly(agent_id) do
      EffectsObserver.record({:load_profile_readonly, agent_id})
      flunk("preview must preserve serialized field-presence evidence")
    end

    def store_profile(profile) do
      EffectsObserver.record({:store_profile, profile})
      flunk("preview must not store profiles")
    end

    def load_profile(agent_id) do
      EffectsObserver.record({:load_profile_migrating, agent_id})
      flunk("preview must use the serialized read-only profile boundary")
    end
  end

  defmodule FakeTemplateStore do
    def get_current(name) do
      EffectsObserver.record({:get_current, name})

      case Process.get({__MODULE__, :template}) do
        {:ok, data} -> {:ok, data}
        {:error, _} = err -> err
        data when is_map(data) -> {:ok, data}
        nil -> {:error, :not_found}
      end
    end

    def get(name) do
      EffectsObserver.record({:get_cache_write, name})
      flunk("preview must use get_current")
    end

    def put(name, data) do
      EffectsObserver.record({:put, name, data})
      flunk("preview must not put templates")
    end
  end

  defmodule FakeSecurity do
    def list_capabilities(principal_id, opts \\ []) do
      EffectsObserver.record({:list_capabilities, principal_id, opts})

      case Process.get({__MODULE__, :list_result}) do
        {:error, reason} -> {:error, reason}
        caps when is_list(caps) -> {:ok, caps}
        nil -> {:ok, Process.get({__MODULE__, :caps}, [])}
        other -> other
      end
    end

    def grant(opts) do
      EffectsObserver.record({:grant, opts})
      flunk("preview must not grant")
    end

    def revoke(id) do
      EffectsObserver.record({:revoke, id})
      flunk("preview must not revoke")
    end
  end

  defmodule FakeTrust do
    def get_trust_profile(agent_id) do
      EffectsObserver.record({:get_trust_profile, agent_id})

      case Process.get({__MODULE__, :trust}) do
        {:ok, profile} when is_map(profile) ->
          bound =
            if Map.has_key?(profile, :agent_id) or Map.has_key?(profile, "agent_id") do
              profile
            else
              Map.put(profile, :agent_id, agent_id)
            end

          {:ok, bound}

        {:raw, profile} ->
          {:ok, profile}

        {:error, _} = err ->
          err

        nil ->
          {:error, :not_found}

        other ->
          other
      end
    end

    def ensure_trust_profile(agent_id, opts) do
      EffectsObserver.record({:ensure_trust_profile, agent_id, opts})
      flunk("preview must not write trust")
    end
  end

  setup do
    EffectsObserver.reset!()
    Process.delete({FakeProfileStore, :profile})
    Process.delete({FakeTemplateStore, :template})
    Process.delete({FakeSecurity, :caps})
    Process.delete({FakeSecurity, :list_result})
    Process.delete({FakeTrust, :trust})
    :ok
  end

  defp deps do
    %{
      profile_store: FakeProfileStore,
      template_store: FakeTemplateStore,
      security: FakeSecurity,
      trust: FakeTrust,
      repo_root: "/Users/dev/arbor"
    }
  end

  defp template_data do
    %{
      "name" => "scout",
      "required_capabilities" => [
        %{"resource" => "arbor://fs/write"},
        %{"resource" => "arbor://orchestrator/execute"}
      ],
      "trust_preset" => %{
        "baseline" => "block",
        "rules" => %{
          "arbor://fs/write" => "ask",
          "arbor://orchestrator/execute" => "auto"
        }
      },
      "template_source" => %{
        "name" => "scout",
        "layer" => "shipped",
        "path" => "/abs/secret/scout.md"
      }
    }
  end

  defp base_profile(opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    caps = Keyword.get(opts, :initial_capabilities, [])

    %Profile{
      agent_id: "agent_preview1",
      character: Arbor.Agent.Character.new(name: "Scout"),
      template: "scout",
      initial_capabilities: caps,
      metadata: metadata,
      version: Keyword.get(opts, :version, 1)
    }
  end

  test "invokes only the four read collaborators and never mutates" do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("scout", template_data())

    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{"arbor://fs/write" => :ask}}}
    )

    {:ok, tagged} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: "agent_preview1",
        metadata: %{
          source: :template_authority_policy,
          version: 1,
          template: "scout",
          template_digest: envelope["digest"]
        }
      )

    Process.put({FakeSecurity, :caps}, [tagged])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["kind"] == "template_authority_preview"
    assert report["target_agent_id"] == "agent_preview1"
    assert is_binary(report["reconciliation_digest"])
    refute inspect(report) =~ "/abs/secret"
    refute inspect(report) =~ "cap_"

    events = EffectsObserver.events()

    assert Enum.sort(Enum.map(events, &elem(&1, 0))) ==
             Enum.sort([
               :load_profile_authority_readonly,
               :get_current,
               :list_capabilities,
               :get_trust_profile
             ])

    refute Enum.any?(events, fn
             {:grant, _} -> true
             {:revoke, _} -> true
             {:store_profile, _} -> true
             {:put, _, _} -> true
             {:get_cache_write, _} -> true
             {:ensure_trust_profile, _, _} -> true
             _ -> false
           end)
  end

  test "profile not found yields unavailable without leaking errors" do
    Process.put({FakeProfileStore, :profile}, {:error, :not_found})

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "unavailable"
    refute inspect(report) =~ "not_found"
    refute inspect(report) =~ "ErlangError"
  end

  test "security list failure yields unavailable" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())
    Process.put({FakeSecurity, :list_result}, {:error, {:boom, self()}})

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :ask, rules: %{}}}
    )

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "unavailable"
    refute inspect(report) =~ "boom"
  end

  test "malformed ownership fails closed as invalid" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{"arbor://fs/write" => :ask}}}
    )

    {:ok, a} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: "agent_preview1",
        constraints: %{rate_limit: 1},
        metadata: %{source: :template_authority_policy}
      )

    {:ok, b} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: "agent_preview1",
        constraints: %{rate_limit: 9},
        metadata: %{source: :template_authority_policy}
      )

    Process.put({FakeSecurity, :caps}, [a, b])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
  end

  test "current marker with matching desired yields current status" do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("scout", template_data())

    metadata =
      TemplateAuthorityPolicy.put_metadata(
        %{"template_source" => %{"name" => "scout", "layer" => "shipped"}},
        envelope
      )

    Process.put(
      {FakeProfileStore, :profile},
      base_profile(
        metadata: metadata,
        initial_capabilities: [
          %{"resource" => "arbor://fs/write"},
          %{"resource" => "arbor://orchestrator/execute"}
        ]
      )
    )

    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok,
       %{
         baseline: :block,
         rules: %{
           "arbor://fs/write" => :ask,
           "arbor://orchestrator/execute" => :auto
         }
       }}
    )

    {:ok, write} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: "agent_preview1",
        metadata: %{
          source: :template_authority_policy,
          version: 1,
          template: "scout",
          template_digest: envelope["digest"]
        }
      )

    {:ok, orch} =
      Capability.new(
        resource_uri: "arbor://orchestrator/execute/**",
        principal_id: "agent_preview1",
        metadata: %{
          source: :template_authority_policy,
          version: 1,
          template: "scout",
          template_digest: envelope["digest"]
        }
      )

    Process.put({FakeSecurity, :caps}, [write, orch])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "current"
    assert report["stored_marker"]["state"] == "current"
    assert report["desired_declaration_digest"] == envelope["digest"]
  end

  test "bounds preserved unmanaged resources" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{"arbor://fs/write" => :ask}}}
    )

    extras =
      for i <- 1..80 do
        {:ok, cap} =
          Capability.new(
            resource_uri: "arbor://custom/resource#{i}",
            principal_id: "agent_preview1"
          )

        cap
      end

    Process.put({FakeSecurity, :caps}, extras)

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["preserved_unmanaged"]["count"] == 80
    assert length(report["preserved_unmanaged"]["resources"]) == 64
  end

  test "invalid collaborator observations dominate unavailable ones" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    # Template missing → unavailable; trust malformed → invalid. Invalid wins.
    Process.put({FakeTemplateStore, :template}, {:error, :not_found})
    Process.put({FakeTrust, :trust}, {:ok, %{baseline: :not_a_mode, rules: %{}}})
    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
    assert report["reconciliation_digest"] == nil
    refute inspect(report) =~ "not_a_mode"
  end

  test "malformed profile provenance fails closed as invalid" do
    Process.put(
      {FakeProfileStore, :profile},
      base_profile(metadata: %{"template_source" => %{"name" => "scout", "layer" => "evil"}})
    )

    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
  end

  test "profile principal mismatch fails closed as invalid" do
    Process.put(
      {FakeProfileStore, :profile},
      %{base_profile() | agent_id: "agent_other"}
    )

    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
  end

  test "capability principal mismatch fails closed as invalid" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{"arbor://fs/write" => :ask}}}
    )

    {:ok, foreign} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: "agent_other",
        metadata: %{source: :template_authority_policy}
      )

    Process.put({FakeSecurity, :caps}, [foreign])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
  end

  test "conflicting trust atom/string baseline fails closed as invalid" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{:baseline => :block, "baseline" => "ask", :rules => %{}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
  end

  test "Lifecycle-equivalent production repo root has no trailing slash" do
    # Injected string already admitted without trailing slash; production path
    # matches Lifecycle repo_root_for_capabilities spelling (trim_trailing "/").
    deps = %{deps() | repo_root: "/Users/dev/arbor/"}

    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{"arbor://fs/write" => :ask}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps)

    assert is_map(report)
    refute report["status"] == "unavailable"
  end

  test "invalid authority marker outranks unavailable collaborator" do
    # Malformed stored marker participates in aggregate rank so it is not
    # skipped when another collaborator (template) is unavailable.
    Process.put(
      {FakeProfileStore, :profile},
      base_profile(
        metadata: %{
          "template_authority_policy" => %{
            "kind" => "template_authority_policy",
            "broken" => true
          }
        }
      )
    )

    Process.put({FakeTemplateStore, :template}, {:error, :not_found})

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert report["status"] == "invalid"
    assert report["reconciliation_digest"] == nil
  end

  test "present template_source requires explicit name and closed layer; name mismatch is not invalid" do
    # Valid provenance whose name differs from profile.template is admitted —
    # pure core treats mismatch as drift evidence, not shell-invalid.
    Process.put(
      {FakeProfileStore, :profile},
      base_profile(
        metadata: %{"template_source" => %{"name" => "other_template", "layer" => "user"}}
      )
    )

    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{"arbor://fs/write" => :ask}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    assert {:ok, report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    refute report["status"] == "invalid"
    assert report["template"]["persisted_provenance"]["name"] == "other_template"
    assert report["template"]["persisted_provenance"]["layer"] == "user"

    # Present map missing layer fails closed.
    Process.put(
      {FakeProfileStore, :profile},
      base_profile(metadata: %{"template_source" => %{"name" => "scout"}})
    )

    assert {:ok, missing_layer} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert missing_layer["status"] == "invalid"

    # Present map missing name fails closed.
    Process.put(
      {FakeProfileStore, :profile},
      base_profile(metadata: %{"template_source" => %{"layer" => "shipped"}})
    )

    assert {:ok, missing_name} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert missing_name["status"] == "invalid"
  end

  test "nil metadata, non-positive version, and nil initial_capabilities fail closed" do
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{}}}
    )

    Process.put({FakeSecurity, :caps}, [])

    Process.put(
      {FakeProfileStore, :profile},
      %{base_profile() | metadata: nil}
    )

    assert {:ok, meta_report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert meta_report["status"] == "invalid"

    Process.put(
      {FakeProfileStore, :profile},
      %{base_profile() | version: 0}
    )

    assert {:ok, version_report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert version_report["status"] == "invalid"

    Process.put(
      {FakeProfileStore, :profile},
      %{base_profile() | initial_capabilities: nil}
    )

    assert {:ok, caps_report} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert caps_report["status"] == "invalid"
  end

  test "security regression: missing serialized authority fields are not restored by profile defaults" do
    Process.put({FakeTemplateStore, :template}, template_data())
    Process.put({FakeTrust, :trust}, {:ok, %{baseline: :block, rules: %{}}})
    Process.put({FakeSecurity, :caps}, [])

    serialized = Profile.serialize(base_profile())

    for missing_field <- ["metadata", "version", "initial_capabilities"] do
      Process.put({FakeProfileStore, :profile}, Map.delete(serialized, missing_field))

      assert {:ok, report} =
               TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

      assert report["status"] == "invalid",
             "expected missing persisted #{missing_field} to fail closed"
    end
  end

  test "security regression: trust observations require an exact target principal" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())
    Process.put({FakeSecurity, :caps}, [])

    for trust <- [
          %{baseline: :block, rules: %{}},
          %{agent_id: nil, baseline: :block, rules: %{}},
          %{agent_id: "agent_other", baseline: :block, rules: %{}}
        ] do
      Process.put({FakeTrust, :trust}, {:raw, trust})

      assert {:ok, report} =
               TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

      assert report["status"] == "invalid",
             "expected unbound trust profile #{inspect(Map.get(trust, :agent_id))} to fail closed"
    end
  end

  test "improper capability list and missing principal fail closed as invalid" do
    Process.put({FakeProfileStore, :profile}, base_profile())
    Process.put({FakeTemplateStore, :template}, template_data())

    Process.put(
      {FakeTrust, :trust},
      {:ok, %{baseline: :block, rules: %{}}}
    )

    # Improper list must not be Enum-traversed.
    Process.put({FakeSecurity, :list_result}, [:not_a_cap | :tail])

    assert {:ok, improper} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert improper["status"] == "invalid"

    # Map grant missing principal_id is invalid.
    Process.put(
      {FakeSecurity, :list_result},
      [%{resource_uri: "arbor://fs/write", constraints: %{}}]
    )

    assert {:ok, missing_principal} =
             TemplateAuthorityPreview.project_with_deps("agent_preview1", [], deps())

    assert missing_principal["status"] == "invalid"
  end
end
