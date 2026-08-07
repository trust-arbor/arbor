defmodule Arbor.Actions.SessionLlmSkillsTest do
  @moduledoc """
  Guards that activated skills reach the LIVE heartbeat prompt.

  Audit finding F2: `Arbor.Agent.HeartbeatPrompt` (rich, offline-eval only) had
  self-knowledge, detected-patterns and active-skills sections that the live
  `SessionLlm.BuildPrompt` lacked — so the eval measured a prompt production
  never sees.

  Skills is the only one of those three with a live producer today. Before this,
  the live path surfaced them only as an `inspect/1` blob inside the generic
  working-memory dump: technically present, but unreadable and duplicated on
  every heartbeat.
  """

  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.SessionLlm.BuildPrompt

  @moduletag :fast

  defp heartbeat(wm) do
    {:ok, out} = BuildPrompt.run(%{mode: "heartbeat", working_memory: wm}, %{})
    out[:heartbeat_prompt]
  end

  describe "active skills in the heartbeat prompt" do
    test "renders name, description and body under their own heading" do
      prompt =
        heartbeat(%{
          active_skills: [
            %{
              name: "dot-authoring",
              description: "How to write pipelines",
              body: "Use exec nodes."
            }
          ]
        })

      assert prompt =~ "## Active Skills"
      assert prompt =~ "### dot-authoring"
      assert prompt =~ "How to write pipelines"
      assert prompt =~ "Use exec nodes."
    end

    test "accepts string-keyed skills from a JSON context round-trip" do
      # The engine context is a JSON checkpoint boundary, so skills can arrive
      # either way depending on whether a checkpoint was replayed.
      prompt =
        heartbeat(%{"active_skills" => [%{"name" => "json-skill", "body" => "from checkpoint"}]})

      assert prompt =~ "### json-skill"
      assert prompt =~ "from checkpoint"
    end

    test "skills are NOT also dumped into the working-memory blob" do
      prompt =
        heartbeat(%{active_skills: [%{name: "s", body: "B"}], focus: "shipping"})

      assert prompt =~ "### s"
      # The generic dump would render the skill list as inspect/1 output.
      refute prompt =~ ~s(active_skills:)
      refute prompt =~ ~s("active_skills")
      # Other working-memory keys still appear.
      assert prompt =~ "focus"
    end

    test "no skills means no section and no empty heading" do
      prompt = heartbeat(%{focus: "shipping"})

      refute prompt =~ "## Active Skills"
      assert prompt =~ "focus"
    end

    test "working memory holding ONLY skills emits no empty Working Memory heading" do
      prompt = heartbeat(%{active_skills: [%{name: "only", body: "b"}]})

      assert prompt =~ "## Active Skills"
      refute prompt =~ "## Working Memory"
    end

    test "a malformed skill entry does not break the prompt" do
      prompt = heartbeat(%{active_skills: [%{name: "good", body: "ok"}, "not-a-map", nil]})

      assert prompt =~ "### good"
      assert is_binary(prompt)
    end
  end

  describe "self-knowledge in the heartbeat prompt (F2)" do
    test "a summary is rendered under Self-Awareness" do
      {:ok, out} =
        BuildPrompt.run(
          %{mode: "heartbeat", self_knowledge: "Capable of tracing DOT pipelines."},
          %{}
        )

      assert out[:heartbeat_prompt] =~ "## Self-Awareness"
      assert out[:heartbeat_prompt] =~ "tracing DOT pipelines"
    end

    test "reads the session.-prefixed key heartbeat.dot supplies" do
      {:ok, out} =
        BuildPrompt.run(
          %{"session.self_knowledge" => "Prefers evidence.", mode: "heartbeat"},
          %{}
        )

      assert out[:heartbeat_prompt] =~ "Prefers evidence."
    end

    test "no self-knowledge means no empty heading" do
      {:ok, out} = BuildPrompt.run(%{mode: "heartbeat"}, %{})
      refute out[:heartbeat_prompt] =~ "## Self-Awareness"
    end
  end

  describe "detected patterns in the heartbeat prompt (F2)" do
    test "learning suggestions render with confidence" do
      {:ok, out} =
        BuildPrompt.run(
          %{
            mode: "heartbeat",
            background_suggestions: [
              %{type: :learning, content: "You read before you edit", confidence: 0.8}
            ]
          },
          %{}
        )

      assert out[:heartbeat_prompt] =~ "## Detected Action Patterns"
      assert out[:heartbeat_prompt] =~ "80% confidence"
      assert out[:heartbeat_prompt] =~ "You read before you edit"
    end

    test "only :learning suggestions are shown" do
      # The producer emits :insight and :preconscious too; those reach the agent
      # as proposals, not as observed-behaviour patterns.
      {:ok, out} =
        BuildPrompt.run(
          %{
            mode: "heartbeat",
            background_suggestions: [
              %{type: :insight, content: "unrelated insight"},
              %{type: :learning, content: "real pattern"}
            ]
          },
          %{}
        )

      assert out[:heartbeat_prompt] =~ "real pattern"
      refute out[:heartbeat_prompt] =~ "unrelated insight"
    end

    test "string-keyed suggestions from a checkpoint round-trip still render" do
      {:ok, out} =
        BuildPrompt.run(
          %{
            "session.background_suggestions" => [
              %{"type" => "learning", "content" => "from json", "confidence" => 0.5}
            ],
            mode: "heartbeat"
          },
          %{}
        )

      assert out[:heartbeat_prompt] =~ "from json"
    end

    test "no suggestions means no empty heading" do
      {:ok, out} = BuildPrompt.run(%{mode: "heartbeat", background_suggestions: []}, %{})
      refute out[:heartbeat_prompt] =~ "## Detected Action Patterns"
    end
  end
end
