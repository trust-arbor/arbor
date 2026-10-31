defmodule Arbor.Commands.LLM.DisclosurePromptCompositionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.LLM.DisclosurePrompt
  alias Arbor.Common.SafePath
  alias Arbor.LLM.Config
  alias Arbor.LLM.OpenCodeZen.Disclosure

  @moduletag :fast
  @moduletag :security_regression

  setup do
    # Missing Root composition is a failed precondition, never a fake default.
    selected = Application.fetch_env!(:arbor_llm, :disclosure_prompt)
    assert selected == DisclosurePrompt
    assert Config.disclosure_prompt() == selected
    assert Application.get_application(selected) == :arbor_commands

    previous_shell = Mix.shell()

    previous =
      Map.new([:disclosure_prompt, :opencode_zen_acknowledgement_path], fn key ->
        {key, Application.fetch_env(:arbor_llm, key)}
      end)

    root =
      Path.join(
        System.tmp_dir!(),
        "llm-product-disclosure-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      )

    File.mkdir!(root)

    on_exit(fn ->
      try do
        Enum.each(previous, fn {key, value} -> restore(key, value) end)
        Mix.shell(previous_shell)
      after
        File.rm_rf!(root)
      end
    end)

    File.chmod!(root, 0o700)
    {:ok, canonical_root} = SafePath.resolve_real(root)
    ack_path = Path.join(canonical_root, "acknowledgement.json")
    Application.put_env(:arbor_llm, :opencode_zen_acknowledgement_path, ack_path)
    Mix.shell(Mix.Shell.Process)
    %{ack_path: ack_path, app: Mix.Project.config()[:app]}
  end

  test "security regression: Root-selected Commands prompt requires actual shell yes before persisting a private ACK",
       ctx do
    at = "2026-10-31T00:00:00Z"
    refute File.exists?(ctx.ack_path)
    send(self(), {:mix_shell_input, :yes?, true})

    assert Disclosure.prompt(now: at) == :ok

    assert prompt_messages(ctx.app) == [
             {:mix_shell, :info, [""]},
             {:mix_shell, :info, [Disclosure.text()]},
             {:mix_shell, :yes?, ["Do you acknowledge this and want to continue?"]}
           ]

    refute_received {:mix_shell_input, :yes?, _}

    assert JSON.decode!(File.read!(ctx.ack_path)) == %{
             "acknowledged" => true,
             "at" => at,
             "version" => 1
           }

    assert Disclosure.ensure() == :ok
  end

  test "security regression: Root-selected Commands prompt preserves actual shell refusal without an ACK",
       ctx do
    refute File.exists?(ctx.ack_path)
    send(self(), {:mix_shell_input, :yes?, false})

    assert Disclosure.prompt() == {:error, :disclosure_not_acknowledged}

    assert prompt_messages(ctx.app) == [
             {:mix_shell, :info, [""]},
             {:mix_shell, :info, [Disclosure.text()]},
             {:mix_shell, :yes?, ["Do you acknowledge this and want to continue?"]}
           ]

    refute_received {:mix_shell_input, :yes?, _}
    refute File.exists?(ctx.ack_path)
    assert Disclosure.ensure() == {:error, :disclosure_not_acknowledged}
  end

  defp prompt_messages(app) do
    # Mix may print its ordinary application heading before prompt callbacks.
    # Only that exact framework heading is excluded from the interaction oracle.
    heading = {:mix_shell, :info, ["==> #{app}"]}
    collect_messages([]) |> Enum.reject(&(&1 == heading))
  end

  defp collect_messages(acc) do
    receive do
      {:mix_shell, _kind, _payload} = message -> collect_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:arbor_llm, key, value)
  defp restore(key, :error), do: Application.delete_env(:arbor_llm, key)
end
