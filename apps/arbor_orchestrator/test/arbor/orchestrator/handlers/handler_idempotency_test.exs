defmodule Arbor.Orchestrator.Handlers.HandlerIdempotencyTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Handlers.{
    BranchHandler,
    CodergenHandler,
    ExitHandler,
    FanInHandler,
    FileWriteHandler,
    ManagerLoopHandler,
    ParallelHandler,
    PipelineRunHandler,
    PipelineValidateHandler,
    StartHandler,
    ToolHandler,
    WaitHumanHandler
  }

  @idempotent_handlers [StartHandler, ExitHandler, BranchHandler]
  @read_only_handlers [PipelineValidateHandler]
  @idempotent_with_key_handlers [FileWriteHandler, CodergenHandler]
  @side_effecting_handlers [
    ToolHandler,
    PipelineRunHandler,
    ParallelHandler,
    FanInHandler,
    WaitHumanHandler,
    ManagerLoopHandler
  ]

  describe "idempotency declarations" do
    test "all handlers declare idempotency" do
      all_handlers =
        @idempotent_handlers ++
          @read_only_handlers ++
          @idempotent_with_key_handlers ++
          @side_effecting_handlers

      for handler <- all_handlers do
        Code.ensure_loaded!(handler)

        assert function_exported?(handler, :idempotency, 0),
               "#{inspect(handler)} must implement idempotency/0"
      end
    end

    test "idempotent handlers return :idempotent" do
      for handler <- @idempotent_handlers do
        assert handler.idempotency() == :idempotent,
               "#{inspect(handler)} should be :idempotent"
      end
    end

    test "read_only handlers return :read_only" do
      for handler <- @read_only_handlers do
        assert handler.idempotency() == :read_only,
               "#{inspect(handler)} should be :read_only"
      end
    end

    test "idempotent_with_key handlers return :idempotent_with_key" do
      for handler <- @idempotent_with_key_handlers do
        assert handler.idempotency() == :idempotent_with_key,
               "#{inspect(handler)} should be :idempotent_with_key"
      end
    end

    test "side_effecting handlers return :side_effecting" do
      for handler <- @side_effecting_handlers do
        assert handler.idempotency() == :side_effecting,
               "#{inspect(handler)} should be :side_effecting"
      end
    end
  end

  describe "Handler.idempotency_of/1" do
    test "returns declared class for handlers that implement it" do
      assert Handler.idempotency_of(StartHandler) == :idempotent
      assert Handler.idempotency_of(ToolHandler) == :side_effecting
      assert Handler.idempotency_of(PipelineValidateHandler) == :read_only
      assert Handler.idempotency_of(FileWriteHandler) == :idempotent_with_key
    end

    test "returns :side_effecting for unknown modules" do
      assert Handler.idempotency_of(String) == :side_effecting
    end
  end
end
