defmodule Arbor.KernelRuntime.ProviderGateSDKPathSecurityRegressionTest do
  @moduledoc """
  Security regression: normal OTP os_mon remains dynamically admitted after
  ordinary Mix removes its path. No provider is added to the application spec.
  """
  use ExUnit.Case, async: false

  # ExUnit's :tmp_dir tag writes inside the repository, which is read-only under
  # contained validation. Allocate a private root under the system tmp dir and
  # resolve it to its physical path.
  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-sdk-path-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root = File.cd!(root, &File.cwd!/0)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, tmp_dir: root}
  end

  alias Arbor.KernelRuntime.ApplicationSpecPeer
  alias Arbor.KernelRuntime.BootProfileBinding
  alias Arbor.KernelRuntime.ProviderGate

  @provider_roots [:os_mon, :recon, :mint, :finch, :req]

  @tag :slow
  @tag :integration
  @tag :security_regression
  test "security regression: admitted full gate restores only pruned normal OTP os_mon" do
    control = ApplicationSpecPeer.start!()

    try do
      prepare_bound_peer!(control)

      refute :os_mon in ApplicationSpecPeer.loaded_applications(control)
      refute :os_mon in ApplicationSpecPeer.started_applications(control)
      os_mon_dir = call(control, :code, :lib_dir, [:os_mon])
      assert is_list(os_mon_dir)
      ebin = os_mon_dir |> List.to_string() |> Path.join("ebin") |> String.to_charlist()
      assert true == call(control, :code, :del_path, [ebin])
      assert {:error, :bad_name} == call(control, :code, :lib_dir, [:os_mon])
      before_paths = call(control, :code, :get_path, [])

      assert {:ok, gate} =
               start_gate(control)

      assert is_pid(gate)
      assert call(control, :code, :get_path, []) == before_paths ++ [ebin]

      assert Enum.all?(
               @provider_roots,
               &(&1 in ApplicationSpecPeer.started_applications(control))
             )

      assert call(control, Process, :whereis, [ProviderGate]) == gate
    after
      ApplicationSpecPeer.stop(control)
    end
  end

  @tag :slow
  @tag :integration
  @tag :security_regression
  test "security regression: flat selected app resource retains its original failure", %{
    tmp_dir: root
  } do
    control = ApplicationSpecPeer.start!()

    try do
      prepare_bound_peer!(control)
      os_mon_dir = call(control, :code, :lib_dir, [:os_mon])
      assert is_list(os_mon_dir)
      sdk_ebin = os_mon_dir |> List.to_string() |> Path.join("ebin") |> String.to_charlist()
      assert true == call(control, :code, :del_path, [sdk_ebin])
      flat = Path.join(root, "flat-provider-resource")
      File.mkdir!(flat)
      selected = Path.join(flat, "os_mon.app")
      File.write!(selected, "not a valid application resource")
      assert true == call(control, :code, :add_patha, [String.to_charlist(flat)])
      assert {:error, :bad_name} == call(control, :code, :lib_dir, [:os_mon])

      assert call(control, :code, :where_is_file, [~c"os_mon.app"]) ==
               String.to_charlist(selected)

      before_paths = call(control, :code, :get_path, [])

      assert {:error, expected_reason} =
               call(control, Application, :ensure_all_started, [:os_mon])

      assert {:error, {:provider_start_failed, :os_mon, ^expected_reason}} =
               start_gate(control)

      assert call(control, :code, :get_path, []) == before_paths
      refute sdk_ebin in call(control, :code, :get_path, [])
      refute :os_mon in ApplicationSpecPeer.started_applications(control)
    after
      ApplicationSpecPeer.stop(control)
    end
  end

  # The peer RPC worker must receive start_link's real error return instead of
  # dying from the linked init exit. A successful Gate outlives that worker.
  defp start_gate(control) do
    opts = [name: ProviderGate, roots: @provider_roots]

    {result, [opts: ^opts]} =
      call(control, Code, :eval_string, [
        """
        Process.flag(:trap_exit, true)

        case Arbor.KernelRuntime.ProviderGate.start_link(opts) do
          {:ok, pid} = result ->
            Process.unlink(pid)
            result

          result ->
            result
        end
        """,
        [opts: opts]
      ])

    result
  end

  defp prepare_bound_peer!(control) do
    build = Mix.Project.build_path()
    :ok = ApplicationSpecPeer.prepare_restricted!(control, :arbor_kernel_runtime, [], build)

    for app <- [:recon, :mint, :finch, :req] do
      :ok = ApplicationSpecPeer.prepare_restricted!(control, app, [], build)
    end

    :ok = ApplicationSpecPeer.copy_selected_env!(control, :arbor_kernel, [:kernel_runtime])
    :ok = ApplicationSpecPeer.put_activation_profile(control, start_profile: :full)
    assert {:ok, _} = call(control, Application, :ensure_all_started, [:crypto])
    assert {:ok, _binding} = call(control, BootProfileBinding, :start_link, [[]])
    assert {:ok, _snapshot} = call(control, Arbor.KernelRuntime, :boot_profile, [])
  end

  defp call(control, module, function, args),
    do: ApplicationSpecPeer.call(control, module, function, args)
end
