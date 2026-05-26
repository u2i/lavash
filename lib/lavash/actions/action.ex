defmodule Lavash.Actions.Action do
  @moduledoc """
  An action that transforms state in response to events.

  ## Action lifecycle

  Action bodies are split around the reactive cascade. Pre-cascade ops
  mutate state; the cascade settles; post-cascade ops observe and
  emit. See `docs/ACTION_LIFECYCLE.md` for the full design.

  ## Pre-cascade ops (mutate state)

  - `set :foo, rx(...)` - declarative state writes
  - `pre_run fn socket -> socket end` - imperative pre-cascade hook
  - `map_by ...` - keyed array mutations

  ## Post-cascade ops (observe and emit)

  - `run fn socket -> socket end` - imperative; reads settled state
  - `effect fn assigns -> :ok end` - fire-and-forget side effects
  - `submit` - form submission (async)
  - `navigate`, `flash`, `push_event`, `push_patch`, `redirect` -
    declarative side effects (handled outside execute_action, in the
    LV-level pipeline)
  - `invoke` - invoke an action on a child component
  """
  defstruct [
    :name,
    :params,
    :reads,
    :when,
    :sets,
    :pre_runs,
    :runs,
    :map_bys,
    :effects,
    :submits,
    :navigates,
    :push_patches,
    :redirects,
    :push_events,
    :flashes,
    :invokes,
    __spark_metadata__: nil
  ]
end
