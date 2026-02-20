defmodule Arbor.Actions.TaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Taint

  @moduletag :fast

  # A mock module with taint_roles defined
  defmodule MockActionWithRoles do
    def taint_roles do
      %{
        path: :control,
        command: :control,
        content: :data,
        timeout: :data
      }
    end
  end

  # A mock module without taint_roles
  defmodule MockActionWithoutRoles do
    def run(_params, _context), do: {:ok, %{}}
  end

  describe "roles_for/1" do
    test "returns roles from module with taint_roles/0" do
      roles = Taint.roles_for(MockActionWithRoles)

      assert roles == %{
               path: :control,
               command: :control,
               content: :data,
               timeout: :data
             }
    end

    test "returns empty map for module without taint_roles/0" do
      roles = Taint.roles_for(MockActionWithoutRoles)

      assert roles == %{}
    end

    test "returns roles from Shell.Execute action" do
      roles = Taint.roles_for(Arbor.Actions.Shell.Execute)

      assert roles.command == {:control, requires: [:command_injection]}
      assert roles.cwd == {:control, requires: [:path_traversal]}
      assert roles.sandbox == :control
      assert roles.env == :data
      assert roles.timeout == :data
    end

    test "returns roles from File.Read action" do
      roles = Taint.roles_for(Arbor.Actions.File.Read)

      assert roles.path == {:control, requires: [:path_traversal]}
      assert roles.encoding == :data
    end

    test "returns roles from File.Write action" do
      roles = Taint.roles_for(Arbor.Actions.File.Write)

      assert roles.path == {:control, requires: [:path_traversal]}
      assert roles.mode == :control
      assert roles.content == :data
      assert roles.create_dirs == :data
    end
  end

  describe "check_params/3 with nil context" do
    test "returns :ok when context is nil" do
      result = Taint.check_params(MockActionWithRoles, %{command: "ls"}, nil)

      assert result == :ok
    end
  end

  describe "check_params/3 with missing taint" do
    test "returns :ok when taint_context has no :taint key" do
      result = Taint.check_params(MockActionWithRoles, %{command: "ls"}, %{})

      assert result == :ok
    end
  end

  describe "check_params/3 with trusted taint" do
    test "trusted passes for control params" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{path: "/etc/passwd", command: "rm -rf /"},
          %{taint: :trusted}
        )

      assert result == :ok
    end

    test "trusted passes for data params" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{content: "malicious content"},
          %{taint: :trusted}
        )

      assert result == :ok
    end
  end

  describe "check_params/3 with derived taint" do
    test "derived passes for control params (audited but not blocked)" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{path: "/tmp/file", command: "echo hello"},
          %{taint: :derived}
        )

      assert result == :ok
    end

    test "derived passes for data params" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{content: "some content"},
          %{taint: :derived}
        )

      assert result == :ok
    end
  end

  describe "check_params/3 with untrusted taint" do
    test "untrusted is BLOCKED for control params" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{command: "rm -rf /"},
          %{taint: :untrusted}
        )

      assert result == {:error, {:taint_blocked, :command, :untrusted, :control}}
    end

    test "untrusted passes for data params" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{content: "user input", timeout: 5000},
          %{taint: :untrusted}
        )

      assert result == :ok
    end

    test "reports first blocked control param" do
      # path is also control, so one of them should be reported
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{path: "/etc/passwd", command: "ls", content: "data"},
          %{taint: :untrusted}
        )

      assert {:error, {:taint_blocked, param, :untrusted, :control}} = result
      assert param in [:path, :command]
    end
  end

  describe "check_params/3 with hostile taint" do
    test "hostile is BLOCKED for control params" do
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{command: "malicious"},
          %{taint: :hostile}
        )

      assert result == {:error, {:taint_blocked, :command, :hostile, :control}}
    end

    test "hostile is BLOCKED even for data params when they're present with control params" do
      # Since the params map includes a control param, hostile will block it
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{path: "/tmp", content: "data"},
          %{taint: :hostile}
        )

      assert result == {:error, {:taint_blocked, :path, :hostile, :control}}
    end

    test "hostile passes for data-only params (no control params in request)" do
      # When only data params are provided, hostile data still passes
      # because data params don't check can_use_as?(hostile, data) here
      # Actually, hostile data should fail... let me check the logic
      # The check_params only checks control params, so data-only is :ok
      result =
        Taint.check_params(
          MockActionWithRoles,
          %{content: "hostile data", timeout: 1000},
          %{taint: :hostile}
        )

      # This returns :ok because we only check control params
      # Hostile data blocking would be done at a different layer
      assert result == :ok
    end
  end

  describe "check_params/3 with module without taint_roles" do
    test "all params pass when module has no taint_roles" do
      result =
        Taint.check_params(
          MockActionWithoutRoles,
          %{anything: "goes", dangerous: "command"},
          %{taint: :untrusted}
        )

      assert result == :ok
    end
  end

  describe "allowed?/2" do
    test "control + trusted = true" do
      assert Taint.allowed?(:control, :trusted)
    end

    test "control + derived = true" do
      assert Taint.allowed?(:control, :derived)
    end

    test "control + untrusted = false" do
      refute Taint.allowed?(:control, :untrusted)
    end

    test "control + hostile = false" do
      refute Taint.allowed?(:control, :hostile)
    end

    test "data + trusted = true" do
      assert Taint.allowed?(:data, :trusted)
    end

    test "data + derived = true" do
      assert Taint.allowed?(:data, :derived)
    end

    test "data + untrusted = true" do
      assert Taint.allowed?(:data, :untrusted)
    end

    test "data + hostile = true (data params don't restrict taint level)" do
      # Data roles are unrestricted — hostile data can still be processed as content.
      # The taint level restriction only applies to control roles.
      assert Taint.allowed?(:data, :hostile)
    end
  end

  describe "integration with real actions" do
    test "Shell.Execute blocks untrusted command" do
      result =
        Taint.check_params(
          Arbor.Actions.Shell.Execute,
          %{command: "rm -rf /", cwd: "/tmp"},
          %{taint: :untrusted}
        )

      assert {:error, {:taint_blocked, param, :untrusted, :control}} = result
      assert param in [:command, :cwd]
    end

    test "File.Write blocks untrusted path" do
      result =
        Taint.check_params(
          Arbor.Actions.File.Write,
          %{path: "/etc/passwd", content: "malicious"},
          %{taint: :untrusted}
        )

      assert {:error, {:taint_blocked, param, :untrusted, :control}} = result
      assert param in [:path, :mode]
    end

    test "File.Write with atom taint fails closed on sanitization requirements" do
      # Legacy atom taint `:trusted` passes the level check but fails closed
      # on sanitization requirements — no bitmask means no evidence of sanitization
      result =
        Taint.check_params(
          Arbor.Actions.File.Write,
          %{path: "/etc/passwd", content: "malicious"},
          %{taint: :trusted}
        )

      assert {:error, {:missing_sanitization, :path, [:path_traversal]}} = result
    end

    test "File.Write allows trusted struct taint with path_traversal sanitization" do
      # Struct taint with the correct sanitization bit set passes
      {:ok, bit} = Arbor.Contracts.Security.Taint.sanitization_bit(:path_traversal)

      taint = %Arbor.Contracts.Security.Taint{
        level: :trusted,
        sanitizations: bit
      }

      result =
        Taint.check_params(
          Arbor.Actions.File.Write,
          %{path: "/safe/path", content: "data"},
          %{taint: taint}
        )

      assert result == :ok
    end
  end

  # ============================================================================
  # Extended taint roles with sanitization requirements
  # ============================================================================

  # A mock module with extended taint roles
  defmodule MockActionWithSanitizationReqs do
    def taint_roles do
      %{
        command: {:control, requires: [:command_injection]},
        path: {:control, requires: [:path_traversal]},
        url: {:control, requires: [:ssrf]},
        multi: {:control, requires: [:command_injection, :path_traversal]},
        bare_control: :control,
        content: :data
      }
    end
  end

  describe "allowed?/2 with extended roles" do
    test "tuple control + trusted = true" do
      assert Taint.allowed?({:control, requires: [:command_injection]}, :trusted)
    end

    test "tuple control + derived = true" do
      assert Taint.allowed?({:control, requires: [:ssrf]}, :derived)
    end

    test "tuple control + untrusted = false" do
      refute Taint.allowed?({:control, requires: [:command_injection]}, :untrusted)
    end

    test "tuple control + hostile = false" do
      refute Taint.allowed?({:control, requires: [:xss]}, :hostile)
    end
  end

  describe "required_sanitizations/1" do
    test "returns empty for :data" do
      assert Taint.required_sanitizations(:data) == []
    end

    test "returns empty for bare :control" do
      assert Taint.required_sanitizations(:control) == []
    end

    test "returns required sanitizers for tuple control" do
      assert Taint.required_sanitizations({:control, requires: [:command_injection]}) == [
               :command_injection
             ]
    end

    test "returns multiple required sanitizers" do
      assert Taint.required_sanitizations({:control, requires: [:xss, :sqli]}) == [:xss, :sqli]
    end

    test "returns empty when no requires key" do
      assert Taint.required_sanitizations({:control, []}) == []
    end
  end

  describe "check_sanitizations/2" do
    test "returns ok when no requirements" do
      assert Taint.check_sanitizations(:control, %{sanitizations: 0}) == {:ok, []}
    end

    test "returns ok when no requirements for data" do
      assert Taint.check_sanitizations(:data, %{sanitizations: 0}) == {:ok, []}
    end

    test "returns ok when required sanitization bit is set" do
      # command_injection is bit 2 (0b00000100 = 4)
      taint = %Arbor.Contracts.Security.Taint{sanitizations: 4}
      role = {:control, requires: [:command_injection]}

      assert Taint.check_sanitizations(role, taint) == {:ok, []}
    end

    test "returns error when required sanitization bit is missing" do
      taint = %Arbor.Contracts.Security.Taint{sanitizations: 0}
      role = {:control, requires: [:command_injection]}

      assert Taint.check_sanitizations(role, taint) == {:error, [:command_injection]}
    end

    test "returns missing sanitizations for multiple requirements" do
      # command_injection = bit 2 (4), path_traversal = bit 3 (8)
      # Only command_injection is set
      taint = %Arbor.Contracts.Security.Taint{sanitizations: 4}
      role = {:control, requires: [:command_injection, :path_traversal]}

      assert Taint.check_sanitizations(role, taint) == {:error, [:path_traversal]}
    end

    test "returns ok when all multiple requirements met" do
      # command_injection (4) + path_traversal (8) = 12
      taint = %Arbor.Contracts.Security.Taint{sanitizations: 12}
      role = {:control, requires: [:command_injection, :path_traversal]}

      assert Taint.check_sanitizations(role, taint) == {:ok, []}
    end

    test "fails closed for legacy atom taint when requirements exist" do
      # Legacy atom taint has no bitmask — can't verify sanitization was applied.
      # Fail closed: treat all requirements as unmet.
      role = {:control, requires: [:command_injection]}

      assert Taint.check_sanitizations(role, :trusted) == {:error, [:command_injection]}
    end
  end

  describe "check_params/3 with struct taint" do
    test "trusted struct taint with missing sanitization is blocked" do
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{command: "ls"},
          %{taint: taint}
        )

      assert {:error, {:missing_sanitization, :command, [:command_injection]}} = result
    end

    test "trusted struct taint with correct sanitization passes" do
      # command_injection = bit 2 (4)
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 4}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{command: "ls"},
          %{taint: taint}
        )

      assert result == :ok
    end

    test "untrusted struct taint blocks on level before sanitization check" do
      taint = %Arbor.Contracts.Security.Taint{level: :untrusted, sanitizations: 4}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{command: "ls"},
          %{taint: taint}
        )

      assert {:error, {:taint_blocked, :command, :untrusted, :control}} = result
    end

    test "bare control param with struct taint checks level only" do
      # bare_control has no sanitization requirements
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{bare_control: "value"},
          %{taint: taint}
        )

      assert result == :ok
    end

    test "data param with struct taint always passes" do
      taint = %Arbor.Contracts.Security.Taint{level: :hostile, sanitizations: 0}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{content: "anything"},
          %{taint: taint}
        )

      assert result == :ok
    end

    test "multiple sanitization requirements with partial set" do
      # multi requires both :command_injection and :path_traversal
      # Only command_injection (4) is set, path_traversal (8) is missing
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 4}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{multi: "value"},
          %{taint: taint}
        )

      assert {:error, {:missing_sanitization, :multi, [:path_traversal]}} = result
    end

    test "multiple sanitization requirements all met" do
      # command_injection (4) + path_traversal (8) = 12
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 12}

      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{multi: "value"},
          %{taint: taint}
        )

      assert result == :ok
    end
  end

  describe "check_params/3 backward compatibility" do
    test "legacy atom taint fails closed when role has sanitization requirements" do
      # Legacy atom :trusted has no bitmask — can't verify sanitization.
      # Fail closed: missing_sanitization error.
      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{command: "ls"},
          %{taint: :trusted}
        )

      assert {:error, {:missing_sanitization, :command, [:command_injection]}} = result
    end

    test "legacy atom taint passes for bare control roles (no requirements)" do
      # bare_control has no sanitization requirements — atom taint is fine
      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{bare_control: "value"},
          %{taint: :trusted}
        )

      assert result == :ok
    end

    test "legacy atom taint passes for data roles" do
      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{content: "anything"},
          %{taint: :trusted}
        )

      assert result == :ok
    end

    test "legacy atom taint blocks on level before sanitization check" do
      result =
        Taint.check_params(
          MockActionWithSanitizationReqs,
          %{command: "ls"},
          %{taint: :untrusted}
        )

      assert {:error, {:taint_blocked, :command, :untrusted, :control}} = result
    end
  end

  describe "integration with real actions using struct taint" do
    test "Shell.Execute requires command_injection sanitization" do
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}

      result =
        Taint.check_params(
          Arbor.Actions.Shell.Execute,
          %{command: "ls"},
          %{taint: taint}
        )

      assert {:error, {:missing_sanitization, :command, [:command_injection]}} = result
    end

    test "Shell.Execute passes with command_injection sanitization" do
      # command_injection = bit 2 (4)
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 4}

      result =
        Taint.check_params(
          Arbor.Actions.Shell.Execute,
          %{command: "ls"},
          %{taint: taint}
        )

      assert result == :ok
    end

    test "Shell.Execute cwd requires path_traversal sanitization" do
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}

      result =
        Taint.check_params(
          Arbor.Actions.Shell.Execute,
          %{cwd: "/tmp"},
          %{taint: taint}
        )

      assert {:error, {:missing_sanitization, :cwd, [:path_traversal]}} = result
    end

    test "File.Read requires path_traversal sanitization" do
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}

      result =
        Taint.check_params(
          Arbor.Actions.File.Read,
          %{path: "/etc/hosts"},
          %{taint: taint}
        )

      assert {:error, {:missing_sanitization, :path, [:path_traversal]}} = result
    end

    test "File.Read passes with path_traversal sanitization" do
      # path_traversal = bit 3 (8)
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 8}

      result =
        Taint.check_params(
          Arbor.Actions.File.Read,
          %{path: "/etc/hosts"},
          %{taint: taint}
        )

      assert result == :ok
    end

    test "Web.Browse requires ssrf sanitization" do
      taint = %Arbor.Contracts.Security.Taint{level: :trusted, sanitizations: 0}

      result =
        Taint.check_params(
          Arbor.Actions.Web.Browse,
          %{url: "http://example.com"},
          %{taint: taint}
        )

      assert {:error, {:missing_sanitization, :url, [:ssrf]}} = result
    end
  end
end
