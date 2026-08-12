defmodule Arbor.Agent.RuntimeAdmission.OptsTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.RuntimeAdmission.Opts
  alias Arbor.Contracts.TenantContext

  @moduletag :fast

  test "empty opts omit runtime; explicit :arbor is distinct" do
    assert {:ok, omitted} = Opts.project([])
    assert {:ok, explicit} = Opts.project(runtime: :arbor)

    refute Map.has_key?(omitted.projection, "runtime")
    refute Keyword.has_key?(omitted.keyword, :runtime)
    assert explicit.projection["runtime"] == "arbor"
    assert explicit.keyword[:runtime] == :arbor
    refute omitted.fingerprint == explicit.fingerprint
    assert omitted.projection["start_session"] == true
  end

  test "boolean flags reject non-booleans" do
    assert {:error, :invalid_start_opts} = Opts.project(start_session: "yes")
    assert {:error, :invalid_start_opts} = Opts.project(start_heartbeat: 1)
    assert {:error, :invalid_start_opts} = Opts.project(recover_session: nil)
  end

  test "Manager create-only passthrough keys are stripped, not rejected" do
    assert {:ok, r} =
             Opts.project(
               template: "scout",
               capabilities: [%{resource: "x"}],
               display_name: "X",
               model: "m",
               model_config: %{module: SomeMod, backend: :foo, model: "m", provider: :openrouter}
             )

    assert r.keyword[:model] == "m"
    refute Map.has_key?(r.projection["model_config"] || %{}, "module")
    refute Map.has_key?(r.projection["model_config"] || %{}, "backend")
  end

  test "provider reconstruction never creates atoms; keeps accepted form" do
    # Pre-existing atoms stay atoms; unknown provider strings remain binaries.
    assert {:ok, known} = Opts.project(provider: :openrouter)
    assert is_atom(known.keyword[:provider]) or is_binary(known.keyword[:provider])

    weird = "definitely_not_a_provider_atom_xyz_#{System.unique_integer([:positive])}"
    assert {:ok, unknown} = Opts.project(provider: weird)
    assert unknown.keyword[:provider] == weird
  end

  test "same principal different workspace fingerprints conflict" do
    t1 = TenantContext.new("human_a", workspace_root: "/tmp/ws_a")
    t2 = TenantContext.new("human_a", workspace_root: "/tmp/ws_b")

    assert {:ok, a} = Opts.project(tenant_context: t1)
    assert {:ok, b} = Opts.project(tenant_context: t2)
    refute a.fingerprint == b.fingerprint
  end

  test "principal-only equality is insufficient when effective workspace differs" do
    t1 = TenantContext.new("human_a", workspace_root: nil)
    t2 = TenantContext.new("human_a", workspace_root: "/explicit/other")

    assert {:ok, a} = Opts.project(tenant_context: t1)
    assert {:ok, b} = Opts.project(tenant_context: t2)
    refute a.fingerprint == b.fingerprint
    assert is_binary(a.projection["tenant_context"]["effective_workspace_root"])
  end

  test "rejects signer/runner and unknown keys; strips create-only" do
    assert {:error, :invalid_start_opts} = Opts.project(signer: fn _ -> :ok end)
    assert {:error, :invalid_start_opts} = Opts.project(runner: Foo)
    assert {:error, :invalid_start_opts} = Opts.project(unknown_key: true)
    # create-only is stripped (Manager forward), not rejected
    assert {:ok, _} = Opts.project(template: "scout", capabilities: [])
  end

  test "rejects non-empty tenant metadata and atom tools" do
    t = TenantContext.new("human_a", metadata: %{oidc: true})
    assert {:error, :invalid_start_opts} = Opts.project(tenant_context: t)
    assert {:error, :invalid_start_opts} = Opts.project(tools: [String])
  end

  test "preserves tools, runtime, fallback, sampling, recover_session" do
    assert {:ok, r} =
             Opts.project(
               tools: ["shell"],
               runtime: :acp,
               fallback_chain: [%{provider: "ollama", model: "kimi"}],
               temperature: 0.2,
               top_p: 0.9,
               recover_session: false,
               context_management: :none
             )

    assert r.projection["tools"] == ["shell"]
    assert r.projection["runtime"] == "acp"
    assert r.projection["recover_session"] == false
    assert r.projection["context_management"] == "none"
    assert r.keyword[:runtime] == :acp
  end

  test "strips model_config module/backend without rejecting" do
    assert {:ok, r} =
             Opts.project(
               model_config: %{
                 module: SomeMod,
                 backend: :persisted,
                 model: "m",
                 provider: :openrouter
               }
             )

    refute Map.has_key?(r.projection["model_config"] || %{}, "module")
    refute Map.has_key?(r.projection["model_config"] || %{}, "backend")
    assert r.projection["model"] == "m" or r.keyword[:model_config][:model] == "m"
  end

  test "rejects non-empty user_media" do
    assert {:error, :invalid_start_opts} = Opts.project(user_media: [%{x: 1}])
  end

  test "security regression: tenant metadata must be exact empty map, not coerced" do
    # Non-map metadata must not be silently replaced with %{}.
    assert {:error, :invalid_start_opts} =
             Opts.project(
               tenant_context: %{
                 principal_id: "human_a",
                 metadata: "not-a-map"
               }
             )

    assert {:error, :invalid_start_opts} =
             Opts.project(
               tenant_context: %{
                 principal_id: "human_a",
                 metadata: [:list]
               }
             )

    assert {:error, :invalid_start_opts} =
             Opts.project(
               tenant_context: %{
                 principal_id: "human_a",
                 metadata: %{claim: true}
               }
             )

    # Exact empty map is ok.
    assert {:ok, _} =
             Opts.project(
               tenant_context: %{
                 principal_id: "human_a",
                 metadata: %{}
               }
             )
  end

  test "security regression: atom/string key duplicates fail closed (no last-wins)" do
    assert {:error, :invalid_start_opts} =
             Opts.project(
               model_config: %{
                 model: "from_atom",
                 "model" => "from_string",
                 provider: :openrouter
               }
             )

    assert {:error, :invalid_start_opts} =
             Opts.project(
               fallback_chain: [
                 %{provider: "ollama", "provider" => "other", model: "kimi"}
               ]
             )

    assert {:error, :invalid_start_opts} =
             Opts.project(
               provider_options: %{
                 temperature: 0.1,
                 "temperature" => 0.9
               }
             )

    assert {:error, :invalid_start_opts} =
             Opts.project(
               tenant_context: %{
                 principal_id: "human_a",
                 "principal_id" => "human_b"
               }
             )
  end

  test "security regression: unsupported map key types reject without crash" do
    # Tuple / integer / pid keys must not raise via to_string/1.
    assert {:error, :invalid_start_opts} =
             Opts.project(model_config: %{{:nested, :key} => "x", model: "m"})

    assert {:error, :invalid_start_opts} =
             Opts.project(provider_options: %{1 => "bad"})

    assert {:error, :invalid_start_opts} =
             Opts.project(fallback_chain: [%{self() => "x", model: "m", provider: "p"}])
  end

  test "provider_options projects to string-keyed map compatible with SessionConfig" do
    assert {:ok, r} =
             Opts.project(
               provider_options: %{
                 foo: "bar",
                 "nested" => %{flag: true}
               }
             )

    po = r.projection["provider_options"]
    assert po["foo"] == "bar"
    assert po["nested"]["flag"] == true
    # Keyword form retains string keys for SessionConfig passthrough.
    assert r.keyword[:provider_options]["foo"] == "bar"
  end
end
