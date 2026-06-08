defmodule Lavash.Test.Magic.TranspilerEdgeLive do
  @moduledoc """
  Fixture exercising transpiler edge cases that previously emitted invalid or
  silently-broken client JS (only failing at prod esbuild):

    * `?`-suffixed map keys in an optimistic interpolation / `:if`
    * empty-list comparison (`!= []`) over optimistic state
    * an optimistic `:for` whose body accesses loop-variable fields

  If the generated colocated JS is wrong, esbuild fails to build it and the
  optimistic update never patches the DOM — so the e2e assertions below double
  as a check that the emitted JS actually parses and runs.
  """
  use Lavash.LiveView

  # A map with a `?`-suffixed key, toggled optimistically.
  state :matrix, :map, from: :ephemeral, default: %{"declared?" => false}, optimistic: true

  # A list, optimistically appended to (exercises `!= []`).
  state :findings, {:array, :string}, from: :ephemeral, default: [], optimistic: true

  # A list of maps with `?`-suffixed keys, rendered in an optimistic :for.
  state :repos, {:array, :map},
    from: :ephemeral,
    default: [%{"name" => "alpha", "ready?" => true}],
    optimistic: true

  actions do
    action :toggle_declared do
      set :matrix, rx(%{"declared?" => not @matrix["declared?"]})
    end

    action :add_finding do
      set :findings, rx(["f#{length(@findings)}" | @findings])
    end

    action :add_repo do
      set :repos, rx([%{"name" => "beta", "ready?" => false} | @repos])
    end
  end

  template do
    ~H"""
    <div>
      <!-- ?-suffixed nested key in an optimistic :if -->
      <span id="declared" :if={@matrix["declared?"]}>declared</span>
      <button id="toggle-declared" phx-click="toggle_declared">Toggle Declared</button>

      <!-- empty-list comparison over optimistic state -->
      <p id="has-findings" :if={@findings != []}>Has findings: {length(@findings)}</p>
      <button id="add-finding" phx-click="add_finding">Add Finding</button>

      <!-- optimistic :for accessing ?-suffixed loop-var fields -->
      <ul id="repos">
        <li :for={r <- @repos} class="repo">
          {r["name"]}: {if r["ready?"], do: "ready", else: "pending"}
        </li>
      </ul>
      <button id="add-repo" phx-click="add_repo">Add Repo</button>
    </div>
    """
  end
end
