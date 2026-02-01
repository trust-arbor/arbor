defmodule Arbor.Actions.Code.HotLoadBehavioralTest do
  use ExUnit.Case, async: false

  # HotLoad modifies global VM state (loaded modules), so async: false is required.

  alias Arbor.Actions.Code.HotLoad

  @moduletag :integration

  @target_module "Arbor.Actions.Code.HotLoadBehavioralTest.Target"
  @target_fqn "Elixir.Arbor.Actions.Code.HotLoadBehavioralTest.Target"

  @original_source """
  defmodule #{@target_fqn} do
    def value, do: :original
    def health_check, do: :ok
  end
  """

  setup do
    # Write the Target module's .beam file to disk so that HotLoad's
    # save_original/1 (which uses :code.get_object_code) can find it.
    # Without this, in-memory test modules have no .beam on the code path
    # and rollback gets nil instead of the original binary.
    beam_dir = Path.join(System.tmp_dir!(), "hot_load_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(beam_dir)

    # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
    [{module, binary}] = Code.compile_string(@original_source)

    beam_file = Path.join(beam_dir, "#{module}.beam")
    File.write!(beam_file, binary)
    true = :code.add_patha(String.to_charlist(beam_dir))

    on_exit(fn ->
      # Restore the original module from the saved binary
      :code.load_binary(module, String.to_charlist(beam_file), binary)
      :code.del_path(String.to_charlist(beam_dir))
      File.rm_rf!(beam_dir)
    end)

    :ok
  end

  describe "successful hot-load" do
    test "loads module without verification" do
      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :updated
        def health_check, do: :ok
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{module: @target_module, source: new_source},
                 %{}
               )

      assert result.loaded == true
      assert result.verification_passed == nil
      assert result.rolled_back == false

      target = Module.concat([Arbor.Actions.Code.HotLoadBehavioralTest.Target])
      assert target.value() == :updated
    end

    test "loads module with passing verification" do
      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :verified
        def health_check, do: :ok
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "#{@target_module}.health_check/0"
                 },
                 %{}
               )

      assert result.loaded == true
      assert result.verification_passed == true
      assert result.rolled_back == false

      target = Module.concat([Arbor.Actions.Code.HotLoadBehavioralTest.Target])
      assert target.value() == :verified
    end
  end

  describe "protected module rejection" do
    test "rejects Arbor.Security" do
      assert {:error, msg} =
               HotLoad.run(
                 %{module: "Arbor.Security", source: "defmodule Arbor.Security do end"},
                 %{}
               )

      assert msg =~ "protected module"
    end

    test "rejects Arbor.Security.Kernel" do
      assert {:error, msg} =
               HotLoad.run(
                 %{
                   module: "Arbor.Security.Kernel",
                   source: "defmodule Arbor.Security.Kernel do end"
                 },
                 %{}
               )

      assert msg =~ "protected module"
    end

    test "rejects Arbor.Persistence" do
      assert {:error, msg} =
               HotLoad.run(
                 %{module: "Arbor.Persistence", source: "defmodule Arbor.Persistence do end"},
                 %{}
               )

      assert msg =~ "protected module"
    end
  end

  describe "unknown module rejection" do
    test "rejects module whose atom does not exist" do
      # This module name has never been used as an atom, so SafeAtom.to_existing rejects it
      assert {:error, msg} =
               HotLoad.run(
                 %{
                   module:
                     "Arbor.Nonexistent.HotLoadTarget.#{System.unique_integer([:positive])}",
                   source: "defmodule Fake do end"
                 },
                 %{}
               )

      assert msg =~ "Hot-load failed"
    end
  end

  describe "verification failure and rollback" do
    test "rolls back when verification returns false" do
      target = Module.concat([Arbor.Actions.Code.HotLoadBehavioralTest.Target])
      assert target.value() == :original

      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :should_rollback
        def health_check, do: false
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "#{@target_module}.health_check/0"
                 },
                 %{}
               )

      assert result.loaded == true
      assert result.verification_passed == false
      assert result.rolled_back == true
      assert target.value() == :original
    end

    test "rolls back when verification returns {:error, reason}" do
      target = Module.concat([Arbor.Actions.Code.HotLoadBehavioralTest.Target])
      assert target.value() == :original

      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :should_rollback
        def health_check, do: {:error, :unhealthy}
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "#{@target_module}.health_check/0"
                 },
                 %{}
               )

      assert result.loaded == true
      assert result.verification_passed == false
      assert result.rolled_back == true
      assert target.value() == :original
    end

    test "rolls back when verification raises" do
      target = Module.concat([Arbor.Actions.Code.HotLoadBehavioralTest.Target])
      assert target.value() == :original

      new_source = ~s"""
      defmodule #{@target_fqn} do
        def value, do: :should_rollback
        def health_check, do: raise "boom"
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "#{@target_module}.health_check/0"
                 },
                 %{}
               )

      assert result.loaded == true
      assert result.verification_passed == false
      assert result.rolled_back == true
      assert target.value() == :original
    end

    test "rolls back on verification timeout" do
      target = Module.concat([Arbor.Actions.Code.HotLoadBehavioralTest.Target])
      assert target.value() == :original

      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :should_rollback
        def health_check do
          Process.sleep(:infinity)
          :ok
        end
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "#{@target_module}.health_check/0",
                   rollback_timeout_ms: 100
                 },
                 %{}
               )

      assert result.loaded == true
      assert result.verification_passed == false
      assert result.rolled_back == true
      assert result.output =~ "timed out"
      assert target.value() == :original
    end
  end

  describe "compilation errors" do
    test "returns error for invalid source code" do
      assert {:error, msg} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: "this is not valid elixir @@!!!"
                 },
                 %{}
               )

      assert msg =~ "Compilation error"
    end
  end

  describe "verify_fn format validation" do
    test "rejects invalid MFA format" do
      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :loaded
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "not_valid_mfa"
                 },
                 %{}
               )

      assert result.verification_passed == false
      assert result.rolled_back == true
    end

    test "rejects non-zero arity verification function" do
      new_source = """
      defmodule #{@target_fqn} do
        def value, do: :loaded
        def check(arg), do: arg
      end
      """

      assert {:ok, result} =
               HotLoad.run(
                 %{
                   module: @target_module,
                   source: new_source,
                   verify_fn: "#{@target_module}.check/1"
                 },
                 %{}
               )

      assert result.verification_passed == false
      assert result.rolled_back == true
    end
  end
end
