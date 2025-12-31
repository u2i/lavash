defmodule Lavash.LiveComponent do
  @moduledoc """
  A Spark-based component that uses SyncedVar for optimistic state synchronization.

  Unlike ClientComponent which re-renders entire HTML on the client, LiveComponent
  keeps the DOM static and updates individual values via SyncedVar. This is more efficient
  for simple value changes but cannot handle structural DOM changes.

  ## Key Differences from ClientComponent

  | Aspect | ClientComponent | LiveComponent |
  |--------|-----------------|---------------|
  | Rendering | Client re-renders HTML | Server renders, client updates values |
  | Structural changes | Yes (add/remove nodes) | No |
  | Pending tracking | `pendingCount` (global) | `SyncedVar` per field |
  | Template | `client_template` (transpiled) | `client_template` with data-synced-* |
  | Update mechanism | Full innerHTML | `data-synced-*` attributes |

  ## Usage

      defmodule MyApp.Toggle do
        use Lavash.LiveComponent

        # Synced field connects to parent state
        synced :value, :boolean

        # Props from parent (read-only)
        prop :label, :string, default: ""

        # Calculations for derived display values
        calculate :button_class, if(@value, do: "bg-blue-600", else: "bg-gray-200")

        # Optimistic action
        optimistic_action :toggle, :value,
          run: fn value, _arg -> !value end

        # Template with natural syntax - l-action and class={@calc} are auto-transformed
        client_template \"\"\"
        <button l-action="toggle" class={@button_class}>
          <span>{if @value, do: "On", else: "Off"}</span>
        </button>
        \"\"\"
      end

  ## Data Attributes (auto-generated from template)

  - `l-action="toggle"` → `data-synced-action="toggle" data-synced-field="value"`
  - `class={@calc}` → adds `data-synced-class="calc"`
  - `{@calc}` in text → adds `data-synced-text="calc"` to parent element
  """

  use Spark.Dsl,
    default_extensions: [extensions: [Lavash.LiveComponent.Dsl]]

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

      @before_compile Lavash.LiveComponent.Compiler
    end
  end

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    []
  end

  @doc """
  Bumps the version counter for server-side state changes.

  This is used by ClientComponent to track when state changes happen
  server-side, allowing the client to detect and reconcile with
  optimistic updates.
  """
  def bump_version(socket) do
    version = Map.get(socket.assigns, :__lavash_version__, 0)
    Phoenix.Component.assign(socket, :__lavash_version__, version + 1)
  end
end
