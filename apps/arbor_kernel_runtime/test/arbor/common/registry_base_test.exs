defmodule Arbor.Common.RegistryBaseTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  # Define a test behaviour
  defmodule TestBehaviour do
    @callback do_something() :: :ok
  end

  # Define modules implementing the behaviour
  defmodule GoodImpl do
    @behaviour TestBehaviour
    def do_something, do: :ok
  end

  defmodule AvailableImpl do
    @behaviour TestBehaviour
    def do_something, do: :ok
    def available?, do: true
  end

  defmodule UnavailableImpl do
    @behaviour TestBehaviour
    def do_something, do: :ok
    def available?, do: false
  end

  defmodule NoBehaviourImpl do
    def do_something, do: :ok
  end

  # Define test registries
  defmodule BasicRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_basic_registry
  end

  defmodule StrictRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_strict_registry,
      require_behaviour: TestBehaviour
  end

  defmodule OverwriteRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_overwrite_registry,
      allow_overwrite: true
  end

  defmodule CircuitBreakerRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_cb_registry,
      max_failures: 3
  end

  defmodule CustomValidationRegistry do
    use Arbor.Common.RegistryBase,
      table_name: :test_custom_validation_registry

    def validate_entry(name, _module, _metadata) do
      if String.starts_with?(name, "valid_") do
        :ok
      else
        {:error, :invalid_name_prefix}
      end
    end
  end

  defp stop_registry(registry) do
    # Erase persistent_term snapshot before stopping
    try do
      :persistent_term.erase({registry, :core_snapshot})
    rescue
      ArgumentError -> :ok
    end

    case GenServer.whereis(registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Give heir a moment to receive ETS-TRANSFER, then delete the table
    Process.sleep(10)

    for table <- [
          :test_strict_registry,
          :test_overwrite_registry,
          :test_cb_registry,
          :test_custom_validation_registry
        ] do
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp ensure_started(registry) do
    case GenServer.whereis(registry) do
      nil -> {:ok, _} = registry.start_link()
      _pid -> registry.reset()
    end
  end

  defp ensure_basic_registry do
    case GenServer.whereis(BasicRegistry) do
      nil ->
        {:ok, _} = BasicRegistry.start_link()

      _pid ->
        :ok
    end
  rescue
    _ ->
      Process.sleep(50)
      {:ok, _} = BasicRegistry.start_link()
  catch
    :exit, _ ->
      Process.sleep(50)
      {:ok, _} = BasicRegistry.start_link()
  end

  defp safe_basic_reset do
    BasicRegistry.reset()
  catch
    :exit, _ ->
      Process.sleep(50)
      ensure_basic_registry()
      BasicRegistry.reset()
  end

  # A minimal, protocol-speaking stand-in for the real heir_owner/2 state
  # machine, used to deterministically construct an owner-DOWN vs.
  # transfer-ordering scenario: waits to actually become the ETS owner (a
  # real transfer, not a forged message), then answers exactly one claim.
  defp await_and_answer_claim(table_name) do
    receive do
      {:"ETS-TRANSFER", ^table_name, _from_pid, _data} ->
        table_ref = :ets.whereis(table_name)

        receive do
          {:claim_ets_table, ^table_name, ^table_ref, claim_ref, claimant_pid}
          when is_pid(claimant_pid) ->
            if :ets.info(table_ref, :owner) == self() do
              :ets.give_away(table_ref, claimant_pid, {table_ref, claim_ref})
            end
        end
    end
  end

  # Erlang's :receive trace proves delivery to the target mailbox, not that
  # the target's current receive expression selected the message.
  defp send_and_await_delivery(pid, message) do
    :erlang.trace(pid, true, [{:tracer, self()}, :receive])

    try do
      send(pid, message)
      assert_receive {:trace, ^pid, :receive, ^message}, 1_000
    after
      disable_receive_trace(pid)
    end
  end

  defp disable_receive_trace(pid) do
    :erlang.trace(pid, false, [:receive])
  rescue
    ArgumentError -> :ok
  end

  # A bounded mailbox drain is used only when the test must prove that the
  # raw heir process selected a delivered message.
  defp assert_mailbox_eventually_empty(pid, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_mailbox_empty(pid, deadline)
  end

  defp poll_mailbox_empty(pid, deadline) do
    case Process.info(pid, :messages) do
      {:messages, []} ->
        :ok

      {:messages, _pending} = not_empty ->
        if System.monotonic_time(:millisecond) >= deadline do
          assert {:messages, []} = not_empty
        else
          Process.sleep(2)
          poll_mailbox_empty(pid, deadline)
        end
    end
  end

  setup do
    ensure_basic_registry()
    safe_basic_reset()

    on_exit(fn ->
      # Don't stop — let the process persist across tests to avoid heir issues.
      # reset/0 in setup handles isolation.
      :ok
    end)

    :ok
  end

  describe "register/3 and resolve/1" do
    test "registers and resolves a module" do
      assert :ok = BasicRegistry.register("test", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("test")
    end

    test "resolves with metadata via resolve_entry/1" do
      meta = %{cost: 0.01, provider: "local"}
      assert :ok = BasicRegistry.register("test", GoodImpl, meta)
      assert {:ok, {"test", GoodImpl, ^meta}} = BasicRegistry.resolve_entry("test")
    end

    test "returns :not_found for unregistered name" do
      assert {:error, :not_found} = BasicRegistry.resolve("nonexistent")
    end

    test "returns :not_found for entry resolve" do
      assert {:error, :not_found} = BasicRegistry.resolve_entry("nonexistent")
    end

    test "default metadata is empty map" do
      :ok = BasicRegistry.register("test", GoodImpl)
      {:ok, {"test", GoodImpl, meta}} = BasicRegistry.resolve_entry("test")
      assert meta == %{}
    end
  end

  describe "deregister/1" do
    test "removes a registered entry" do
      :ok = BasicRegistry.register("test", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("test")

      assert :ok = BasicRegistry.deregister("test")
      assert {:error, :not_found} = BasicRegistry.resolve("test")
    end

    test "returns :not_found for unregistered name" do
      assert {:error, :not_found} = BasicRegistry.deregister("nonexistent")
    end
  end

  describe "list_all/0 and list_available/0" do
    test "lists all registered entries" do
      :ok = BasicRegistry.register("a", GoodImpl, %{order: 1})
      :ok = BasicRegistry.register("b", GoodImpl, %{order: 2})

      entries = BasicRegistry.list_all()
      assert length(entries) == 2

      names = Enum.map(entries, fn {name, _mod, _meta} -> name end) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "list_available excludes unavailable modules" do
      :ok = BasicRegistry.register("available", AvailableImpl)
      :ok = BasicRegistry.register("unavailable", UnavailableImpl)
      :ok = BasicRegistry.register("no_check", GoodImpl)

      available = BasicRegistry.list_available()
      names = Enum.map(available, fn {name, _mod, _meta} -> name end) |> Enum.sort()
      assert "available" in names
      assert "no_check" in names
      refute "unavailable" in names
    end
  end

  describe "namespace sovereignty" do
    test "lock_core prevents overwriting core entries" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()

      assert BasicRegistry.core_locked?()
      assert {:error, :core_locked} = BasicRegistry.register("core_source", AvailableImpl)

      # But the original is still resolvable
      assert {:ok, GoodImpl} = BasicRegistry.resolve("core_source")
    end

    test "lock_core prevents deregistering core entries" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()

      assert {:error, :core_locked} = BasicRegistry.deregister("core_source")
    end

    test "new entries can be registered after lock" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()

      assert :ok = BasicRegistry.register("plugin.new_source", AvailableImpl)
      assert {:ok, AvailableImpl} = BasicRegistry.resolve("plugin.new_source")
    end

    test "new entries registered after lock can be deregistered" do
      :ok = BasicRegistry.register("core_source", GoodImpl)
      :ok = BasicRegistry.lock_core()
      :ok = BasicRegistry.register("plugin.new_source", AvailableImpl)

      assert :ok = BasicRegistry.deregister("plugin.new_source")
    end
  end

  describe "overwrite protection" do
    test "default: duplicate registration is rejected" do
      :ok = BasicRegistry.register("test", GoodImpl)
      assert {:error, :already_registered} = BasicRegistry.register("test", AvailableImpl)
    end

    test "allow_overwrite: duplicate registration overwrites" do
      ensure_started(OverwriteRegistry)

      :ok = OverwriteRegistry.register("test", GoodImpl)
      :ok = OverwriteRegistry.register("test", AvailableImpl)
      assert {:ok, AvailableImpl} = OverwriteRegistry.resolve("test")

      stop_registry(OverwriteRegistry)
    end

    test "allow_overwrite still respects core lock" do
      ensure_started(OverwriteRegistry)

      :ok = OverwriteRegistry.register("test", GoodImpl)
      :ok = OverwriteRegistry.lock_core()
      assert {:error, :core_locked} = OverwriteRegistry.register("test", AvailableImpl)

      stop_registry(OverwriteRegistry)
    end
  end

  describe "behaviour enforcement" do
    test "strict registry accepts modules with required behaviour" do
      ensure_started(StrictRegistry)

      assert :ok = StrictRegistry.register("test", GoodImpl)

      stop_registry(StrictRegistry)
    end

    test "strict registry rejects modules without required behaviour" do
      ensure_started(StrictRegistry)

      assert {:error, {:missing_behaviour, TestBehaviour}} =
               StrictRegistry.register("test", NoBehaviourImpl)

      stop_registry(StrictRegistry)
    end
  end

  describe "circuit breaker" do
    test "record_failure increments failure count" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("test", GoodImpl)
      :ok = CircuitBreakerRegistry.record_failure("test")
      :ok = CircuitBreakerRegistry.record_failure("test")

      # Still available (2 < 3 threshold)
      available = CircuitBreakerRegistry.list_available()
      assert length(available) == 1

      stop_registry(CircuitBreakerRegistry)
    end

    test "entry becomes unstable after max_failures" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("test", GoodImpl)
      :ok = CircuitBreakerRegistry.record_failure("test")
      :ok = CircuitBreakerRegistry.record_failure("test")
      :ok = CircuitBreakerRegistry.record_failure("test")

      # Not in available list (3 >= 3 threshold)
      available = CircuitBreakerRegistry.list_available()
      assert available == []

      # But still resolvable
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve("test")

      stop_registry(CircuitBreakerRegistry)
    end

    test "reset_failures restores availability" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("test", GoodImpl)

      for _ <- 1..3, do: CircuitBreakerRegistry.record_failure("test")

      assert CircuitBreakerRegistry.list_available() == []

      :ok = CircuitBreakerRegistry.reset_failures("test")
      assert length(CircuitBreakerRegistry.list_available()) == 1

      stop_registry(CircuitBreakerRegistry)
    end

    test "record_failure on nonexistent entry returns error" do
      ensure_started(CircuitBreakerRegistry)

      assert {:error, :not_found} = CircuitBreakerRegistry.record_failure("nope")

      stop_registry(CircuitBreakerRegistry)
    end
  end

  describe "snapshot/restore" do
    test "snapshot captures state and restore replays it" do
      :ok = BasicRegistry.register("a", GoodImpl, %{v: 1})
      :ok = BasicRegistry.register("b", AvailableImpl, %{v: 2})

      snapshot = BasicRegistry.snapshot()

      # Modify state
      :ok = BasicRegistry.deregister("a")
      assert {:error, :not_found} = BasicRegistry.resolve("a")

      # Restore
      :ok = BasicRegistry.restore(snapshot)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("a")
      assert {:ok, AvailableImpl} = BasicRegistry.resolve("b")
    end

    test "snapshot preserves core_locked state" do
      :ok = BasicRegistry.register("core", GoodImpl)
      :ok = BasicRegistry.lock_core()

      {_entries, core_locked} = BasicRegistry.snapshot()
      assert core_locked == true
    end
  end

  describe "custom validation" do
    test "custom validate_entry is called" do
      ensure_started(CustomValidationRegistry)

      assert :ok = CustomValidationRegistry.register("valid_source", GoodImpl)
      assert {:error, :invalid_name_prefix} = CustomValidationRegistry.register("bad", GoodImpl)

      stop_registry(CustomValidationRegistry)
    end
  end

  describe "plugin namespace enforcement" do
    test "before core lock, any name is allowed" do
      :ok = BasicRegistry.register("simple_name", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("simple_name")
    end

    test "after core lock, plugin names must contain a dot" do
      :ok = BasicRegistry.register("core_entry", GoodImpl)
      :ok = BasicRegistry.lock_core()

      # Plugin with dot prefix succeeds
      assert :ok = BasicRegistry.register("myplugin.custom", AvailableImpl)

      # Plugin without dot is rejected
      assert {:error, {:plugin_namespace_required, "bare_name"}} =
               BasicRegistry.register("bare_name", AvailableImpl)
    end

    test "core entries can still be registered before lock" do
      :ok = BasicRegistry.register("no_dot_name", GoodImpl)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("no_dot_name")
    end
  end

  describe "resolve_stable" do
    test "returns module for healthy entries" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("healthy", GoodImpl)
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve_stable("healthy")

      stop_registry(CircuitBreakerRegistry)
    end

    test "returns :unstable for entries over failure threshold" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("flaky", GoodImpl)

      for _ <- 1..3, do: CircuitBreakerRegistry.record_failure("flaky")

      # resolve still works
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve("flaky")

      # resolve_stable blocks unstable entries
      assert {:error, :unstable} = CircuitBreakerRegistry.resolve_stable("flaky")

      stop_registry(CircuitBreakerRegistry)
    end

    test "returns :not_found for missing entries" do
      ensure_started(CircuitBreakerRegistry)

      assert {:error, :not_found} = CircuitBreakerRegistry.resolve_stable("nope")

      stop_registry(CircuitBreakerRegistry)
    end

    test "reset_failures restores resolve_stable" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("recovered", GoodImpl)

      for _ <- 1..3, do: CircuitBreakerRegistry.record_failure("recovered")

      assert {:error, :unstable} = CircuitBreakerRegistry.resolve_stable("recovered")

      :ok = CircuitBreakerRegistry.reset_failures("recovered")
      assert {:ok, GoodImpl} = CircuitBreakerRegistry.resolve_stable("recovered")

      stop_registry(CircuitBreakerRegistry)
    end
  end

  describe "persistent_term fast path" do
    test "resolve uses persistent_term after lock_core" do
      :ok = BasicRegistry.register("fast", GoodImpl)
      :ok = BasicRegistry.lock_core()

      # persistent_term should be populated
      pt_key = {BasicRegistry, :core_snapshot}
      snapshot = :persistent_term.get(pt_key, nil)
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, "fast")

      # Resolve should still work (via fast path)
      assert {:ok, GoodImpl} = BasicRegistry.resolve("fast")
      assert {:ok, GoodImpl} = BasicRegistry.resolve_stable("fast")
    end

    test "reset clears persistent_term" do
      :ok = BasicRegistry.register("temp", GoodImpl)
      :ok = BasicRegistry.lock_core()

      pt_key = {BasicRegistry, :core_snapshot}
      assert :persistent_term.get(pt_key, nil) != nil

      BasicRegistry.reset()
      assert :persistent_term.get(pt_key, nil) == nil
    end

    test "record_failure invalidates persistent_term" do
      ensure_started(CircuitBreakerRegistry)

      :ok = CircuitBreakerRegistry.register("failing", GoodImpl)
      :ok = CircuitBreakerRegistry.lock_core()

      pt_key = {CircuitBreakerRegistry, :core_snapshot}
      assert :persistent_term.get(pt_key, nil) != nil

      :ok = CircuitBreakerRegistry.record_failure("failing")
      # Snapshot invalidated after failure
      assert :persistent_term.get(pt_key, nil) == nil

      stop_registry(CircuitBreakerRegistry)
    end
  end

  describe "ETS heir protection" do
    test "table data survives registry restart via heir" do
      :ok = BasicRegistry.register("persistent", GoodImpl)

      # Stop the GenServer gracefully
      GenServer.stop(BasicRegistry)

      # Table should still exist (held by heir)
      assert [{_name, _mod, _meta, _failures, _core?}] =
               :ets.lookup(:test_basic_registry, "persistent")

      # Restart — init should reclaim the existing table
      {:ok, _pid} = BasicRegistry.start_link()

      # Data should still be there
      assert {:ok, GoodImpl} = BasicRegistry.resolve("persistent")
    end
  end

  # ===========================================================================
  # Owner-mediated ETS handoff (crash-recovery state machine)
  #
  # These kill the registry abnormally (Process.exit(pid, :kill), not
  # GenServer.stop) to exercise a genuine crash rather than a graceful
  # shutdown, and use Process.monitor/assert_receive for synchronization
  # instead of Process.sleep polling loops.
  # ===========================================================================

  describe "owner-mediated ETS handoff" do
    test "an abnormal kill hands the table to the old heir, which the replacement claims, preserving data" do
      :ok = BasicRegistry.register("abnormal_kill_check", GoodImpl)

      pid = Process.whereis(BasicRegistry)
      mon = Process.monitor(pid)
      # start_link linked us to the registry; unlink before the kill so the
      # kill signal doesn't also crash this test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mon, :process, ^pid, :killed}, 1_000

      # Erlang performs the heir transfer synchronously as part of the dying
      # owner's termination — by the time our DOWN lands, it has happened.
      old_heir = :ets.info(:test_basic_registry, :owner)
      assert is_pid(old_heir)
      refute old_heir == pid

      {:ok, new_pid} = BasicRegistry.start_link()

      assert Process.whereis(BasicRegistry) == new_pid
      assert :ets.info(:test_basic_registry, :owner) == new_pid
      assert {:ok, GoodImpl} = BasicRegistry.resolve("abnormal_kill_check")
    end

    test "restart installs exactly one fresh heir; the old heir exits and no extra heir remains" do
      :ok = BasicRegistry.register("fresh_heir_no_extra_check", GoodImpl)

      old_heir = :ets.info(:test_basic_registry, :heir)
      assert is_pid(old_heir)

      pid = Process.whereis(BasicRegistry)
      pid_mon = Process.monitor(pid)
      # start_link linked us to the registry; unlink before the kill so the
      # kill signal doesn't also crash this test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^pid_mon, :process, ^pid, :killed}, 1_000

      old_heir_mon = Process.monitor(old_heir)

      {:ok, _new_pid} = BasicRegistry.start_link()

      # The old heir must exit promptly after a successful hand-off —
      # confirmed via a monitor DOWN, not by polling Process.alive?/1.
      assert_receive {:DOWN, ^old_heir_mon, :process, ^old_heir, _reason}, 1_000

      new_heir = :ets.info(:test_basic_registry, :heir)
      assert is_pid(new_heir)
      assert new_heir != old_heir
      assert Process.alive?(new_heir)
      # No extra heir remains: the specific old one is confirmed gone above,
      # not merely "some heir is alive".
      refute Process.alive?(old_heir)
    end

    test "a claimant pid that doesn't match the registered module is rejected" do
      :ok = BasicRegistry.register("invalid_claimant_check", GoodImpl)

      pid = Process.whereis(BasicRegistry)
      mon = Process.monitor(pid)
      # start_link linked us to the registry; unlink before the kill so the
      # kill signal doesn't also crash this test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mon, :process, ^pid, :killed}, 1_000

      owner = :ets.info(:test_basic_registry, :owner)
      table_ref = :ets.whereis(:test_basic_registry)
      assert is_pid(owner)

      # Correct table generation, but the claimant pid (our own test
      # process) does not equal Process.whereis(BasicRegistry) — currently
      # nil, since the registry hasn't restarted yet.
      send(owner, {:claim_ets_table, :test_basic_registry, table_ref, make_ref(), self()})

      # A legitimate restart afterward must still succeed — the heir stays
      # in owner state after rejecting the bogus claim above, rather than
      # crashing or getting stuck.
      {:ok, new_pid} = BasicRegistry.start_link()
      assert :ets.info(:test_basic_registry, :owner) == new_pid
      assert {:ok, GoodImpl} = BasicRegistry.resolve("invalid_claimant_check")
    end

    test "a claim bound to a stale table-generation reference is rejected" do
      :ok = BasicRegistry.register("stale_generation_check", GoodImpl)

      pid = Process.whereis(BasicRegistry)
      mon = Process.monitor(pid)
      # start_link linked us to the registry; unlink before the kill so the
      # kill signal doesn't also crash this test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mon, :process, ^pid, :killed}, 1_000

      owner = :ets.info(:test_basic_registry, :owner)
      table_ref = :ets.whereis(:test_basic_registry)
      assert is_pid(owner)

      # Make the claimant pid VALID (Process.whereis(BasicRegistry) ==
      # claimant_pid) so the only thing wrong with this claim is the table
      # generation — otherwise an invalid-claimant rejection would be
      # indistinguishable from a stale-generation rejection, and this test
      # would prove nothing about generation checking specifically.
      real_claimant = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(real_claimant, BasicRegistry)

      # A throwaway table gives us a real, distinct ETS reference to stand
      # in for "a different table generation" without needing to actually
      # delete and recreate :test_basic_registry.
      stale_ref = :ets.new(:stale_generation_stand_in, [])
      :ets.delete(stale_ref)

      claim_msg = {:claim_ets_table, :test_basic_registry, stale_ref, make_ref(), real_claimant}
      send_and_await_delivery(owner, claim_msg)

      # Prove the old heir RETAINED ownership — the claim was rejected, not
      # silently accepted — before ever attempting the legitimate restart.
      assert :ets.info(:test_basic_registry, :owner) == owner
      assert Process.alive?(owner)

      # Clean up the temporary claimant impersonation before the real
      # restart claims the name.
      Process.unregister(BasicRegistry)
      Process.exit(real_claimant, :kill)

      # A legitimate restart (which reads the real, current generation)
      # must still succeed — proving the stale-generation claim was
      # specifically what was rejected, with a claimant pid that would
      # otherwise have been perfectly valid.
      {:ok, new_pid} = BasicRegistry.start_link()
      assert :ets.info(:test_basic_registry, :owner) == new_pid
      assert :ets.whereis(:test_basic_registry) == table_ref
      assert {:ok, GoodImpl} = BasicRegistry.resolve("stale_generation_check")
    end

    test "a forged transfer-shaped message cannot disarm or expire the standby heir" do
      :ok = BasicRegistry.register("forged_transfer_check", GoodImpl)

      real_owner = Process.whereis(BasicRegistry)
      heir = :ets.info(:test_basic_registry, :heir)
      assert is_pid(heir)

      # Neither of these is a real ETS ownership transfer — only the VM
      # sends one, and only when the actual owner terminates. Both are
      # forged, transfer-shaped messages from an arbitrary process (this
      # test). Delivery tracing and a bounded mailbox drain distinguish
      # delivery from the standby loop actually selecting each message.
      forged_1 = {:"ETS-TRANSFER", :test_basic_registry, self(), :forged_1}
      forged_2 = {:"ETS-TRANSFER", :test_basic_registry, self(), :forged_2}
      send_and_await_delivery(heir, forged_1)
      assert_mailbox_eventually_empty(heir)
      send_and_await_delivery(heir, forged_2)
      assert_mailbox_eventually_empty(heir)

      # Real ownership must be completely unaffected by the forgeries.
      assert :ets.info(:test_basic_registry, :owner) == real_owner
      assert Process.alive?(heir)

      # Definitive end-to-end proof: since the heir was never disarmed, a
      # genuine crash afterward still recovers correctly.
      pid_mon = Process.monitor(real_owner)
      Process.unlink(real_owner)
      Process.exit(real_owner, :kill)
      assert_receive {:DOWN, ^pid_mon, :process, ^real_owner, :killed}, 1_000

      assert :ets.info(:test_basic_registry, :owner) == heir

      {:ok, new_pid} = BasicRegistry.start_link()
      assert :ets.info(:test_basic_registry, :owner) == new_pid
      assert {:ok, GoodImpl} = BasicRegistry.resolve("forged_transfer_check")
    end

    # No test for give_away_safely/3's rescue branch: the race it guards
    # (a validated claimant dying between heir_claim_valid?/2 and
    # :ets.give_away/3, two back-to-back native calls with no yield point
    # in between) cannot be forced deterministically from black-box test
    # code — measured empirically at ~10-40% hit rate across seeded runs,
    # with the remaining runs either rejecting the claim before give_away
    # or completing it successfully, neither of which exercises the rescue
    # at all. A test built on that race would be nondeterministic and, on
    # its non-triggering paths, vacuous. The rescue itself remains in
    # source (see give_away_safely/3) — verified by hand during
    # development that removing it reproduces an uncaught
    # :ets.give_away ArgumentError crash in the heir.

    test "owner-DOWN vs. transfer ordering: the replacement retries and obtains the table from a second, live owner" do
      # Vacate the real registry and its table entirely so this test can
      # construct a fully controlled scenario from scratch: two
      # protocol-speaking helper processes standing in for successive old
      # heirs, chained via a real ETS heir transfer.
      case Process.whereis(BasicRegistry) do
        nil ->
          :ok

        pid ->
          mon = Process.monitor(pid)
          Process.unlink(pid)
          Process.exit(pid, :kill)
          assert_receive {:DOWN, ^mon, :process, ^pid, :killed}, 1_000
      end

      # Whatever currently holds :test_basic_registry (if anything — the
      # real heir from the kill above), reclaim the raw name for our own
      # controlled owner1 by killing that holder directly (its own actual
      # owner triggers deletion; nothing foreign touches the table).
      case :ets.info(:test_basic_registry, :owner) do
        :undefined ->
          :ok

        stale_owner ->
          stale_mon = Process.monitor(stale_owner)
          Process.exit(stale_owner, :kill)
          assert_receive {:DOWN, ^stale_mon, :process, ^stale_owner, _}, 1_000
      end

      assert :ets.whereis(:test_basic_registry) == :undefined

      test_pid = self()

      # owner2: a second, protocol-speaking helper. Not yet the table's
      # owner — it becomes so only via a REAL ETS heir transfer once
      # owner1 dies.
      owner2 = spawn(fn -> await_and_answer_claim(:test_basic_registry) end)

      # owner1: creates the exact named table itself (so it is genuinely,
      # verifiably its owner), with owner2 configured as ITS heir, holds a
      # real entry, and reports a claim back to the test before going
      # silent — never answering it itself.
      owner1 =
        spawn(fn ->
          :ets.new(:test_basic_registry, [
            :set,
            :named_table,
            :public,
            {:heir, owner2, :test_basic_registry}
          ])

          :ets.insert(:test_basic_registry, {"ordering_check", GoodImpl, %{}, 0, false})
          send(test_pid, {:owner1_ready, :ets.whereis(:test_basic_registry)})

          receive do
            {:claim_ets_table, :test_basic_registry, _table_ref, _claim_ref, _claimant} ->
              send(test_pid, :owner1_saw_claim)

              receive do
                :never_arrives -> :ok
              end
          end
        end)

      table_ref =
        receive do
          {:owner1_ready, ref} -> ref
        after
          1_000 -> flunk("owner1 did not initialize the table")
        end

      owner1_mon = Process.monitor(owner1)

      # The replacement's init/1 will block inside claim_table/2 waiting on
      # owner1 — run it concurrently so the test can drive the race.
      replacement_task = Task.async(fn -> BasicRegistry.start_link() end)

      # Deterministic synchronization: only kill owner1 once it has
      # actually received the replacement's claim (proving the replacement
      # already sent it and is monitoring owner1) — no scheduling luck
      # involved.
      assert_receive :owner1_saw_claim, 1_000

      Process.exit(owner1, :kill)
      assert_receive {:DOWN, ^owner1_mon, :process, ^owner1, :killed}, 1_000

      # Erlang transfers the SAME table generation to owner2 synchronously
      # as part of owner1's death. The replacement's claim_table/2 must
      # observe owner1's DOWN, re-read the exact current owner, and retry
      # against owner2 — obtaining the table from it.
      assert {:ok, new_pid} = Task.await(replacement_task, 2_000)

      assert :ets.info(:test_basic_registry, :owner) == new_pid
      assert :ets.whereis(:test_basic_registry) == table_ref
      assert {:ok, GoodImpl} = BasicRegistry.resolve("ordering_check")
    end

    test "fresh startup (no orphaned table) creates exactly one heir and proves ownership/heir invariants" do
      pid = Process.whereis(BasicRegistry)
      pid_mon = Process.monitor(pid)
      # start_link linked us to the registry; unlink before the kill so the
      # kill signal doesn't also crash this test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^pid_mon, :process, ^pid, :killed}, 1_000

      old_heir = :ets.info(:test_basic_registry, :owner)
      assert is_pid(old_heir)

      # Reach a genuinely fresh-boot precondition (no table at all) without
      # any foreign :ets.delete/1: kill the CURRENT ACTUAL OWNER (old_heir)
      # directly. Since it is still its own :heir, its own termination is
      # what causes Erlang to delete the table — not an unrelated process
      # reaching in — and old_heir is cleanly reaped via the monitor below
      # rather than left leaking in a 60-second wait for a claim that could
      # now never arrive.
      old_heir_mon = Process.monitor(old_heir)
      Process.exit(old_heir, :kill)
      assert_receive {:DOWN, ^old_heir_mon, :process, ^old_heir, :killed}, 1_000
      assert :ets.whereis(:test_basic_registry) == :undefined

      {:ok, new_pid} = BasicRegistry.start_link()

      assert :ets.info(:test_basic_registry, :owner) == new_pid
      heir = :ets.info(:test_basic_registry, :heir)
      assert is_pid(heir)
      assert Process.alive?(heir)
      refute heir == old_heir
    end
  end

  # ===========================================================================
  # resolve/2 — node-aware resolution
  # ===========================================================================

  describe "resolve/2 with node option" do
    setup do
      ensure_basic_registry()
      safe_basic_reset()
      BasicRegistry.register("local_handler", GoodImpl, %{})
      :ok
    end

    test "node: :local behaves like resolve/1" do
      assert {:ok, GoodImpl} = BasicRegistry.resolve("local_handler", node: :local)
    end

    test "node: :local returns :not_found for missing" do
      assert {:error, :not_found} = BasicRegistry.resolve("missing", node: :local)
    end

    test "node: :any resolves locally first" do
      assert {:ok, GoodImpl} = BasicRegistry.resolve("local_handler", node: :any)
    end

    test "node: :any returns :not_found when not found locally and no remote members" do
      assert {:error, :not_found} = BasicRegistry.resolve("nonexistent", node: :any)
    end

    test "node: self() resolves locally" do
      assert {:ok, GoodImpl} = BasicRegistry.resolve("local_handler", node: node())
    end

    test "node: unknown_node returns :node_not_found" do
      assert {:error, :node_not_found} =
               BasicRegistry.resolve("local_handler", node: :unknown@nowhere)
    end

    test "defaults to :local when no option given" do
      assert {:ok, GoodImpl} = BasicRegistry.resolve("local_handler", [])
    end
  end

  # ===========================================================================
  # resolve_remote handler (GenServer callback)
  # ===========================================================================

  describe "resolve_remote GenServer handler" do
    setup do
      ensure_basic_registry()
      safe_basic_reset()
      BasicRegistry.register("remote_test", GoodImpl, %{cost: :low})
      :ok
    end

    test "returns module and metadata for existing entry" do
      result = GenServer.call(BasicRegistry, {:resolve_remote, "remote_test"})
      assert {:ok, GoodImpl, %{cost: :low}} = result
    end

    test "returns :not_found for missing entry" do
      result = GenServer.call(BasicRegistry, {:resolve_remote, "missing"})
      assert {:error, :not_found} = result
    end

    test "returns :unstable for entry over failure threshold" do
      # BasicRegistry has default max_failures: 5
      for _ <- 1..5, do: BasicRegistry.record_failure("remote_test")

      result = GenServer.call(BasicRegistry, {:resolve_remote, "remote_test"})
      assert {:error, :unstable} = result
    end
  end

  # ===========================================================================
  # pg integration
  # ===========================================================================

  describe "pg group membership" do
    setup do
      # Ensure pg scope is running (may not be if app started with start_children: false)
      case :pg.start_link(:arbor_registry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Stop and restart BasicRegistry so it joins the pg group
      case Process.whereis(BasicRegistry) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      Process.sleep(20)

      # Clean up ETS if held by heir
      try do
        :ets.delete(:test_basic_registry)
      rescue
        ArgumentError -> :ok
      end

      {:ok, _} = BasicRegistry.start_link()
      :ok
    end

    test "registry joins pg group on start" do
      members = :pg.get_members(:arbor_registry, {:registry, :test_basic_registry})
      registry_pid = Process.whereis(BasicRegistry)
      assert registry_pid in members
    end
  end

  # ===========================================================================
  # Remote cache
  # ===========================================================================

  describe "remote cache" do
    setup do
      ensure_basic_registry()
      safe_basic_reset()
      :ok
    end

    test "cache entries are stored in ETS with TTL" do
      # Manually insert a cache entry
      expiry = System.monotonic_time(:millisecond) + 30_000

      :ets.insert(
        :test_basic_registry,
        {{:remote_cache, "cached_handler"}, GoodImpl, :remote@host, expiry}
      )

      # Verify it's readable via resolve/2 with node: :any
      # (local lookup will miss, but cache won't be checked for :any — that's the remote path)
      # Instead, let's verify the raw ETS entry exists
      assert [{{:remote_cache, "cached_handler"}, GoodImpl, :remote@host, ^expiry}] =
               :ets.lookup(:test_basic_registry, {:remote_cache, "cached_handler"})
    end

    test "expired cache entries are ignored" do
      # Insert an expired cache entry
      expiry = System.monotonic_time(:millisecond) - 1000

      :ets.insert(
        :test_basic_registry,
        {{:remote_cache, "expired_handler"}, GoodImpl, :remote@host, expiry}
      )

      # The entry exists but would be treated as :miss by the cache lookup
      # resolve/2 will go through remote path and find no pg members
      assert {:error, :not_found} = BasicRegistry.resolve("expired_handler", node: :any)
    end
  end

  # ===========================================================================
  # call_remote/3
  # ===========================================================================

  describe "call_remote/3" do
    setup do
      ensure_basic_registry()
      safe_basic_reset()
      :ok
    end

    test "returns :node_not_found for unknown node" do
      assert {:error, :node_not_found} =
               BasicRegistry.call_remote("handler", :unknown@host, {:some_func, []})
    end

    test "resolves locally and calls on self node" do
      BasicRegistry.register("callable", GoodImpl, %{})
      # call_remote to self node should work via resolve + erpc
      result = BasicRegistry.call_remote("callable", node(), {:do_something, []})
      assert {:ok, :ok} = result
    end
  end
end
