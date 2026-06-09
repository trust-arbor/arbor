defmodule Arbor.AI.AcpSession.HandlerAuthzFailClosedTest do
  @moduledoc """
  Security regression: the ACP session handler's authorization helpers must FAIL
  CLOSED when the underlying security check raises or exits. Before the
  2026-06-09 fix:

    - `authorize_file/3` rescued/caught to `:ok` (file op auto-authorized)
    - `check_security_authorize/4` rescued/caught to `:authorized` (action
      auto-granted)

  so any exception — or a Security GenServer timeout (`:exit`) — silently
  granted access. These tests force the injected security module to raise/exit
  and assert denial; they fail on `git checkout HEAD~1` of the fix.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.AcpSession.Handler

  defmodule RaisingFileGuard do
    @moduledoc false
    def authorize(_agent_id, _path, _op), do: raise("boom in file guard")
  end

  defmodule ExitingFileGuard do
    @moduledoc false
    def authorize(_agent_id, _path, _op), do: exit(:timeout)
  end

  defmodule RaisingSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: raise("boom in security")
  end

  defmodule ExitingSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: exit(:timeout)
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:arbor_ai, :file_guard_module)
      Application.delete_env(:arbor_ai, :security_module)
    end)

    :ok
  end

  describe "authorize_file/3 fails closed" do
    test "denies (error) when FileGuard raises" do
      Application.put_env(:arbor_ai, :file_guard_module, RaisingFileGuard)
      assert {:error, _reason} = Handler.authorize_file("agent_x", "/ws/secret", :write)
    end

    test "denies (error) when FileGuard exits" do
      Application.put_env(:arbor_ai, :file_guard_module, ExitingFileGuard)
      assert {:error, _reason} = Handler.authorize_file("agent_x", "/ws/secret", :write)
    end
  end

  describe "check_security_authorize/4 fails closed" do
    test "denies when Security.authorize raises" do
      Application.put_env(:arbor_ai, :security_module, RaisingSecurity)

      assert {:denied, _reason} =
               Handler.check_security_authorize("agent_x", "arbor://shell/exec/rm", :execute, %{})
    end

    test "denies when Security.authorize exits" do
      Application.put_env(:arbor_ai, :security_module, ExitingSecurity)

      assert {:denied, _reason} =
               Handler.check_security_authorize("agent_x", "arbor://shell/exec/rm", :execute, %{})
    end
  end
end
