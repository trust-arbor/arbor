defmodule Arbor.Orchestrator.CodingPlanTestActionCatalog do
  @moduledoc false

  @modules [
    Arbor.Actions.Acp.StartSession,
    Arbor.Actions.Acp.SendMessage,
    Arbor.Actions.Acp.SessionStatus,
    Arbor.Actions.Acp.CloseSession,
    Arbor.Actions.Coding.Workspace.Acquire,
    Arbor.Actions.Coding.Workspace.Inspect,
    Arbor.Actions.Coding.Workspace.Release,
    Arbor.Actions.Coding.Workspace.CommittedChange,
    Arbor.Actions.Coding.Workspace.RecoverySummary,
    Arbor.Actions.Coding.DependencyBaselineAdmission,
    Arbor.Actions.Coding.DesignCheckpoint.Parse,
    Arbor.Actions.Coding.DesignCheckpoint.Capture,
    Arbor.Actions.Coding.DesignCheckpoint.Open,
    Arbor.Actions.Coding.DesignCheckpoint.Await,
    Arbor.Actions.Coding.DesignCheckpoint.Load,
    Arbor.Actions.Coding.SecurityRegression.Validate,
    Arbor.Actions.Coding.CrossApp.Validate,
    Arbor.Actions.Coding.ReviewTree.Read,
    Arbor.Actions.Coding.ReviewTree.Search,
    Arbor.Actions.Coding.SubmitReviewReport,
    Arbor.Actions.Mix.Compile,
    Arbor.Actions.Mix.Test,
    Arbor.Actions.Coding.ReviewedCommit,
    Arbor.Actions.Git.Commit,
    Arbor.Actions.Git.PR,
    Arbor.Actions.Council.ReviewChange,
    Arbor.Actions.Consensus.DecideReview
  ]

  @spec modules() :: [module()]
  def modules, do: @modules
end
