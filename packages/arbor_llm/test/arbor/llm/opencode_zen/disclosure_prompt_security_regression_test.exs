defmodule Arbor.LLM.OpenCodeZen.DisclosurePromptSecurityRegressionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.LLM.OpenCodeZen
  alias Arbor.LLM.OpenCodeZen.Disclosure

  @moduletag :fast
  @moduletag :security_regression

  defmodule YesPrompt do
    @behaviour Arbor.LLM.Contracts.DisclosurePrompt

    @impl true
    def info(text) do
      send(self(), {:prompt_info, text})
      :ok
    end

    @impl true
    def yes?(question) do
      send(self(), {:prompt_question, question})
      true
    end
  end

  defmodule NoPrompt do
    @behaviour Arbor.LLM.Contracts.DisclosurePrompt

    @impl true
    defdelegate info(text), to: YesPrompt

    @impl true
    def yes?(question) do
      send(self(), {:prompt_question, question})
      false
    end
  end

  defmodule IncompletePrompt do
    def info(text) do
      send(self(), {:incomplete_prompt_info, text})
      :ok
    end
  end

  defmodule RaisingPrompt do
    def info(_text), do: raise("prompt unavailable")
    def yes?(_question), do: true
  end

  defmodule ExitingPrompt do
    def info(_text), do: exit(:prompt_unavailable)
    def yes?(_question), do: true
  end

  defmodule MalformedInfoPrompt do
    def info(_text), do: :unexpected
    def yes?(_question), do: true
  end

  defmodule MalformedYesPrompt do
    def info(_text), do: :ok
    def yes?(_question), do: :unexpected
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-disclosure-prompt-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    ack_path = Path.join(root, "acknowledgement.json")

    previous =
      Map.new([:disclosure_prompt, :opencode_zen_acknowledgement_path], fn key ->
        {key, Application.fetch_env(:arbor_llm, key)}
      end)

    Application.put_env(:arbor_llm, :opencode_zen_acknowledgement_path, ack_path)
    Application.delete_env(:arbor_llm, :disclosure_prompt)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, ack_path: ack_path}
  end

  test "security regression: missing prompt cannot print or acknowledge through a yes override",
       %{
         ack_path: ack_path
       } do
    yes? = fn ->
      send(self(), :yes_override_called)
      true
    end

    output =
      capture_io(fn ->
        assert OpenCodeZen.prompt_acknowledgement(yes_fn: yes?) ==
                 {:error, :disclosure_not_acknowledged}
      end)

    assert output == ""
    refute_receive :yes_override_called
    refute File.exists?(ack_path)
    assert Disclosure.ensure() == {:error, :disclosure_not_acknowledged}
  end

  test "security regression: incomplete prompt is rejected before its display callback", %{
    ack_path: ack_path
  } do
    Application.put_env(:arbor_llm, :disclosure_prompt, IncompletePrompt)

    assert OpenCodeZen.prompt_acknowledgement(yes_fn: fn -> true end) ==
             {:error, :disclosure_not_acknowledged}

    refute_receive {:incomplete_prompt_info, _}
    refute File.exists?(ack_path)
  end

  test "security regression: unavailable and malformed prompt callbacks cannot persist an ACK", %{
    root: root
  } do
    providers = [
      __MODULE__.UnavailablePrompt,
      RaisingPrompt,
      ExitingPrompt,
      MalformedInfoPrompt,
      MalformedYesPrompt
    ]

    for {provider, index} <- Enum.with_index(providers) do
      ack_path = Path.join(root, "refused-#{index}.json")
      Application.put_env(:arbor_llm, :opencode_zen_acknowledgement_path, ack_path)
      Application.put_env(:arbor_llm, :disclosure_prompt, provider)

      assert OpenCodeZen.prompt_acknowledgement() == {:error, :disclosure_not_acknowledged}
      refute File.exists?(ack_path)
    end
  end

  test "explicit host yes preserves disclosure text, question and version-one ACK", %{
    ack_path: ack_path
  } do
    Application.put_env(:arbor_llm, :disclosure_prompt, YesPrompt)
    at = "2026-10-31T00:00:00Z"

    assert OpenCodeZen.prompt_acknowledgement(now: at) == :ok
    assert_receive {:prompt_info, ""}
    text = OpenCodeZen.disclosure_text()
    assert_receive {:prompt_info, ^text}
    assert_receive {:prompt_question, "Do you acknowledge this and want to continue?"}

    assert JSON.decode!(File.read!(ack_path)) == %{
             "acknowledged" => true,
             "at" => at,
             "version" => 1
           }

    assert Disclosure.ensure() == :ok
  end

  test "an explicit host decline leaves the disclosure unacknowledged", %{ack_path: ack_path} do
    Application.put_env(:arbor_llm, :disclosure_prompt, NoPrompt)

    assert OpenCodeZen.prompt_acknowledgement() == {:error, :disclosure_not_acknowledged}
    assert_receive {:prompt_question, "Do you acknowledge this and want to continue?"}
    refute File.exists?(ack_path)
  end

  test "the existing yes override replaces only the configured provider question", %{
    ack_path: ack_path
  } do
    Application.put_env(:arbor_llm, :disclosure_prompt, NoPrompt)

    yes? = fn ->
      send(self(), :yes_override_called)
      true
    end

    assert OpenCodeZen.prompt_acknowledgement(yes_fn: yes?) == :ok
    assert_receive {:prompt_info, ""}
    text = OpenCodeZen.disclosure_text()
    assert_receive {:prompt_info, ^text}
    assert_receive :yes_override_called
    refute_receive {:prompt_question, _}
    assert File.regular?(ack_path)
  end

  test "an existing valid ACK needs no prompt and is not rewritten", %{ack_path: ack_path} do
    assert Disclosure.persist("2026-10-31T00:00:00Z") == :ok
    before = File.read!(ack_path)

    assert OpenCodeZen.prompt_acknowledgement() == :ok
    assert File.read!(ack_path) == before
  end
end
