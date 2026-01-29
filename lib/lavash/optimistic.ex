defmodule Lavash.Optimistic do
  @moduledoc """
  Namespace module for Lavash's optimistic update infrastructure.

  This module serves as documentation and namespace for the optimistic update system.
  The actual functionality is provided by submodules:

  ## Active Submodules

  - `Lavash.Optimistic.JsGenerator` - Generates JavaScript from DSL declarations
  - `Lavash.Optimistic.Macros` - Provides the `optimistic_action/3` macro for LiveViews
  - `Lavash.Optimistic.ActionMacro` - Provides `optimistic_action` for ClientComponents
  - `Lavash.Optimistic.ColocatedTransformer` - Extracts generated JS to colocated files
  - `Lavash.Optimistic.ExpandAnimatedStates` - Expands animated state DSL
  - `Lavash.Optimistic.DefrxExpander` - Expands defrx function calls

  ## How Optimistic Updates Work

  When you mark state fields and derives with `optimistic: true`, Lavash:

  1. **Generates JavaScript** from your DSL action declarations at compile time
  2. **Extracts to colocated files** via `Lavash.Optimistic.ColocatedTransformer`
  3. **Injects state** into the page via `Lavash.LiveView.Runtime.wrap_render/3`
  4. **Updates DOM** via the `LavashOptimistic` hook (in `priv/static/lavash_optimistic.js`)

  ## Usage Example

      defmodule MyApp.CounterLive do
        use Lavash.LiveView

        state :count, :integer, from: :url, default: 0, optimistic: true

        optimistic_action :increment, :count,
          run: fn count, _params -> count + 1 end

        render fn assigns ->
          ~H\"\"\"
          <div>
            <span>{@count}</span>
            <button phx-click="increment">+</button>
          </div>
          \"\"\"
        end
      end

  The `LavashOptimistic` hook automatically intercepts the button click, updates the DOM
  optimistically, then confirms with the server.
  """
end
