defmodule Arbor.AI.AgentSDK.HooksTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Hooks

  @context %{session_id: "test-123", cwd: "/tmp", model: "opus"}

  describe "run_pre_hooks/4" do
    test "returns allow with original input when no hooks" do
      assert {:allow, %{cmd: "ls"}} =
               Hooks.run_pre_hooks(%{}, "Bash", %{cmd: "ls"}, @context)
    end

    test "single hook returning :allow" do
      hooks = %{pre_tool_use: fn _name, _input, _ctx -> :allow end}

      assert {:allow, %{cmd: "ls"}} =
               Hooks.run_pre_hooks(hooks, "Bash", %{cmd: "ls"}, @context)
    end

    test "single hook returning :deny" do
      hooks = %{pre_tool_use: fn _name, _input, _ctx -> :deny end}

      assert {:deny, "Tool call denied by hook"} =
               Hooks.run_pre_hooks(hooks, "Bash", %{cmd: "rm -rf"}, @context)
    end

    test "single hook returning {:deny, reason}" do
      hooks = %{
        pre_tool_use: fn _name, _input, _ctx -> {:deny, "dangerous command"} end
      }

      assert {:deny, "dangerous command"} =
               Hooks.run_pre_hooks(hooks, "Bash", %{cmd: "rm -rf"}, @context)
    end

    test "single hook returning {:modify, new_input}" do
      hooks = %{
        pre_tool_use: fn _name, input, _ctx ->
          {:modify, Map.put(input, :sanitized, true)}
        end
      }

      assert {:allow, %{cmd: "ls", sanitized: true}} =
               Hooks.run_pre_hooks(hooks, "Bash", %{cmd: "ls"}, @context)
    end

    test "hook chain - all allow" do
      hooks = %{
        pre_tool_use: [
          fn _name, _input, _ctx -> :allow end,
          fn _name, _input, _ctx -> :allow end
        ]
      }

      assert {:allow, %{}} = Hooks.run_pre_hooks(hooks, "Read", %{}, @context)
    end

    test "hook chain - first denies, second not called" do
      hooks = %{
        pre_tool_use: [
          fn _name, _input, _ctx -> {:deny, "blocked"} end,
          fn _name, _input, _ctx -> raise "should not be called" end
        ]
      }

      assert {:deny, "blocked"} = Hooks.run_pre_hooks(hooks, "Bash", %{}, @context)
    end

    test "hook chain - modify passes to next hook" do
      hooks = %{
        pre_tool_use: [
          fn _name, input, _ctx -> {:modify, Map.put(input, :step1, true)} end,
          fn _name, input, _ctx ->
            assert input.step1 == true
            {:modify, Map.put(input, :step2, true)}
          end
        ]
      }

      assert {:allow, %{step1: true, step2: true}} =
               Hooks.run_pre_hooks(hooks, "Read", %{}, @context)
    end

    test "hook receives tool name and context" do
      test_pid = self()

      hooks = %{
        pre_tool_use: fn name, input, ctx ->
          send(test_pid, {:hook_called, name, input, ctx})
          :allow
        end
      }

      Hooks.run_pre_hooks(hooks, "Bash", %{cmd: "ls"}, @context)

      assert_received {:hook_called, "Bash", %{cmd: "ls"},
                       %{session_id: "test-123", cwd: "/tmp", model: "opus"}}
    end
  end

  describe "run_post_hooks/5" do
    test "no-op when no hooks" do
      assert :ok = Hooks.run_post_hooks(%{}, "Bash", %{}, "result", @context)
    end

    test "single hook called with all args" do
      test_pid = self()

      hooks = %{
        post_tool_use: fn name, input, result, ctx ->
          send(test_pid, {:post_hook, name, input, result, ctx})
        end
      }

      Hooks.run_post_hooks(hooks, "Read", %{path: "/foo"}, "contents", @context)

      assert_received {:post_hook, "Read", %{path: "/foo"}, "contents", @context}
    end

    test "multiple post hooks all called" do
      test_pid = self()

      hooks = %{
        post_tool_use: [
          fn _n, _i, _r, _c -> send(test_pid, :hook1) end,
          fn _n, _i, _r, _c -> send(test_pid, :hook2) end
        ]
      }

      Hooks.run_post_hooks(hooks, "Read", %{}, "result", @context)

      assert_received :hook1
      assert_received :hook2
    end
  end

  describe "run_message_hooks/3" do
    test "no-op when no hooks" do
      assert :ok = Hooks.run_message_hooks(%{}, %{"type" => "assistant"}, @context)
    end

    test "single hook called" do
      test_pid = self()

      hooks = %{
        on_message: fn msg, ctx ->
          send(test_pid, {:message, msg, ctx})
        end
      }

      Hooks.run_message_hooks(hooks, %{"type" => "result"}, @context)

      assert_received {:message, %{"type" => "result"}, @context}
    end

    test "multiple hooks all called" do
      test_pid = self()

      hooks = %{
        on_message: [
          fn _msg, _ctx -> send(test_pid, :msg_hook1) end,
          fn _msg, _ctx -> send(test_pid, :msg_hook2) end
        ]
      }

      Hooks.run_message_hooks(hooks, %{}, @context)

      assert_received :msg_hook1
      assert_received :msg_hook2
    end
  end

  describe "build_context/1" do
    test "builds context from opts" do
      ctx = Hooks.build_context(session_id: "abc", cwd: "/home", model: :opus)
      assert ctx.session_id == "abc"
      assert ctx.cwd == "/home"
      assert ctx.model == "opus"
    end

    test "defaults to cwd when not provided" do
      ctx = Hooks.build_context([])
      assert ctx.cwd == File.cwd!()
      assert ctx.session_id == nil
      assert ctx.model == nil
    end
  end
end
