defmodule Arbor.SDLC.PipelineTest do
  use ExUnit.Case, async: false

  alias Arbor.SDLC.Pipeline

  @moduletag :fast

  # Reset config after each test to avoid test pollution
  setup do
    on_exit(fn -> Pipeline.reset_config() end)
    :ok
  end

  describe "stages/0" do
    test "returns all stages in order" do
      stages = Pipeline.stages()

      assert :inbox in stages
      assert :brainstorming in stages
      assert :planned in stages
      assert :in_progress in stages
      assert :completed in stages
      assert :discarded in stages
      assert length(stages) == 6
    end
  end

  describe "initial_stage/0" do
    test "returns inbox" do
      assert Pipeline.initial_stage() == :inbox
    end
  end

  describe "terminal_stages/0" do
    test "returns completed and discarded" do
      terminals = Pipeline.terminal_stages()

      assert :completed in terminals
      assert :discarded in terminals
      assert length(terminals) == 2
    end
  end

  describe "transition_allowed?/2" do
    test "allows inbox to brainstorming" do
      assert Pipeline.transition_allowed?(:inbox, :brainstorming)
    end

    test "allows brainstorming to planned" do
      assert Pipeline.transition_allowed?(:brainstorming, :planned)
    end

    test "allows brainstorming to discarded" do
      assert Pipeline.transition_allowed?(:brainstorming, :discarded)
    end

    test "allows planned to in_progress" do
      assert Pipeline.transition_allowed?(:planned, :in_progress)
    end

    test "allows planned to discarded" do
      assert Pipeline.transition_allowed?(:planned, :discarded)
    end

    test "allows in_progress to completed" do
      assert Pipeline.transition_allowed?(:in_progress, :completed)
    end

    test "allows in_progress back to planned" do
      assert Pipeline.transition_allowed?(:in_progress, :planned)
    end

    test "disallows skipping stages" do
      refute Pipeline.transition_allowed?(:inbox, :planned)
      refute Pipeline.transition_allowed?(:inbox, :in_progress)
      refute Pipeline.transition_allowed?(:inbox, :completed)
    end

    test "disallows backward transitions except in_progress to planned" do
      refute Pipeline.transition_allowed?(:brainstorming, :inbox)
      refute Pipeline.transition_allowed?(:planned, :brainstorming)
      refute Pipeline.transition_allowed?(:completed, :in_progress)
    end

    test "disallows transitions from terminal stages" do
      refute Pipeline.transition_allowed?(:completed, :inbox)
      refute Pipeline.transition_allowed?(:discarded, :planned)
    end
  end

  describe "stage_directory/1" do
    test "returns correct directory for inbox" do
      assert Pipeline.stage_directory(:inbox) == "0-inbox"
    end

    test "returns correct directory for brainstorming" do
      assert Pipeline.stage_directory(:brainstorming) == "1-brainstorming"
    end

    test "returns correct directory for planned" do
      assert Pipeline.stage_directory(:planned) == "2-planned"
    end

    test "returns correct directory for in_progress" do
      assert Pipeline.stage_directory(:in_progress) == "3-in-progress"
    end

    test "returns correct directory for completed" do
      assert Pipeline.stage_directory(:completed) == "5-completed"
    end

    test "returns correct directory for discarded" do
      assert Pipeline.stage_directory(:discarded) == "8-discarded"
    end
  end

  describe "directory_stage/1" do
    test "returns inbox for 0-inbox" do
      assert Pipeline.directory_stage("0-inbox") == {:ok, :inbox}
    end

    test "returns brainstorming for 1-brainstorming" do
      assert Pipeline.directory_stage("1-brainstorming") == {:ok, :brainstorming}
    end

    test "returns error for unknown directory" do
      assert Pipeline.directory_stage("unknown") == :error
    end
  end

  describe "stage_path/2" do
    test "builds correct path for inbox" do
      assert Pipeline.stage_path(:inbox, "/roadmap") == "/roadmap/0-inbox"
    end

    test "builds correct path for completed" do
      assert Pipeline.stage_path(:completed, "/my/roadmap") == "/my/roadmap/5-completed"
    end
  end

  describe "watched_directories/1" do
    test "returns inbox and brainstorming directories" do
      dirs = Pipeline.watched_directories("/roadmap")

      assert "/roadmap/0-inbox" in dirs
      assert "/roadmap/1-brainstorming" in dirs
      assert length(dirs) == 2
    end
  end

  describe "stage_from_path/1" do
    test "extracts stage from full path" do
      assert Pipeline.stage_from_path("/roadmap/0-inbox/item.md") == {:ok, :inbox}
      assert Pipeline.stage_from_path("/roadmap/1-brainstorming/item.md") == {:ok, :brainstorming}
      assert Pipeline.stage_from_path("/roadmap/5-completed/item.md") == {:ok, :completed}
    end

    test "returns error for unknown path" do
      assert Pipeline.stage_from_path("/other/path/item.md") == :error
    end
  end

  describe "next_stage/1" do
    test "returns next stage for non-terminal stages" do
      assert Pipeline.next_stage(:inbox) == {:ok, :brainstorming}
      assert Pipeline.next_stage(:brainstorming) == {:ok, :planned}
      assert Pipeline.next_stage(:planned) == {:ok, :in_progress}
      assert Pipeline.next_stage(:in_progress) == {:ok, :completed}
    end

    test "returns nil for terminal stages" do
      assert Pipeline.next_stage(:completed) == nil
      assert Pipeline.next_stage(:discarded) == nil
    end
  end

  describe "processing_stage?/1" do
    test "returns true for inbox and brainstorming" do
      assert Pipeline.processing_stage?(:inbox)
      assert Pipeline.processing_stage?(:brainstorming)
    end

    test "returns false for other stages" do
      refute Pipeline.processing_stage?(:planned)
      refute Pipeline.processing_stage?(:in_progress)
      refute Pipeline.processing_stage?(:completed)
    end
  end

  describe "ensure_directories!/1" do
    setup do
      test_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      temp_root = Path.join(System.tmp_dir!(), "pipeline_test_#{test_id}")

      on_exit(fn ->
        File.rm_rf!(temp_root)
      end)

      %{temp_root: temp_root}
    end

    test "creates all stage directories", %{temp_root: temp_root} do
      assert :ok = Pipeline.ensure_directories!(temp_root)

      for stage <- Pipeline.stages() do
        path = Pipeline.stage_path(stage, temp_root)
        assert File.dir?(path), "Expected #{path} to exist"
      end
    end
  end

  # =============================================================================
  # Runtime Configuration Tests
  # =============================================================================

  describe "config/0" do
    test "returns default configuration when not configured" do
      config = Pipeline.config()

      assert is_list(config.stages)
      assert is_map(config.directories)
      assert match?(%MapSet{}, config.transitions)
      assert is_list(config.processing_stages)
    end

    test "includes all default stages" do
      config = Pipeline.config()

      assert :inbox in config.stages
      assert :brainstorming in config.stages
      assert :planned in config.stages
      assert :in_progress in config.stages
      assert :completed in config.stages
      assert :discarded in config.stages
    end
  end

  describe "configure/1" do
    test "updates stages configuration" do
      custom_stages = [:draft, :review, :published]

      Pipeline.configure(%{stages: custom_stages})

      assert Pipeline.stages() == custom_stages
    end

    test "updates directory mapping" do
      custom_dirs = %{
        draft: "drafts",
        review: "under-review",
        published: "live"
      }

      Pipeline.configure(%{
        stages: [:draft, :review, :published],
        directories: custom_dirs
      })

      assert Pipeline.stage_directory(:draft) == "drafts"
      assert Pipeline.stage_directory(:review) == "under-review"
      assert Pipeline.stage_directory(:published) == "live"
    end

    test "updates transitions" do
      custom_transitions = [
        {:draft, :review},
        {:review, :published},
        {:review, :draft}
      ]

      Pipeline.configure(%{transitions: custom_transitions})

      assert Pipeline.transition_allowed?(:draft, :review)
      assert Pipeline.transition_allowed?(:review, :published)
      assert Pipeline.transition_allowed?(:review, :draft)
      # Old transition should not work
      refute Pipeline.transition_allowed?(:inbox, :brainstorming)
    end

    test "updates processing stages" do
      custom_processing = [:draft, :review]

      Pipeline.configure(%{
        stages: [:draft, :review, :published],
        directories: %{draft: "drafts", review: "review", published: "published"},
        processing_stages: custom_processing
      })

      assert Pipeline.processing_stage?(:draft)
      assert Pipeline.processing_stage?(:review)
      refute Pipeline.processing_stage?(:published)
    end

    test "merges with existing configuration" do
      # First configure stages
      Pipeline.configure(%{stages: [:a, :b, :c]})

      # Then configure directories separately
      Pipeline.configure(%{directories: %{a: "stage-a", b: "stage-b", c: "stage-c"}})

      # Both should be present
      assert Pipeline.stages() == [:a, :b, :c]
      assert Pipeline.stage_directory(:a) == "stage-a"
    end
  end

  describe "reset_config/0" do
    test "restores default configuration" do
      # Configure custom pipeline
      Pipeline.configure(%{stages: [:custom]})
      assert Pipeline.stages() == [:custom]

      # Reset
      Pipeline.reset_config()

      # Should have defaults again
      assert :inbox in Pipeline.stages()
      assert length(Pipeline.stages()) == 6
    end
  end

  describe "directory_stage/1 with custom config" do
    test "reverse mapping works with custom directories" do
      Pipeline.configure(%{
        stages: [:todo, :doing, :done],
        directories: %{
          todo: "1-todo",
          doing: "2-doing",
          done: "3-done"
        }
      })

      assert Pipeline.directory_stage("1-todo") == {:ok, :todo}
      assert Pipeline.directory_stage("2-doing") == {:ok, :doing}
      assert Pipeline.directory_stage("3-done") == {:ok, :done}
      assert Pipeline.directory_stage("unknown") == :error
    end
  end

  describe "initial_stage/0 with custom config" do
    test "returns first stage from custom configuration" do
      Pipeline.configure(%{stages: [:start, :middle, :end]})

      assert Pipeline.initial_stage() == :start
    end
  end

  describe "watched_directories/1 with custom config" do
    test "uses custom processing stages" do
      Pipeline.configure(%{
        stages: [:draft, :review, :published],
        directories: %{
          draft: "drafts",
          review: "review",
          published: "published"
        },
        processing_stages: [:draft]
      })

      dirs = Pipeline.watched_directories("/my/root")

      assert dirs == ["/my/root/drafts"]
    end
  end
end
