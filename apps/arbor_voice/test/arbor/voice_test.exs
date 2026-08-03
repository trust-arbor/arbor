defmodule Arbor.VoiceTest do
  @moduledoc """
  Facade/application proofs for the tuple-only voice lifecycle API (VP-04D2B).
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Voice
  alias Arbor.Voice.Test.FakeBackend

  alias Arbor.Voice.Test.SessionFakes.{
    FakeCommsSession,
    FakeEngagementStore,
    FakeLedger,
    FakeSignals,
    IncompleteSpeakableDouble,
    ValidSpeakableDouble
  }

  # Consult-only agent for empty-catalog sessions (VP-05C): send_message only.
  defmodule ConsultOnlyAgent do
    @moduledoc false
    def send_message(_c, _t, _m, _o \\ []), do: {:ok, "ok"}
  end

  defp unique_ids do
    n = System.unique_integer([:positive])
    {"user_#{n}", "agent_#{n}"}
  end

  defp base_opts(extra \\ []) do
    {:ok, _eng} = FakeEngagementStore.start()
    {:ok, ledger} = FakeLedger.start()
    {:ok, _signals} = FakeSignals.start()

    [
      comms: FakeCommsSession,
      engagement_store: FakeEngagementStore,
      ledger: FakeLedger,
      ledger_opts: [],
      backend: FakeBackend,
      backend_opts: [],
      signals: FakeSignals,
      session_budget_ms: 60_000,
      daily_budget_ms: 3_600_000,
      wall_clock: fn -> ~U[2026-08-02 12:00:00.000000Z] end,
      monotonic_clock: fn -> 1_000_000 end
    ]
    |> Keyword.merge(extra)
    |> then(fn opts -> {opts, ledger} end)
  end

  setup do
    assert is_pid(Process.whereis(Arbor.Voice.SessionSupervisor))
    :ok
  end

  describe "application supervision" do
    @tag spec: "VOICE-7"
    test "SessionSupervisor is present under the app supervisor" do
      children = Supervisor.which_children(Arbor.Voice.Supervisor)

      entry =
        Enum.find(children, fn {id, _, _, _} -> id == Arbor.Voice.SessionSupervisor end)

      assert {Arbor.Voice.SessionSupervisor, pid, :supervisor, [DynamicSupervisor]} = entry
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    @tag spec: "VOICE-13"
    test "SpeechOutputTaskSupervisor is present under the app supervisor" do
      children = Supervisor.which_children(Arbor.Voice.Supervisor)

      entry =
        Enum.find(children, fn {id, _, _, _} ->
          id == Arbor.Voice.SpeechOutputTaskSupervisor
        end)

      assert {Arbor.Voice.SpeechOutputTaskSupervisor, pid, :supervisor, [Task.Supervisor]} =
               entry

      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "speech_output_timeout_ms config" do
    @tag spec: "VOICE-13"
    test "malformed Application config fails closed without leaking global env" do
      previous = Application.fetch_env(:arbor_voice, :speech_output_timeout_ms)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_voice, :speech_output_timeout_ms, value)
          :error -> Application.delete_env(:arbor_voice, :speech_output_timeout_ms)
        end
      end)

      Application.put_env(:arbor_voice, :speech_output_timeout_ms, 0)
      assert {:error, :invalid_config} = Arbor.Voice.Config.speech_output_timeout_ms()

      Application.put_env(:arbor_voice, :speech_output_timeout_ms, 251)
      assert {:error, :invalid_config} = Arbor.Voice.Config.speech_output_timeout_ms()

      Application.put_env(:arbor_voice, :speech_output_timeout_ms, "100")
      assert {:error, :invalid_config} = Arbor.Voice.Config.speech_output_timeout_ms()

      Application.put_env(:arbor_voice, :speech_output_timeout_ms, 50)
      assert {:ok, 50} = Arbor.Voice.Config.speech_output_timeout_ms()

      # Explicit session opt maps pure-validator failure to :invalid_opts.
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :speech_output_timeout_ms, 0)
               )

      # Malformed Application config surfaces as :invalid_config on start when
      # the per-session option is omitted.
      Application.put_env(:arbor_voice, :speech_output_timeout_ms, 999)

      assert {:error, :invalid_config} =
               Voice.start_session(user_id, agent_id, opts)
    end
  end

  describe "tool_router opts (VP-04E3)" do
    @tag spec: "VOICE-8"
    test "invalid tool_router module and timeout map to :invalid_opts" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      assert {:error, :invalid_opts} =
               Voice.start_session(user_id, agent_id, Keyword.put(opts, :tool_router, 123))

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :tool_router, String)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :tool_router_timeout_ms, 0)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :tool_router_timeout_ms, 30_001)
               )
    end

    @tag spec: "VOICE-8"
    test "malformed Application tool_router_timeout_ms fails as :invalid_config" do
      previous = Application.fetch_env(:arbor_voice, :tool_router_timeout_ms)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_voice, :tool_router_timeout_ms, value)
          :error -> Application.delete_env(:arbor_voice, :tool_router_timeout_ms)
        end
      end)

      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()
      Application.put_env(:arbor_voice, :tool_router_timeout_ms, 0)

      assert {:error, :invalid_config} =
               Voice.start_session(user_id, agent_id, opts)
    end
  end

  defmodule BadToolsRaise do
    @moduledoc false
    def tools, do: raise("tools boom")
    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsThrow do
    @moduledoc false
    def tools, do: throw(:tools_throw)
    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsExit do
    @moduledoc false
    def tools, do: exit(:tools_exit)
    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsDup do
    @moduledoc false
    def tools do
      decl = %{
        "type" => "function",
        "name" => "a",
        "description" => "desc",
        "parameters" => %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      }

      [decl, decl]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsNameOnly do
    @moduledoc false
    def tools, do: [%{"name" => "only_name"}]
    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsOversized do
    @moduledoc false
    def tools do
      # More than max_tool_declarations (8)
      for i <- 1..10 do
        %{
          "type" => "function",
          "name" => "tool_#{i}",
          "description" => "desc #{i}",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => [],
            "additionalProperties" => false
          }
        }
      end
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsNonJson do
    @moduledoc false
    def tools do
      # Valid function shape but non-JSON term (PID) inside properties schema.
      [
        %{
          "type" => "function",
          "name" => "bad",
          "description" => "has non-JSON term",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "string", "default" => self()}},
            "required" => [],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsNotList do
    @moduledoc false
    def tools, do: %{not: "a list"}
    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsAdditionalPropertiesAbsent do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => []
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsAdditionalPropertiesTrue do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => [],
            "additionalProperties" => true
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsEmptyPropertySchema do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"message" => %{}},
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsBogusPropertyType do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"message" => %{"type" => "bogus"}},
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsUnknownPropertyKey do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "message" => %{"type" => "string", "pattern" => ".*"}
            },
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsInvertedLengthBounds do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "message" => %{"type" => "string", "minLength" => 10, "maxLength" => 1}
            },
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsNullPropertyDescription do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"message" => %{"type" => "string", "description" => nil}},
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsNullMinLength do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"message" => %{"type" => "string", "minLength" => nil}},
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsNullMaxLength do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"message" => %{"type" => "string", "maxLength" => nil}},
            "required" => ["message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  defmodule BadToolsDuplicateRequired do
    @moduledoc false
    def tools do
      [
        %{
          "type" => "function",
          "name" => "a",
          "description" => "desc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"message" => %{"type" => "string"}},
            "required" => ["message", "message"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def invoke(_, _), do: {:error, :no_tools_installed}
  end

  describe "session_token and progress opts (VP-05B)" do
    @tag spec: "VOICE-9"
    test "malformed session_token fails as :invalid_opts before resource effects" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      for bad <- [nil, "", 123, :atom, String.duplicate("x", 4097)] do
        assert {:error, :invalid_opts} =
                 Voice.start_session(user_id, agent_id, Keyword.put(opts, :session_token, bad))
      end

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 opts ++ [session_token: "a", session_token: "b"]
               )
    end

    @tag spec: "VOICE-9"
    test "malformed agent_module Application config fails as :invalid_config" do
      previous = Application.fetch_env(:arbor_voice, :agent_module)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_voice, :agent_module, value)
          :error -> Application.delete_env(:arbor_voice, :agent_module)
        end
      end)

      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()
      Application.put_env(:arbor_voice, :agent_module, String)

      assert {:error, :invalid_config} =
               Voice.start_session(user_id, agent_id, opts)
    end

    @tag spec: "VOICE-11"
    test "progress_threshold_ms validation and tool-timeout ceiling" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :progress_threshold_ms, 0)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :progress_threshold_ms, 30_001)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 opts
                 |> Keyword.put(:tool_router_timeout_ms, 1_000)
                 |> Keyword.put(:progress_threshold_ms, 2_000)
               )
    end

    @tag spec: "VOICE-9"
    test "explicit router declaration failures are :invalid_opts" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      for router <- [
            BadToolsRaise,
            BadToolsThrow,
            BadToolsExit,
            BadToolsDup,
            BadToolsNameOnly,
            BadToolsOversized,
            BadToolsNonJson,
            BadToolsNotList,
            BadToolsAdditionalPropertiesAbsent,
            BadToolsAdditionalPropertiesTrue,
            BadToolsEmptyPropertySchema,
            BadToolsBogusPropertyType,
            BadToolsUnknownPropertyKey,
            BadToolsInvertedLengthBounds,
            BadToolsNullPropertyDescription,
            BadToolsNullMinLength,
            BadToolsNullMaxLength,
            BadToolsDuplicateRequired
          ] do
        assert {:error, :invalid_opts} =
                 Voice.start_session(user_id, agent_id, Keyword.put(opts, :tool_router, router)),
               "expected :invalid_opts for #{inspect(router)}"
      end
    end

    @tag spec: "VOICE-9"
    test "Application progress_threshold_ms malformed is :invalid_config" do
      previous = Application.fetch_env(:arbor_voice, :progress_threshold_ms)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_voice, :progress_threshold_ms, value)
          :error -> Application.delete_env(:arbor_voice, :progress_threshold_ms)
        end
      end)

      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()
      # Omit explicit progress so Application path is used.
      opts = Keyword.delete(opts, :progress_threshold_ms)
      Application.put_env(:arbor_voice, :progress_threshold_ms, 0)

      assert {:error, :invalid_config} =
               Voice.start_session(user_id, agent_id, opts)
    end

    @tag spec: "VOICE-9"
    test "valid session_token starts and stays out of public status and retained state" do
      {user_id, agent_id} = unique_ids()
      token = "facade-proof-token-abc"
      {opts, _} = base_opts(session_token: token)

      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert {:ok, status} = Voice.session_status(key)
      refute inspect(status) =~ token

      [{session_pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
      refute inspect(:sys.get_status(session_pid)) =~ token
      # Proof is closed over inside tool_authority only — not a Session field.
      state = :sys.get_state(session_pid)
      refute Map.has_key?(state, :session_token)
      refute inspect(state) =~ token

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-10"
    test "empty catalog does not require dispatch_task or orchestrator collaborators" do
      previous_agent = Application.fetch_env(:arbor_voice, :agent_module)
      previous_orch = Application.fetch_env(:arbor_voice, :orchestrator_module)

      on_exit(fn ->
        case previous_agent do
          {:ok, value} -> Application.put_env(:arbor_voice, :agent_module, value)
          :error -> Application.delete_env(:arbor_voice, :agent_module)
        end

        case previous_orch do
          {:ok, value} -> Application.put_env(:arbor_voice, :orchestrator_module, value)
          :error -> Application.delete_env(:arbor_voice, :orchestrator_module)
        end
      end)

      Application.put_env(:arbor_voice, :agent_module, ConsultOnlyAgent)
      # Broken orchestrator would fail if resolved — must not be required.
      Application.put_env(:arbor_voice, :orchestrator_module, String)

      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts(tool_router: Arbor.Voice.ToolRouter.EmptyCatalog)

      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert :ok = Voice.stop_session(key)
    end
  end

  describe "start_session/3 API" do
    @tag spec: "VOICE-2"
    test "returns the tuple key, never a pid, and registers uniquely" do
      {user_id, agent_id} = unique_ids()
      {opts, _ledger} = base_opts()

      assert {:ok, {^user_id, ^agent_id} = key} = Voice.start_session(user_id, agent_id, opts)
      refute match?({:ok, pid} when is_pid(pid), {:ok, key})

      assert [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)
      assert is_pid(pid)
      assert Process.alive?(pid)

      assert :ok = Voice.stop_session(key)
    end

    @tag spec: "VOICE-2"
    test "duplicate start returns :already_started" do
      {user_id, agent_id} = unique_ids()
      {opts, _ledger} = base_opts()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert {:error, :already_started} = Voice.start_session(user_id, agent_id, opts)
      assert :ok = Voice.stop_session(key)
    end

    test "rejects blank, non-utf8, oversized, and non-string ids" do
      {opts, _} = base_opts()

      assert {:error, :invalid_user_id} = Voice.start_session("", "agent_1", opts)
      assert {:error, :invalid_user_id} = Voice.start_session("   ", "agent_1", opts)
      assert {:error, :invalid_agent_id} = Voice.start_session("user_1", "", opts)
      assert {:error, :invalid_user_id} = Voice.start_session(nil, "agent_1", opts)
      assert {:error, :invalid_agent_id} = Voice.start_session("user_1", 123, opts)

      huge = String.duplicate("a", 257)
      assert {:error, :invalid_user_id} = Voice.start_session(huge, "agent_1", opts)
      assert {:error, :invalid_agent_id} = Voice.start_session("user_1", huge, opts)

      # invalid UTF-8
      bad = <<0xFF, 0xFE>>
      assert {:error, :invalid_user_id} = Voice.start_session(bad, "agent_1", opts)
    end

    test "rejects unknown and duplicate option keys" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      assert {:error, :invalid_opts} =
               Voice.start_session(user_id, agent_id, opts ++ [bogus: true])

      assert {:error, :invalid_opts} =
               Voice.start_session(user_id, agent_id, opts ++ [backend: FakeBackend])
    end

    test "rejects unknown and duplicate transcript_opts keys" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :transcript_opts, comms: :x)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id,
                 agent_id,
                 Keyword.put(opts, :transcript_opts, persistence: :a, persistence: :b)
               )
    end

    @tag spec: "VOICE-13"
    test "closed speakable/speech_output options: defaults, validation, compiled-unloaded" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      # Default Speakable + nil speech_output accepted.
      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert :ok = Voice.stop_session(key)

      # Explicit production Speakable + nil output.
      {user_id2, agent_id2} = unique_ids()

      assert {:ok, key2} =
               Voice.start_session(
                 user_id2,
                 agent_id2,
                 Keyword.merge(opts, speakable: Arbor.Voice.Speakable, speech_output: nil)
               )

      assert :ok = Voice.stop_session(key2)

      # Explicit valid double + nil output.
      {user_id2b, agent_id2b} = unique_ids()

      assert {:ok, key2b} =
               Voice.start_session(
                 user_id2b,
                 agent_id2b,
                 Keyword.merge(opts, speakable: ValidSpeakableDouble, speech_output: nil)
               )

      assert :ok = Voice.stop_session(key2b)

      # Valid arity-1 speech_output.
      {user_id3, agent_id3} = unique_ids()

      assert {:ok, key3} =
               Voice.start_session(
                 user_id3,
                 agent_id3,
                 Keyword.put(opts, :speech_output, fn _s -> :ok end)
               )

      assert :ok = Voice.stop_session(key3)

      # Compiled-but-unloaded Speakable double still validates via module_info.
      # Purge the test double only — never the production Speakable module.
      speakable = ValidSpeakableDouble
      _ = :code.purge(speakable)
      _ = :code.delete(speakable)
      _ = :code.purge(speakable)
      assert :code.is_loaded(speakable) == false

      {user_id4, agent_id4} = unique_ids()

      assert {:ok, key4} =
               Voice.start_session(
                 user_id4,
                 agent_id4,
                 Keyword.put(opts, :speakable, speakable)
               )

      assert match?({:file, _path}, :code.is_loaded(speakable))
      assert :ok = Voice.stop_session(key4)

      # Missing callback(s).
      {user_id5, agent_id5} = unique_ids()

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id5,
                 agent_id5,
                 Keyword.put(opts, :speakable, IncompleteSpeakableDouble)
               )

      # nil / non-module speakable.
      assert {:error, :invalid_opts} =
               Voice.start_session(user_id5, agent_id5, Keyword.put(opts, :speakable, nil))

      assert {:error, :invalid_opts} =
               Voice.start_session(user_id5, agent_id5, Keyword.put(opts, :speakable, "nope"))

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id5,
                 agent_id5,
                 Keyword.put(opts, :speakable, :NonexistentSpeakableModuleXYZ)
               )

      # Invalid speech_output values/arities.
      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id5,
                 agent_id5,
                 Keyword.put(opts, :speech_output, fn -> :ok end)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id5,
                 agent_id5,
                 Keyword.put(opts, :speech_output, fn _a, _b -> :ok end)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id5,
                 agent_id5,
                 Keyword.put(opts, :speech_output, :not_a_fun)
               )

      assert {:error, :invalid_opts} =
               Voice.start_session(
                 user_id5,
                 agent_id5,
                 Keyword.put(opts, :speech_output, "nope")
               )

      # speech_output_timeout_ms: closed positive integer 1..250.
      {user_id6, agent_id6} = unique_ids()

      assert {:ok, key6} =
               Voice.start_session(
                 user_id6,
                 agent_id6,
                 Keyword.put(opts, :speech_output_timeout_ms, 1)
               )

      assert :ok = Voice.stop_session(key6)

      {user_id7, agent_id7} = unique_ids()

      assert {:ok, key7} =
               Voice.start_session(
                 user_id7,
                 agent_id7,
                 Keyword.put(opts, :speech_output_timeout_ms, 250)
               )

      assert :ok = Voice.stop_session(key7)

      for bad <- [0, 251, -1, 1.5, "100", nil] do
        assert {:error, :invalid_opts} =
                 Voice.start_session(
                   user_id5,
                   agent_id5,
                   Keyword.put(opts, :speech_output_timeout_ms, bad)
                 ),
               "bad timeout #{inspect(bad)}"
      end
    end
  end

  describe "text_turn/3 facade" do
    @tag spec: "VOICE-2,VOICE-3,VOICE-5"
    test "exports text_turn/3, validates input, returns raw text, never exposes a pid" do
      # Alias does not load the module; ensure_loaded so function_exported?/3 is order-stable.
      assert Code.ensure_loaded?(Voice)
      assert function_exported?(Voice, :text_turn, 3)
      refute function_exported?(Voice, :text_turn, 2)

      # Validation without a live session.
      assert {:error, :invalid_user_text} = Voice.text_turn("user_1", "agent_1", "")
      assert {:error, :invalid_user_text} = Voice.text_turn("user_1", "agent_1", "   ")
      assert {:error, :invalid_user_text} = Voice.text_turn("user_1", "agent_1", <<0xFF, 0xFE>>)
      assert {:error, :invalid_user_text} = Voice.text_turn("user_1", "agent_1", nil)

      huge = String.duplicate("a", 8193)
      assert {:error, :invalid_user_text} = Voice.text_turn("user_1", "agent_1", huge)

      assert {:error, :not_found} = Voice.text_turn("missing_u", "missing_a", "hello")

      # Successful raw-text return through supervised session (FakeBackend).
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()
      {:ok, _} = Arbor.Voice.Test.SessionFakes.FakeCommsSession.start_recorder()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert {:ok, raw} = Voice.text_turn(user_id, agent_id, "hello facade")
      assert is_binary(raw)
      assert String.trim(raw) != ""
      refute is_pid(raw)
      refute match?({:ok, pid} when is_pid(pid), {:ok, raw})
      assert key == {user_id, agent_id}

      assert :ok = Voice.stop_session(key)
    end
  end

  describe "session_status/1" do
    @tag spec: "VOICE-5"
    test "returns a redacted bounded status map" do
      {user_id, agent_id} = unique_ids()
      {opts, _} = base_opts()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert {:ok, status} = Voice.session_status(key)

      assert status == %{
               state: :ready,
               user_id: user_id,
               agent_id: agent_id,
               backend: :fake,
               mode: :local,
               reserved_ms: 60_000
             }

      # No pids, engagement ids, reservation ids, or raw errors.
      refute Map.has_key?(status, :pid)
      refute Map.has_key?(status, :engagement_id)
      refute Map.has_key?(status, :reservation_id)
      refute Map.has_key?(status, :owner)
      refute Map.has_key?(status, :error)

      encoded = inspect(status)
      refute encoded =~ "pid"
      refute encoded =~ "eng_"

      assert :ok = Voice.stop_session(key)
    end

    test "unknown session returns :not_found" do
      assert {:error, :not_found} = Voice.session_status({"missing_user", "missing_agent"})
    end
  end

  describe "stop_session/1" do
    @tag spec: "VOICE-7,VOICE-22"
    test "normal stop settles, closes, emits stop, and removes registry entry" do
      {user_id, agent_id} = unique_ids()
      {opts, ledger} = base_opts()
      {:ok, signals} = FakeSignals.start()

      assert {:ok, key} = Voice.start_session(user_id, agent_id, opts)
      assert [{pid, _}] = Registry.lookup(Arbor.Voice.Registry, key)

      assert :ok = Voice.stop_session(key)

      # Registry entry gone (allow brief lag)
      wait_until(fn -> Registry.lookup(Arbor.Voice.Registry, key) == [] end, 2_000)
      refute Process.alive?(pid)

      emissions = FakeSignals.emissions(signals)
      assert Enum.any?(emissions, fn {cat, type, _, _} -> cat == :voice and type == :stop end)
      assert Enum.any?(emissions, fn {cat, type, _, _} -> cat == :voice and type == :start end)

      assert Enum.any?(emissions, fn {cat, type, _, _} ->
               cat == :voice and type == :backend_connected
             end)

      # Public Signals shape is emit/4 with a closed opts list.
      assert Enum.all?(emissions, fn {_c, _t, _data, opts} -> is_list(opts) and opts == [] end)

      calls = FakeLedger.calls(ledger)
      assert Enum.any?(calls, fn c -> match?({:consume, _, _, _}, c) end)

      assert {:error, :not_found} = Voice.stop_session(key)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
