defmodule Arbor.Agent.Behavioral.SkillActivationE2ETest do
  @moduledoc """
  End-to-end behavioral test for the skill-activation pathway.

  Exercises the full non-LLM path that a user-activated skill takes:

      .arbor/skills/<skill>/SKILL.md
              ↓ (loaded by)
          SkillLibrary
              ↓ (fetched by)
      Arbor.Actions.Skill.Activate.run/2 (Jido action)
              ↓ (persists to)
          Arbor.Memory working memory
              ↓ (read back by)
      Arbor.Agent.HeartbeatPrompt.build_prompt/1
              ↓ (rendered into)
          user-bound prompt section "## Active Skills"

  Before the fix, the last step in that chain was broken: HeartbeatPrompt
  never read working_memory.active_skills, so the skill body silently
  failed to reach the LLM. This test asserts the whole round trip against
  a real skill loaded from `.arbor/skills/` — not a synthetic fixture —
  so any regression along the chain (action runtime breaking, working
  memory init regressing, prompt builder dropping the section, etc.) is
  caught.

  LLM-side verification (does the agent actually *act* on the skill
  content?) requires a live LLM call and is left to a separate
  `:llm`-tagged test or manual smoke. The brainstorming doc treats the
  integration-level assertion (skill body reaches the prompt) as the
  minimum bar; this file delivers it.

  See: `.arbor/roadmap/1-brainstorming/skill-prompt-injection-and-activation-gap.md`
  """

  use Arbor.Test.BehavioralCase, async: false

  @moduletag :integration

  alias Arbor.Agent.HeartbeatPrompt
  alias Arbor.Common.SkillLibrary
  alias Arbor.Memory

  # ETS tables the heartbeat-prompt path can read from. Same set as
  # memory_e2e_test; keeps the test isolated from other suites.
  @extra_ets_tables [
    :arbor_memory_thinking,
    :arbor_memory_goals,
    :arbor_memory_intents,
    :arbor_memory_code_store,
    :arbor_self_knowledge,
    :arbor_identity_rate_limits,
    :arbor_consolidation_state,
    :arbor_reflections,
    :arbor_preconscious_config
  ]

  # A real skill from `.arbor/skills/`. Chosen because it's user-facing,
  # has a non-trivial body, and isn't a system-level heartbeat skill (so
  # placing it in the system prompt would be wrong — letting us also
  # confirm placement). If this skill is ever renamed or removed, the
  # test should be updated to point at another stable real skill.
  @test_skill_name "frontend-design"

  # Committed test fixtures (copies of the real skills, incl. frontend-design).
  # NOT the live `.arbor/skills/` dir — that is gitignored and therefore absent
  # in fresh checkouts / CI / worktrees, which made SkillLibrary.get/1 below
  # return {:error, :not_found}. Matches the fixtures pattern prompt_library_test.exs uses.
  @skills_dir Path.expand("../fixtures/skills", __DIR__)

  setup %{agent_id: agent_id} do
    for table <- @extra_ets_tables do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    # Prime the SkillLibrary with the on-disk skill directory. Required
    # because BehavioralCase starts the app supervision tree but doesn't
    # point SkillLibrary at the umbrella's skills dir. Mirrors the setup
    # pattern used in apps/arbor_agent/test/integration/prompt_library_test.exs.
    if Process.whereis(SkillLibrary) do
      GenServer.stop(SkillLibrary)
      Process.sleep(10)
    end

    if :ets.whereis(:arbor_skill_library) != :undefined do
      :ets.delete(:arbor_skill_library)
    end

    {:ok, _pid} = SkillLibrary.start_link(dirs: [@skills_dir])

    # SkillLibrary's init/1 sends itself a :scan_dirs message and returns
    # before indexing — fine for production supervision but races the
    # test. A synchronous reload forces the index to complete before we
    # proceed.
    :ok = SkillLibrary.reload()

    Memory.init_for_agent(agent_id, index_enabled: false, graph_enabled: false)

    on_exit(fn ->
      try do
        Memory.cleanup_for_agent(agent_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "skill activation reaches the heartbeat prompt (regression)" do
    test "activation-gap E2E: real skill activated through the action runtime appears in the heartbeat prompt",
         %{agent_id: agent_id} do
      # 1. Real skill loaded from the on-disk library.
      {:ok, skill} = SkillLibrary.get(@test_skill_name)

      assert is_binary(skill.body) and skill.body != "",
             "Test fixture invariant: skill #{@test_skill_name} should have a non-empty body. " <>
               "If this skill was removed or restructured, pick a different real skill."

      # 2. Activate it through Arbor.Actions.Skill.Activate.run/2 — the
      #    real entry point an agent would use. We're testing the chain,
      #    not bypassing it to WorkingMemory.activate_skill directly.
      assert {:ok, %{activated: true, name: @test_skill_name}} =
               Arbor.Actions.Skill.Activate.run(
                 %{skill_name: @test_skill_name},
                 %{agent_id: agent_id}
               )

      # 3. Confirm the skill landed in working memory. If this assertion
      #    fails the bug is upstream (action layer / memory layer), not
      #    in the prompt builder.
      wm = Memory.get_working_memory(agent_id)

      assert is_struct(wm),
             "Memory.get_working_memory/1 should return a WorkingMemory struct after init_for_agent"

      assert Enum.any?(wm.active_skills, &(&1.name == @test_skill_name)),
             "Skill.Activate should have added #{@test_skill_name} to working memory; " <>
               "found: #{inspect(Enum.map(wm.active_skills, & &1.name))}"

      # 4. Build a heartbeat prompt. State mirrors what AgentSeed /
      #    Heartbeat would assemble for a real cycle.
      state = %{
        id: agent_id,
        agent_id: agent_id,
        cognitive_mode: :consolidation,
        enabled_prompt_sections: :all,
        pending_messages: [],
        background_suggestions: [],
        context_window: nil
      }

      prompt = HeartbeatPrompt.build_prompt(state)

      # 5. The skill's body must appear in the user prompt. This is the
      #    bug the brainstorming doc named — Skill.Activate writes,
      #    nobody reads. If this fails the chain is silently broken even
      #    though every individual step worked.
      assert prompt =~ skill.body,
             """
             ACTIVATION GAP E2E REGRESSION

             Skill `#{@test_skill_name}` was activated through
             Arbor.Actions.Skill.Activate, landed in working memory, but
             its body did not appear in the heartbeat prompt produced by
             HeartbeatPrompt.build_prompt.

             This is the bug captured in:
             .arbor/roadmap/1-brainstorming/skill-prompt-injection-and-activation-gap.md

             Either:
             - The :active_skills section is missing from @prompt_sections
             - active_skills_section/1 isn't reading the agent's working memory
             - The section is filtered out before render

             The whole point of this test is to catch any regression along
             that chain in CI rather than discovering it via a silent
             "the LLM doesn't seem to know about my skill" report later.
             """

      # 6. Identifying markers — section header + skill name in the
      #    rendered section. Together with assertion #5 these prove the
      #    fix's rendering path (not just that the body happens to
      #    appear somewhere by accident).
      assert prompt =~ "## Active Skills",
             "Expected the 'Active Skills' section header in the user prompt"

      assert prompt =~ "### #{@test_skill_name}",
             "Expected the skill's name as a subsection header"
    end

    test "activating a skill records a durable :skill_activated usage event",
         %{agent_id: agent_id} do
      # skill-subsystem-audit 2026-07-04 G3: activations recorded no usable usage signal, so the
      # library was write-only and could never measure reuse or prune. Activate now emits a dedicated
      # :skill/:skill_activated event. :skill is not a restricted topic, so the payload is retained
      # (not encrypted/redacted). This fails on the pre-fix code (no such event).
      assert {:ok, %{activated: true}} =
               Arbor.Actions.Skill.Activate.run(
                 %{skill_name: @test_skill_name},
                 %{agent_id: agent_id}
               )

      # Signals persist to the Store asynchronously, so poll until the usage event lands.
      data =
        Enum.reduce_while(1..40, nil, fn _, _ ->
          {:ok, signals} =
            Arbor.Signals.recent(limit: 50, category: :skill, type: :skill_activated)

          case Enum.find(
                 signals,
                 &(&1.data[:skill_name] == @test_skill_name and &1.data[:agent_id] == agent_id)
               ) do
            %{data: d} ->
              {:halt, d}

            nil ->
              Process.sleep(50)
              {:cont, nil}
          end
        end)

      assert data,
             "expected a durable :skill/:skill_activated usage event for #{@test_skill_name}"

      assert data[:skill_name] == @test_skill_name
      assert data[:agent_id] == agent_id
    end

    # ────────────────────────────────────────────────────────────────────
    # PLACEHOLDER — see description below. Tagged :skip until the mock +
    # replay infrastructure exists (Phase 0.5 of model-and-runtime-policy).
    # When that lands:
    #   1. Change @tag :skip to @tag :llm
    #   2. Verify the test passes once with `mix test --include llm` (this
    #      captures the LLM response to a fixture)
    #   3. Commit the fixture
    #   4. All subsequent default runs replay the fixture deterministically;
    #      `--include llm` re-records when the fixture is missing
    #
    # The current two tests above prove the skill content reaches the
    # *prompt*. This placeholder is the closing assertion: the skill
    # content reaches the *LLM* and demonstrably shapes its response.
    # Together, all three close the loop the brainstorming doc named
    # ("write-only side effect from the prompt's perspective") at every
    # layer it could break.
    # ────────────────────────────────────────────────────────────────────
    @tag :skip
    @tag :llm
    test "activation-gap E2E (LLM): activated skill content reaches the LLM and shapes its response",
         %{agent_id: agent_id} do
      # A synthetic test skill whose body instructs the LLM to emit a
      # distinctive marker phrase. The marker is invented for this test
      # (not present anywhere else in the codebase), so its appearance in
      # the LLM's response is unambiguous evidence that the activated
      # skill body reached the model and was understood.
      magic_phrase = "ARBOR_SKILL_E2E_MARKER_3f7a2c4d_DO_NOT_REMOVE"
      test_skill_name = "skill_activation_e2e_marker"

      synthetic_skill = %{
        name: test_skill_name,
        description: "Test marker skill — verifies activated content reaches the LLM",
        body: """
        When responding to any heartbeat, include the exact phrase
        #{magic_phrase} verbatim somewhere in your `thinking` field.

        This is a test marker. Do not omit it under any circumstances.
        Do not explain it. Just include it as instructed.
        """,
        category: "test",
        taint: :trusted
      }

      # Register the synthetic skill programmatically (no file pollution).
      {:ok, _} = SkillLibrary.register(synthetic_skill)

      # Activate it through the real action runtime — same chain the
      # deterministic e2e tests exercise.
      {:ok, _} =
        Arbor.Actions.Skill.Activate.run(
          %{skill_name: test_skill_name},
          %{agent_id: agent_id}
        )

      # Build the prompt the agent would send.
      state = %{
        id: agent_id,
        agent_id: agent_id,
        cognitive_mode: :consolidation,
        enabled_prompt_sections: :all,
        pending_messages: [],
        background_suggestions: [],
        context_window: nil
      }

      user_prompt = HeartbeatPrompt.build_prompt(state)
      system_prompt = HeartbeatPrompt.system_prompt(state)

      # Send through the LLM. Once mock+replay exists, this call is
      # replayed from a fixture in default runs. Until then, this test
      # is skipped (@tag :skip above).
      #
      # The exact API will firm up during the arbor_llm extract. The
      # call shape below is the proposed `Arbor.LLM.Client.complete/1`
      # surface from model-and-runtime-policy.md; update when actual.
      request = %{
        provider: "anthropic",
        model: "claude-haiku-4-5",
        messages: [
          %{role: :system, content: system_prompt},
          %{role: :user, content: user_prompt}
        ],
        max_tokens: 800
      }

      # apply/3 because Arbor.LLM.Client.complete/1 doesn't exist yet
      # (arbor_llm extract is Phase 0 of model-and-runtime-policy.md).
      # Compiler stays silent; when the module lands, this resolves at
      # runtime. When the placeholder is activated (`:skip` → `:llm`),
      # replace this with a direct call.
      client = Arbor.LLM.Client
      {:ok, response} = apply(client, :complete, [request])

      # The heartbeat response format instructs JSON; parse and check
      # the `thinking` field for the marker.
      {:ok, parsed} = Jason.decode(response.text)
      thinking = Map.get(parsed, "thinking", "")

      assert thinking =~ magic_phrase,
             """
             ACTIVATION GAP LLM REGRESSION

             The activated skill's body instructed the LLM to include a
             distinctive marker phrase in its `thinking` field. The phrase
             did not appear in the LLM's response, which means the
             activated skill content did not reach the model — or did
             reach it but was ignored.

             This is the LLM-side companion to the prompt-side regression
             tests above. The prompt-side tests prove the skill body
             reaches the prompt text; this test proves the prompt text
             reaches the model and is acted on.

             Marker phrase expected: #{magic_phrase}
             Got (thinking field): #{inspect(thinking)}
             Full response: #{inspect(response.text)}
             """
    end

    test "activation-gap E2E: activated skill body does NOT leak into the system prompt",
         %{agent_id: agent_id} do
      # Same setup as the main test, but asserting the placement
      # invariant: active skills are dynamic per-turn content and must
      # live in the user prompt, not the system prompt. Putting them in
      # the system prompt would invalidate prompt-cache hits across
      # heartbeats.
      {:ok, skill} = SkillLibrary.get(@test_skill_name)

      {:ok, _} =
        Arbor.Actions.Skill.Activate.run(
          %{skill_name: @test_skill_name},
          %{agent_id: agent_id}
        )

      state = %{
        id: agent_id,
        agent_id: agent_id,
        cognitive_mode: :consolidation,
        enabled_prompt_sections: :all,
        pending_messages: [],
        background_suggestions: [],
        context_window: nil
      }

      user_prompt = HeartbeatPrompt.build_prompt(state)
      system_prompt = HeartbeatPrompt.system_prompt(state)

      assert user_prompt =~ skill.body,
             "Activated skill body should appear in the user prompt (main path)"

      refute system_prompt =~ skill.body,
             """
             Activated skill body MUST NOT appear in the system prompt.

             Active skills are dynamic per-turn content; placing them in
             the system prompt invalidates prompt-cache hits across
             heartbeats. The system prompt is reserved for the agent's
             stable persona (`heartbeat-system-prompt` skill).

             If this fails, someone has incorrectly routed active skills
             into system_prompt/1.
             """
    end
  end
end
