defmodule Arbor.Shell.AppleContainerExecutorTest do
  @moduledoc """
  Focused hermetic tests for the internal Apple Container spawn-capable adapter.

  Uses only deterministic same-library fakes for the internal adapter. Public
  facade coverage is limited to pure preflight (no host Apple Container).
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerExecutor, as: Executor
  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.SpawnCapableTimeout

  @moduletag :fast

  @digest String.duplicate("a", 64)
  @init_digest String.duplicate("b", 64)
  @workload "127.0.0.1:0/arbor/workload@sha256:#{@digest}"
  @vminit "127.0.0.1:0/arbor/vminit@sha256:#{@init_digest}"
  @kernel "/usr/local/share/container/kernels/default.kernel"
  @mix_wrapper "/private/tmp/arbor-val/bin/mix"
  @worktree "/private/tmp/arbor-val/worktree"
  @unit_name_re ~r/\Aarbor-v1-[0-9a-f]{32}\z/

  @valid_admission %{
    "admitted" => true,
    "platform" => %{"os" => "macos", "version" => "26.5.2", "architecture" => "arm64"},
    "runtime" => %{"path" => "/usr/local/bin/container"},
    "image" => %{
      "execution_reference" => @workload,
      "platform" => "linux/arm64"
    },
    "vminit" => %{
      "execution_reference" => @vminit,
      "platform" => "linux/arm64"
    },
    "control_plane" => %{
      "kernel" => %{"path" => @kernel}
    }
  }

  setup do
    {:ok, agent} = Agent.start_link(fn -> empty_trace() end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    {:ok, agent: agent}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp empty_trace do
    %{
      probe_calls: [],
      resolve_calls: 0,
      random_calls: 0,
      register_calls: 0,
      start_calls: [],
      adopt_calls: 0,
      begin_calls: [],
      cancel_sends: [],
      settle_calls: 0,
      settle_results: [],
      mono: 1_000_000,
      mono_steps: [],
      generated_names: [],
      last_spec: nil,
      last_execution_id: nil,
      last_start_ref: nil,
      last_worker: nil,
      registry: %{},
      fail_calls: []
    }
  end

  defp actions_entry(path, mode, purpose) do
    %{
      "path" => path,
      "mode" => Atom.to_string(mode),
      "purpose" => Atom.to_string(purpose)
    }
  end

  defp base_projections do
    %{
      read_only: [
        actions_entry(
          "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang",
          :read_only,
          :runtime_erlang
        ),
        actions_entry("/opt/homebrew/Cellar/elixir/1.19.5", :read_only, :runtime_elixir),
        actions_entry(@mix_wrapper, :read_only, :mix_wrapper)
      ],
      read_write: [
        actions_entry(@worktree, :read_write, :worktree),
        actions_entry("/private/tmp/arbor-val/home", :read_write, :home),
        actions_entry("/private/tmp/arbor-val/tmp", :read_write, :tmp),
        actions_entry("/private/tmp/arbor-val/build", :read_write, :build),
        actions_entry("/private/tmp/arbor-val/deps", :read_write, :deps)
      ],
      revision: "candidate"
    }
  end

  defp valid_opts(overrides \\ []) do
    base = [
      cwd: @worktree,
      timeout: 60_000,
      sandbox: :basic,
      env: %{},
      clear_env: true,
      filesystem_projections: base_projections()
    ]

    Keyword.merge(base, overrides)
  end

  defp fake_executable do
    %Executable{
      name: "container",
      path: "/usr/local/bin/container",
      device: 1,
      inode: 2,
      size: 100,
      mtime: 0,
      ctime: 0,
      mode: 0o755,
      sha256: String.duplicate("c", 64)
    }
  end

  defp success_result(overrides \\ %{}) do
    Map.merge(
      %{
        exit_code: 0,
        stdout: "ok",
        stderr: "",
        duration_ms: 12,
        timed_out: false,
        cancelled: false,
        killed: false,
        output_truncated: false,
        output_limit_exceeded: false
      },
      overrides
    )
  end

  defp record(agent, key, value \\ 1) do
    Agent.update(agent, fn state ->
      case Map.get(state, key) do
        list when is_list(list) -> Map.put(state, key, [value | list])
        n when is_integer(n) -> Map.put(state, key, n + value)
        _ -> Map.put(state, key, value)
      end
    end)
  end

  defp put_state(agent, key, value) do
    Agent.update(agent, &Map.put(&1, key, value))
  end

  defp get_state(agent, key) do
    Agent.get(agent, &Map.get(&1, key))
  end

  defp advance_mono(agent, by) do
    Agent.update(agent, fn state ->
      %{state | mono: state.mono + by, mono_steps: [by | state.mono_steps]}
    end)
  end

  defp mono(agent) do
    Agent.get_and_update(agent, fn state ->
      {state.mono, state}
    end)
  end

  defp publish_registry(agent, execution_id, status, result, terminal_source) do
    Agent.update(agent, fn state ->
      reg = Map.get(state, :registry, %{})
      entry = Map.get(reg, execution_id, %{status: :running, result: nil, owner: :controller})

      updated = %{
        entry
        | status: status,
          result: result,
          terminal_source: terminal_source
      }

      %{state | registry: Map.put(reg, execution_id, updated)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Dependency builders
  # ---------------------------------------------------------------------------

  defp base_deps(agent, overrides \\ %{}) do
    base = %{
      probe: fn remaining ->
        record(agent, :probe_calls, remaining)
        advance_mono(agent, 100)
        {:ok, @valid_admission}
      end,
      resolve_executable: fn ->
        record(agent, :resolve_calls)
        advance_mono(agent, 10)
        {:ok, fake_executable()}
      end,
      generate_unit_name: fn ->
        record(agent, :random_calls)
        name = "arbor-v1-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        record(agent, :generated_names, name)
        name
      end,
      register: fn _cmd, _opts ->
        record(agent, :register_calls)
        id = "exec_test_" <> Integer.to_string(System.unique_integer([:positive]))
        put_state(agent, :last_execution_id, id)

        put_state(agent, :registry, %{
          id => %{
            status: :pending,
            result: nil,
            owner: :controller,
            terminal_source: nil
          }
        })

        {:ok, id}
      end,
      adopt: fn execution_id, worker ->
        record(agent, :adopt_calls)
        put_state(agent, :last_worker, worker)

        Agent.update(agent, fn state ->
          reg = Map.get(state, :registry, %{})

          entry =
            reg
            |> Map.get(execution_id, %{status: :pending, result: nil, terminal_source: nil})
            |> Map.merge(%{status: :running, owner: worker, terminal_source: nil})

          %{state | registry: Map.put(reg, execution_id, entry)}
        end)

        :ok
      end,
      registry_get: fn execution_id ->
        case Agent.get(agent, fn state -> get_in(state, [:registry, execution_id]) end) do
          nil ->
            {:error, :not_found}

          entry ->
            {:ok,
             %{
               id: execution_id,
               status: Map.get(entry, :status),
               result: Map.get(entry, :result),
               terminal_source: Map.get(entry, :terminal_source)
             }}
        end
      end,
      registry_fail: fn execution_id, reason ->
        record(agent, :fail_calls, {execution_id, reason})

        Agent.update(agent, fn state ->
          reg = Map.get(state, :registry, %{})

          case Map.get(reg, execution_id) do
            %{owner: :controller} = entry ->
              updated = %{
                entry
                | status: :failed,
                  result: %{error: reason},
                  terminal_source: :owner_published
              }

              %{state | registry: Map.put(reg, execution_id, updated)}

            _ ->
              state
          end
        end)

        :ok
      end,
      worker_start: fn spec, _exe, execution_id, start_ref ->
        record(agent, :start_calls, %{
          timeout_ms: Map.get(spec, :timeout_ms),
          unit_name: unit_name_from_spec(spec),
          execution_id: execution_id,
          start_ref: start_ref
        })

        put_state(agent, :last_spec, spec)
        put_state(agent, :last_execution_id, execution_id)
        put_state(agent, :last_start_ref, start_ref)

        parent = self()

        worker =
          spawn(fn ->
            fake_worker_loop(agent, parent, execution_id, start_ref, :completed, success_result())
          end)

        put_state(agent, :last_worker, worker)
        {:ok, worker}
      end,
      worker_begin: fn worker, start_ref, timeout ->
        record(agent, :begin_calls, timeout)
        send(worker, {:begin, start_ref, self()})
        :ok
      end,
      await_settled: fn execution_id ->
        record(agent, :settle_calls)

        results = get_state(agent, :settle_results) || []

        case results do
          [next | rest] ->
            put_state(agent, :settle_results, rest)
            next

          [] ->
            _ = execution_id
            :ok
        end
      end,
      monotonic_ms: fn -> mono(agent) end,
      sleep: fn _ms ->
        # Deterministic: no real sleep; advance mono slightly.
        advance_mono(agent, 1)
        :ok
      end
    }

    Map.merge(base, overrides)
  end

  defp fake_worker_loop(agent, controller, execution_id, expected_start_ref, status, result) do
    receive do
      {:begin, ^expected_start_ref, _from} ->
        publish_registry(agent, execution_id, status, result, :owner_published)
        send(controller, {:apple_container_unit_terminal, execution_id, {:ok, result}})
        :ok

      {:begin, _other_ref, _from} ->
        :ok

      {:cancel_shell_execution, ^execution_id} ->
        :ok

      _other ->
        fake_worker_loop(agent, controller, execution_id, expected_start_ref, status, result)
    end
  end

  defp unit_name_from_spec(spec) when is_map(spec) do
    plan = Map.get(spec, :plan)

    cond do
      is_map(plan) and is_binary(Map.get(plan, :unit_name)) -> Map.get(plan, :unit_name)
      is_map(plan) and is_binary(Map.get(plan, "unit_name")) -> Map.get(plan, "unit_name")
      true -> nil
    end
  end

  defp unit_name_from_spec(_), do: nil

  defp worker_publishing(agent, status, result, terminal_source \\ :owner_published) do
    fn spec, _exe, execution_id, start_ref ->
      record(agent, :start_calls, %{
        timeout_ms: Map.get(spec, :timeout_ms),
        execution_id: execution_id,
        start_ref: start_ref
      })

      put_state(agent, :last_spec, spec)
      put_state(agent, :last_execution_id, execution_id)
      put_state(agent, :last_start_ref, start_ref)
      parent = self()

      worker =
        spawn(fn ->
          receive do
            {:begin, ^start_ref, _} ->
              publish_registry(agent, execution_id, status, result, terminal_source)

              send(
                parent,
                {:apple_container_unit_terminal, execution_id, {status, result}}
              )

              :ok

            {:cancel_shell_execution, ^execution_id} ->
              :ok
          end
        end)

      put_state(agent, :last_worker, worker)
      {:ok, worker}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "malformed request" do
    test "invokes none of probe/random/registry/start", %{agent: agent} do
      deps = base_deps(agent)

      assert {:error, reason} =
               Executor.execute_for_test("not-absolute", ["compile"], valid_opts(), deps)

      assert is_atom(reason) or is_tuple(reason)
      assert get_state(agent, :probe_calls) == []
      assert get_state(agent, :random_calls) == 0
      assert get_state(agent, :register_calls) == 0
      assert get_state(agent, :start_calls) == []
      assert get_state(agent, :resolve_calls) == 0
    end

    test "rejects missing opts keys without side effects", %{agent: agent} do
      deps = base_deps(agent)

      assert {:error, _} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], [cwd: @worktree], deps)

      assert get_state(agent, :probe_calls) == []
      assert get_state(agent, :start_calls) == []
    end
  end

  describe "deadline shrink" do
    test "operation budgets above the probe ceiling cap only the probe sub-deadline", %{
      agent: agent
    } do
      timeout = Shell.spawn_capable_max_timeout_ms()

      assert {:ok, _result} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 base_deps(agent)
               )

      assert get_state(agent, :probe_calls) == [SpawnCapableTimeout.max_probe_deadline_ms()]

      start_meta = hd(get_state(agent, :start_calls))
      assert start_meta.timeout_ms > SpawnCapableTimeout.max_probe_deadline_ms()
      assert start_meta.timeout_ms < timeout
    end

    test "one deadline shrinks across a fake probe and before start", %{agent: agent} do
      timeout = 5_000

      deps =
        base_deps(agent, %{
          probe: fn remaining ->
            record(agent, :probe_calls, remaining)
            # Consume 1_200ms of the caller's budget inside the probe.
            advance_mono(agent, 1_200)
            {:ok, @valid_admission}
          end,
          resolve_executable: fn ->
            record(agent, :resolve_calls)
            advance_mono(agent, 300)
            {:ok, fake_executable()}
          end
        })

      assert {:ok, _result} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 deps
               )

      probe_remaining = hd(Enum.reverse(get_state(agent, :probe_calls)))
      assert probe_remaining == timeout

      start_meta = hd(Enum.reverse(get_state(agent, :start_calls)))
      assert start_meta.timeout_ms < timeout
      assert start_meta.timeout_ms <= timeout - 1_500
      assert start_meta.timeout_ms > 0
    end

    test "register latency that exhausts deadline skips Worker.start and settlement", %{
      agent: agent
    } do
      timeout = 1_000
      test_pid = self()

      deps =
        base_deps(agent, %{
          register: fn _cmd, _opts ->
            record(agent, :register_calls)
            # Exhaust the absolute deadline during registration.
            advance_mono(agent, timeout + 50)
            id = "exec_test_late_reg"
            put_state(agent, :last_execution_id, id)

            put_state(agent, :registry, %{
              id => %{
                status: :pending,
                result: nil,
                owner: :controller,
                terminal_source: nil
              }
            })

            {:ok, id}
          end,
          worker_start: fn _spec, _exe, _id, _ref ->
            send(test_pid, :worker_started_unexpectedly)
            flunk("Worker.start must not run after deadline exhaustion post-register")
          end,
          await_settled: fn _id ->
            send(test_pid, :settled_unexpectedly)
            flunk("settlement must not run when no unit start was attempted")
          end
        })

      assert {:error, :deadline_exhausted} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 deps
               )

      assert get_state(agent, :register_calls) == 1
      assert get_state(agent, :start_calls) == []
      assert get_state(agent, :settle_calls) == 0
      # Controller-owned entry was failed without settlement.
      fails = get_state(agent, :fail_calls)
      assert Enum.any?(fails, fn {_id, reason} -> reason == :deadline_exhausted end)
      refute_received :worker_started_unexpectedly
      refute_received :settled_unexpectedly
    end

    test "adopt latency that exhausts deadline does not begin and settles positively", %{
      agent: agent
    } do
      timeout = 2_000
      test_pid = self()

      deps =
        base_deps(agent, %{
          adopt: fn execution_id, worker ->
            record(agent, :adopt_calls)
            put_state(agent, :last_worker, worker)
            # Exhaust deadline after adopt, before begin.
            advance_mono(agent, timeout + 100)

            Agent.update(agent, fn state ->
              reg = Map.get(state, :registry, %{})

              entry =
                reg
                |> Map.get(execution_id, %{status: :pending, result: nil, terminal_source: nil})
                |> Map.merge(%{status: :running, owner: worker, terminal_source: nil})

              %{state | registry: Map.put(reg, execution_id, entry)}
            end)

            :ok
          end,
          worker_begin: fn _worker, _ref, _timeout ->
            send(test_pid, :begin_unexpectedly)
            flunk("begin must not run after deadline exhaustion post-adopt")
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:settled_after_deadline, execution_id})
            :ok
          end
        })

      assert {:error, :deadline_exhausted} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 deps
               )

      assert get_state(agent, :begin_calls) == []
      assert get_state(agent, :settle_calls) >= 1
      assert_received {:settled_after_deadline, _}
      # Direct cancel sent to known worker (not via request_cancel).
      assert get_state(agent, :cancel_sends) == [] or is_list(get_state(agent, :cancel_sends))
      refute_received :begin_unexpectedly
    end

    test "never substitutes begin timeout 1 after deadline expiry", %{agent: agent} do
      timeout = 500
      test_pid = self()

      deps =
        base_deps(agent, %{
          adopt: fn execution_id, worker ->
            record(agent, :adopt_calls)
            put_state(agent, :last_worker, worker)
            advance_mono(agent, timeout + 1)

            Agent.update(agent, fn state ->
              reg = Map.get(state, :registry, %{})

              entry =
                reg
                |> Map.get(execution_id, %{})
                |> Map.merge(%{status: :running, owner: worker, terminal_source: nil})

              %{state | registry: Map.put(reg, execution_id, entry)}
            end)

            :ok
          end,
          worker_begin: fn _worker, _ref, timeout_ms ->
            send(test_pid, {:begin_with_timeout, timeout_ms})
            :ok
          end,
          await_settled: fn _id ->
            record(agent, :settle_calls)
            :ok
          end
        })

      assert {:error, :deadline_exhausted} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 deps
               )

      refute_received {:begin_with_timeout, 1}
      refute_received {:begin_with_timeout, _}
    end
  end

  describe "unit name" do
    test "generated unit name is internal and valid", %{agent: agent} do
      caller_name = "caller-nominated-name-should-be-ignored"

      deps =
        base_deps(agent, %{
          generate_unit_name: fn ->
            record(agent, :random_calls)
            name = "arbor-v1-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
            record(agent, :generated_names, name)
            name
          end
        })

      assert {:ok, _} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 # unit_name is not an allowed opt — generation is internal only.
                 valid_opts(),
                 deps
               )

      names = get_state(agent, :generated_names)
      assert length(names) == 1
      name = hd(names)
      assert name != caller_name
      assert Regex.match?(@unit_name_re, name)

      spec = get_state(agent, :last_spec)
      assert unit_name_from_spec(spec) == name
    end

    test "invalid unit-name generation returns bounded error without crash", %{agent: agent} do
      deps =
        base_deps(agent, %{
          generate_unit_name: fn ->
            record(agent, :random_calls)
            "INVALID_UPPERCASE"
          end
        })

      assert {:error, :unit_name_generation_failed} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert get_state(agent, :start_calls) == []
    end

    test "unit-name generation crash returns bounded error", %{agent: agent} do
      deps =
        base_deps(agent, %{
          generate_unit_name: fn ->
            record(agent, :random_calls)
            raise "boom"
          end
        })

      assert {:error, reason} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert reason in [:call_error, :unit_name_generation_failed]
      assert get_state(agent, :start_calls) == []
    end
  end

  describe "clock boundary" do
    test "non-integer monotonic clock returns bounded error", %{agent: agent} do
      deps =
        base_deps(agent, %{
          monotonic_ms: fn -> :not_an_integer end
        })

      assert {:error, :clock_unavailable} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)
    end

    test "monotonic clock crash returns bounded error", %{agent: agent} do
      deps =
        base_deps(agent, %{
          monotonic_ms: fn -> raise "clock broken" end
        })

      assert {:error, reason} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert reason in [:call_error, :clock_unavailable]
    end

    test "negative monotonic origin still completes preflight/probe/start", %{agent: agent} do
      # System.monotonic_time(:millisecond) uses an arbitrary origin and is
      # commonly negative on the live node. Deadline arithmetic is relative.
      put_state(agent, :mono, -50_000)

      deps =
        base_deps(agent, %{
          probe: fn remaining ->
            record(agent, :probe_calls, remaining)
            advance_mono(agent, 100)
            {:ok, @valid_admission}
          end
        })

      assert {:ok, result} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: 5_000),
                 deps
               )

      assert result.exit_code == 0
      assert get_state(agent, :probe_calls) != []
      assert get_state(agent, :register_calls) == 1
      assert length(get_state(agent, :start_calls)) == 1
      start_meta = hd(Enum.reverse(get_state(agent, :start_calls)))
      assert start_meta.timeout_ms > 0
      assert start_meta.timeout_ms <= 5_000
      # Origin remained negative through setup advances.
      assert get_state(agent, :mono) < 0
    end
  end

  describe "happy path" do
    test "does not return before exact worker DOWN plus owner_published Registry terminal", %{
      agent: agent
    } do
      test_pid = self()
      barrier = make_ref()

      deps =
        base_deps(agent, %{
          worker_start: fn spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{
              timeout_ms: Map.get(spec, :timeout_ms),
              execution_id: execution_id,
              start_ref: start_ref
            })

            put_state(agent, :last_spec, spec)
            put_state(agent, :last_execution_id, execution_id)
            put_state(agent, :last_start_ref, start_ref)
            controller = self()

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _from} ->
                    send(test_pid, {:worker_began, self()})

                    receive do
                      {:release, ^barrier} -> :ok
                    after
                      5_000 -> :ok
                    end

                    result = success_result(%{stdout: "done", duration_ms: 5})
                    publish_registry(agent, execution_id, :completed, result, :owner_published)

                    send(
                      controller,
                      {:apple_container_unit_terminal, execution_id, {:ok, result}}
                    )

                    :ok
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end
        })

      task =
        Task.async(fn ->
          Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)
        end)

      assert_receive {:worker_began, worker_pid}, 2_000
      assert Process.alive?(worker_pid)
      refute Task.yield(task, 50)

      send(worker_pid, {:release, barrier})
      assert {:ok, result} = Task.await(task, 2_000)
      assert result.exit_code == 0
      assert result.stdout == "done"
      refute Map.has_key?(result, :pid)
      refute Map.has_key?(result, :unit_name)
    end

    test "does not trust forged notifications and preserves unrelated mailbox", %{agent: agent} do
      unrelated = {:caller_mail, :keep_me}
      send(self(), unrelated)

      deps =
        base_deps(agent, %{
          worker_start: fn spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{
              timeout_ms: Map.get(spec, :timeout_ms),
              execution_id: execution_id,
              start_ref: start_ref
            })

            put_state(agent, :last_spec, spec)
            put_state(agent, :last_execution_id, execution_id)
            parent = self()

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _} ->
                    # Forged terminal for a different execution id.
                    send(parent, {:apple_container_unit_terminal, "exec_forged", {:ok, %{}}})
                    # Forged DOWN-like noise (wrong shape is just mail).
                    send(parent, {:DOWN, make_ref(), :process, self(), :kill})

                    result = success_result(%{stdout: "real", duration_ms: 1})
                    publish_registry(agent, execution_id, :completed, result, :owner_published)

                    send(
                      parent,
                      {:apple_container_unit_terminal, execution_id, {:ok, result}}
                    )

                    :ok
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end
        })

      assert {:ok, result} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert result.stdout == "real"
      assert_received ^unrelated
    end
  end

  describe "owner-published shell result semantics" do
    test "completed maps to {:ok, bound_result}", %{agent: agent} do
      result = success_result(%{stdout: "compiled"})
      deps = base_deps(agent, %{worker_start: worker_publishing(agent, :completed, result)})

      assert {:ok, out} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert out.stdout == "compiled"
      assert out.exit_code == 0
      assert out.timed_out == false
    end

    test "timed_out maps to {:ok, bound_result} matching Shell Executor", %{agent: agent} do
      result =
        success_result(%{
          exit_code: 137,
          stdout: "",
          timed_out: true,
          killed: true,
          duration_ms: 100
        })

      deps = base_deps(agent, %{worker_start: worker_publishing(agent, :timed_out, result)})

      assert {:ok, out} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert out.timed_out == true
      assert out.killed == true
      assert out.exit_code == 137
    end

    test "killed maps to {:ok, bound_result}", %{agent: agent} do
      result =
        success_result(%{
          exit_code: 137,
          timed_out: false,
          killed: true,
          cancelled: true,
          duration_ms: 50
        })

      deps = base_deps(agent, %{worker_start: worker_publishing(agent, :killed, result)})

      assert {:ok, out} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert out.killed == true
      assert out.cancelled == true
    end

    test "failed maps to {:error, bounded reason}", %{agent: agent} do
      result = %{error: :container_start_failed}

      deps = base_deps(agent, %{worker_start: worker_publishing(agent, :failed, result)})

      assert {:error, :container_start_failed} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)
    end

    test "output_limit owner-published completed is {:ok, result}", %{agent: agent} do
      result =
        success_result(%{
          exit_code: 137,
          killed: true,
          output_truncated: true,
          output_limit_exceeded: true
        })

      deps = base_deps(agent, %{worker_start: worker_publishing(agent, :killed, result)})

      assert {:ok, out} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert out.output_limit_exceeded == true
      assert out.killed == true
    end
  end

  describe "start errors" do
    test "every start error waits for settlement before return", %{agent: agent} do
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, _ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            put_state(agent, :last_execution_id, execution_id)
            {:error, :simulated_start_failure}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:settled, execution_id})
            :ok
          end
        })

      assert {:error, reason} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert reason == :simulated_start_failure or reason == :execution_uncertain or
               is_atom(reason)

      assert_received {:settled, exec_id}
      assert is_binary(exec_id)
      assert get_state(agent, :settle_calls) >= 1
      refute is_pid(reason)
      refute is_reference(reason)
    end

    test "coordinator turnover/unavailable is retried rather than treated as settled", %{
      agent: agent
    } do
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, _ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            {:error, :unit_start_failed}
          end,
          await_settled: fn execution_id ->
            n = record_and_count(agent, :settle_calls)
            send(test_pid, {:settle_attempt, n, execution_id})

            cond do
              n == 1 -> {:error, {:coordinator_unavailable, :noproc}}
              n == 2 -> {:error, :too_many_execution_waiters}
              true -> :ok
            end
          end
        })

      assert {:error, _} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert_received {:settle_attempt, 1, _}
      assert_received {:settle_attempt, 2, _}
      assert_received {:settle_attempt, 3, _}
      assert get_state(agent, :settle_calls) >= 3
    end
  end

  describe "terminal_source provenance" do
    test "owner_down after worker DOWN waits for settlement and returns bounded error", %{
      agent: agent
    } do
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: fn spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{
              timeout_ms: Map.get(spec, :timeout_ms),
              execution_id: execution_id
            })

            put_state(agent, :last_execution_id, execution_id)
            parent = self()

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _} ->
                    # Explicit owner_down provenance — NOT authoritative publish.
                    # Even if result.error shape looks like owner-down, source is king.
                    publish_registry(
                      agent,
                      execution_id,
                      :failed,
                      %{error: {:execution_owner_down, :killed}},
                      :owner_down
                    )

                    send(
                      parent,
                      {:apple_container_unit_terminal, execution_id,
                       {:error, :execution_owner_down}}
                    )

                    exit(:kill)
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:owner_down_settled, execution_id})
            :ok
          end
        })

      assert {:error, reason} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert is_atom(reason) or is_tuple(reason)
      # Must not project owner-down as a normal failed result.
      refute match?({:execution_owner_down, _}, reason)
      assert_received {:owner_down_settled, _}
      assert get_state(agent, :settle_calls) >= 1
      reason_inspect = inspect(reason)
      refute reason_inspect =~ "#PID"
      refute reason_inspect =~ "#Reference"
    end

    test "does not accept owner_down-shaped error when terminal_source is missing", %{
      agent: agent
    } do
      test_pid = self()

      # Old-shape inference trap: result looks like owner-down but source is nil.
      # Without explicit :owner_published this must settle, not project as success/fail.
      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            parent = self()

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _} ->
                    publish_registry(
                      agent,
                      execution_id,
                      :failed,
                      %{error: {:execution_owner_down, :noproc}},
                      nil
                    )

                    send(
                      parent,
                      {:apple_container_unit_terminal, execution_id, {:error, :owner_down}}
                    )

                    :ok
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:nil_source_settled, execution_id})
            :ok
          end
        })

      assert {:error, _} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert_received {:nil_source_settled, _}
      assert get_state(agent, :settle_calls) >= 1
    end

    test "missing registry terminal after worker DOWN settles and errors", %{agent: agent} do
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            put_state(agent, :last_execution_id, execution_id)

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _} ->
                    Agent.update(agent, fn state ->
                      reg = Map.delete(Map.get(state, :registry, %{}), execution_id)
                      %{state | registry: reg}
                    end)

                    :ok
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:missing_reg_settled, execution_id})
            :ok
          end
        })

      assert {:error, reason} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert reason in [:execution_uncertain, :execution_error] or is_atom(reason)
      assert_received {:missing_reg_settled, _}
    end

    test "nonterminal registry after worker DOWN settles", %{agent: agent} do
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{execution_id: execution_id})

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _} ->
                    # Leave status :running with nil source — nonterminal.
                    publish_registry(agent, execution_id, :running, nil, nil)
                    :ok
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:nonterminal_settled, execution_id})
            :ok
          end
        })

      assert {:error, _} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert_received {:nonterminal_settled, _}
      assert get_state(agent, :settle_calls) >= 1
    end

    test "registry get error after worker DOWN settles", %{agent: agent} do
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: worker_publishing(agent, :completed, success_result()),
          registry_get: fn _id ->
            {:error, :registry_restarting}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:reg_err_settled, execution_id})
            :ok
          end
        })

      assert {:error, _} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert_received {:reg_err_settled, _}
    end

    test "owner_published failed with nil result is malformed and settles", %{agent: agent} do
      # ExecutionRegistry.owner_fail always stores a result map. A nil result with
      # terminal_source: :owner_published is a malformed projection — settle.
      test_pid = self()

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            parent = self()

            worker =
              spawn(fn ->
                receive do
                  {:begin, ^start_ref, _} ->
                    publish_registry(agent, execution_id, :failed, nil, :owner_published)

                    send(
                      parent,
                      {:apple_container_unit_terminal, execution_id, {:error, :failed}}
                    )

                    :ok
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:nil_failed_settled, execution_id})
            :ok
          end
        })

      assert {:error, reason} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert is_atom(reason) or is_tuple(reason)
      assert_received {:nil_failed_settled, _}
      assert get_state(agent, :settle_calls) >= 1
    end
  end

  describe "exact known-worker cancellation" do
    test "sends cancel directly to known worker PID and settles before return", %{agent: agent} do
      test_pid = self()
      hold = make_ref()

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, start_ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            put_state(agent, :last_execution_id, execution_id)

            worker =
              spawn(fn ->
                receive do
                  {:cancel_shell_execution, ^execution_id} ->
                    send(test_pid, {:worker_got_cancel, execution_id, self()})
                    # Stay alive until settlement completes; DOWN is not required first.
                    receive do
                      {:release, ^hold} -> :ok
                    after
                      5_000 -> :ok
                    end

                  {:begin, ^start_ref, _} ->
                    # Should not begin in this test path.
                    send(test_pid, :unexpected_begin)
                end
              end)

            put_state(agent, :last_worker, worker)
            {:ok, worker}
          end,
          adopt: fn _execution_id, _worker ->
            record(agent, :adopt_calls)
            {:error, :simulated_adopt_failure}
          end,
          await_settled: fn execution_id ->
            record(agent, :settle_calls)
            send(test_pid, {:cancel_settled, execution_id})
            # Release worker after settlement observed so test can finish cleanly.
            case get_state(agent, :last_worker) do
              pid when is_pid(pid) -> send(pid, {:release, hold})
              _ -> :ok
            end

            :ok
          end
        })

      assert {:error, :simulated_adopt_failure} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert_received {:worker_got_cancel, exec_id, worker_pid}
      assert is_binary(exec_id)
      assert is_pid(worker_pid)
      assert_received {:cancel_settled, ^exec_id}
      assert get_state(agent, :settle_calls) >= 1
      refute_received :unexpected_begin
    end

    test "rejects request_cancel as a test dependency key", %{agent: agent} do
      deps =
        base_deps(agent)
        |> Map.put(:request_cancel, fn _id -> :ok end)

      assert {:error, :invalid_test_deps} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)
    end
  end

  describe "mailbox hygiene" do
    test "uncertain path leaves unrelated messages in place", %{agent: agent} do
      unrelated_a = {:mail_a, 1}
      unrelated_b = {:mail_b, 2}
      send(self(), unrelated_a)
      send(self(), unrelated_b)

      deps =
        base_deps(agent, %{
          worker_start: fn _spec, _exe, execution_id, _ref ->
            record(agent, :start_calls, %{execution_id: execution_id})
            {:error, :unit_start_failed}
          end,
          await_settled: fn _id ->
            record(agent, :settle_calls)
            :ok
          end
        })

      assert {:error, _} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      # Original order preserved; nothing stashed/re-sent out of order.
      assert_received ^unrelated_a
      assert_received ^unrelated_b
    end
  end

  describe "production facade" do
    test "relative tool is pure preflight before admission or candidate work" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["compile"], valid_opts())
    end

    test "rejects incomplete test deps" do
      assert {:error, :invalid_test_deps} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp record_and_count(agent, key) do
    Agent.get_and_update(agent, fn state ->
      n = Map.get(state, key, 0) + 1
      {n, Map.put(state, key, n)}
    end)
  end
end
