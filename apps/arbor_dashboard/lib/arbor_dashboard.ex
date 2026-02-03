defmodule Arbor.Dashboard do
  @moduledoc """
  Phoenix LiveView dashboards for Arbor.

  A Level 2 app that consumes `arbor_web` foundation components and
  accesses backend apps only through their public facades.

  ## Dashboards

  | Dashboard | Description | Backend Dependencies |
  |-----------|-------------|---------------------|
  | LandingLive | Navigation shell | None |
  | SignalsLive | Real-time signal stream | arbor_signals |
  | EvalLive | Evaluation results | arbor_eval |

  ## Architecture

  - Uses `arbor_web` for shared components, theme, and layouts
  - Hosts its own Phoenix.Endpoint on a configurable port (default 4001)
  - Accesses backends only through public facades
  - Signal subscriptions scoped per dashboard
  """
end
