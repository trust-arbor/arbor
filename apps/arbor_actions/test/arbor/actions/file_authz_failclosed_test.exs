defmodule Arbor.Actions.FileAuthzFailClosedTest do
  @moduledoc """
  Security regression: `Arbor.Actions.File.authorize_file_op/3` must FAIL CLOSED
  on any authorization result it doesn't explicitly recognize. Before the
  2026-06-09 fix, its catch-all clause was `_ -> {:ok, path}`, which swallowed
  `{:ok, :pending_approval, _}` (an op that needs human approval and is NOT yet
  authorized) — and any other unexpected shape — into an ALLOW. That is an
  approval bypass.

  These tests inject a security module that returns the pending-approval and
  unexpected shapes and assert denial; they fail on `git checkout HEAD~1` of the
  fix (where the catch-all returns `{:ok, path}`).
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.File, as: FileActions

  defmodule PendingSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: {:ok, :pending_approval, "proposal_1"}
  end

  defmodule WeirdSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: :totally_unexpected
  end

  defmodule AllowSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: {:ok, :authorized}
  end

  defmodule CaptureSecurity do
    @moduledoc false

    def authorize(_agent, _uri, _action, opts) do
      send(self(), {:file_authorization_opts, opts})
      {:ok, :authorized}
    end
  end

  defmodule DescriptorReadSecurity do
    @moduledoc false

    def authorize(_agent, _uri, _action, _opts) do
      send(self(), :legacy_check_then_read_called)
      {:ok, :authorized}
    end

    def read_authorized_file(agent, path, opts) do
      send(self(), {:descriptor_read_called, agent, path, opts})
      {:error, :path_changed}
    end
  end

  defmodule SuccessfulDescriptorReadSecurity do
    @moduledoc false

    def authorize(_agent, _uri, _action, _opts) do
      send(self(), :legacy_check_then_read_called)
      {:ok, :authorized}
    end

    def read_authorized_file(agent, path, opts) do
      send(self(), {:descriptor_read_called, agent, path, opts})
      {:ok, "alias-safe", path}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:arbor_actions, :security_module) end)
    :ok
  end

  @ctx %{agent_id: "agent_x"}

  test "denies a pending_approval result instead of allowing it" do
    Application.put_env(:arbor_actions, :security_module, PendingSecurity)

    assert {:error, {:unauthorized, {:requires_approval, "proposal_1"}}} =
             FileActions.authorize_file_op(@ctx, "/ws/secret", :write)
  end

  test "fails closed on an unexpected authorization result" do
    Application.put_env(:arbor_actions, :security_module, WeirdSecurity)

    assert {:error, {:unauthorized, {:unexpected_authz_result, :totally_unexpected}}} =
             FileActions.authorize_file_op(@ctx, "/ws/secret", :write)
  end

  test "still allows a genuinely authorized op (no regression on the happy path)" do
    Application.put_env(:arbor_actions, :security_module, AllowSecurity)
    assert {:ok, "/ws/secret"} = FileActions.authorize_file_op(@ctx, "/ws/secret", :write)
  end

  @tag :security_regression
  @tag spec: "SSEC-015"
  test "security regression: facade authorization preserves capability scope bindings" do
    Application.put_env(:arbor_actions, :security_module, CaptureSecurity)

    context =
      Map.merge(@ctx, %{
        session_id: "session_file_scope",
        task_id: "task_file_scope",
        principal_scope: "principal_file_scope"
      })

    assert {:ok, "/ws/secret"} =
             FileActions.authorize_file_op(context, "/ws/secret", :read)

    assert_receive {:file_authorization_opts, opts}
    assert opts[:file_path] == "/ws/secret"
    assert opts[:verify_identity] == false
    assert opts[:session_id] == "session_file_scope"
    assert opts[:task_id] == "task_file_scope"
    assert opts[:principal_scope] == "principal_file_scope"
  end

  @tag :security_regression
  @tag spec: "KSEC-012,SSEC-015"
  test "security regression: public file read uses the descriptor-bound security facade" do
    Application.put_env(:arbor_actions, :security_module, DescriptorReadSecurity)

    path =
      Path.join(
        System.tmp_dir!(),
        "descriptor-read-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "must-not-be-read-after-a-path-only-check")
    on_exit(fn -> File.rm(path) end)

    context = %{
      agent_id: "agent_descriptor_read",
      session_id: "session_descriptor_read",
      task_id: "task_descriptor_read"
    }

    assert {:error, message} =
             Arbor.Actions.File.Read.run(%{path: path}, context)

    assert message =~ "path_changed"

    assert_receive {:descriptor_read_called, "agent_descriptor_read", ^path, opts}
    assert opts[:session_id] == "session_descriptor_read"
    assert opts[:task_id] == "task_descriptor_read"
    refute_received :legacy_check_then_read_called
  end

  @tag :security_regression
  @tag spec: "SSEC-015"
  test "security regression: workspace aliases preserve the authorization path spelling" do
    Application.put_env(
      :arbor_actions,
      :security_module,
      SuccessfulDescriptorReadSecurity
    )

    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    fixture_root = Path.join(System.tmp_dir!(), "file-read-alias-#{token}")
    real_workspace = Path.join(fixture_root, "real-workspace")
    lexical_workspace = Path.join(fixture_root, "workspace-alias")
    File.mkdir_p!(real_workspace)
    File.write!(Path.join(real_workspace, "inside.txt"), "inside")
    File.ln_s!(real_workspace, lexical_workspace)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    context = %{
      agent_id: "agent_alias_read",
      workspace: lexical_workspace
    }

    assert {:ok, %{content: "alias-safe"}} =
             Arbor.Actions.File.Read.run(%{path: "inside.txt"}, context)

    expected_path = Path.join(lexical_workspace, "inside.txt")

    assert_receive {:descriptor_read_called, "agent_alias_read", ^expected_path, _opts}
    refute_received :legacy_check_then_read_called
  end

  test "system-level calls (no agent_id) still pass through" do
    assert {:ok, "/ws/secret"} = FileActions.authorize_file_op(%{}, "/ws/secret", :read)
  end
end
