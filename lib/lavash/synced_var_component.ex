defmodule Lavash.SyncedVarComponent do
  @moduledoc """
  A Spark-based component that uses SyncedVar for optimistic state synchronization.

  Unlike ClientComponent which re-renders entire HTML on the client, SyncedVarComponent
  keeps the DOM static and updates individual values via SyncedVar. This is more efficient
  for simple value changes but cannot handle structural DOM changes.

  ## Key Differences from ClientComponent

  | Aspect | ClientComponent | SyncedVarComponent |
  |--------|-----------------|-------------------|
  | Rendering | Client re-renders HTML | Server renders, client updates values |
  | Structural changes | Yes (add/remove nodes) | No |
  | Pending tracking | `pendingCount` (global) | `SyncedVar` per field |
  | Template | `client_template` (transpiled) | Regular `render/1` |
  | Update mechanism | Full innerHTML | `data-synced-*` attributes |

  ## Usage

      defmodule MyApp.Toggle do
        use Lavash.SyncedVarComponent

        # Synced field connects to parent state
        synced :value, :boolean

        # Props from parent (read-only)
        prop :label, :string, default: ""

        # Calculations for derived display values
        calculate :button_class, if(@value, do: "bg-blue-600", else: "bg-gray-200")

        # Optimistic action
        optimistic_action :toggle, :value,
          run: fn value, _arg -> !value end

        def render(assigns) do
          ~H\"\"\"
          <div id={@id} phx-hook={@__hook_name__} data-synced-state={@__state_json__}>
            <button
              data-synced-action="toggle"
              data-synced-field="value"
              class={@button_class}
            >
              <span data-synced-text="value">{if @value, do: "On", else: "Off"}</span>
            </button>
          </div>
          \"\"\"
        end
      end

  ## Data Attributes

  - `data-synced-action="toggle"` - Element triggers the named action on click
  - `data-synced-field="value"` - The field being modified
  - `data-synced-text="field"` - Update textContent from field value
  - `data-synced-class="field"` - Update className from field value
  - `data-synced-attr-X="field"` - Update attribute X from field value
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.SyncedVarComponent.Dsl]]

  @impl Spark.Dsl
  def handle_opts(_opts) do
    quote do
      use Phoenix.LiveComponent
      require Phoenix.LiveView.TagEngine
      require Phoenix.Component
      import Phoenix.Component
      import Lavash.Optimistic.Macros, only: [calculate: 2, optimistic_action: 3]

      Module.register_attribute(__MODULE__, :__lavash_calculations__, accumulate: true)
      Module.register_attribute(__MODULE__, :__lavash_optimistic_actions__, accumulate: true)

      @before_compile Lavash.SyncedVarComponent.Compiler
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    []
  end
end
