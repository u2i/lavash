defmodule Lavash.Components.SelectionSummary do
  @moduledoc """
  A component that displays a summary of selected items with loading state.

  Shows the current selection and displays a loading indicator while waiting
  for server confirmation after optimistic updates.

  ## Usage

      <.live_component
        module={Lavash.Components.SelectionSummary}
        id="roast-summary"
        bind={[selected: :roast]}
        selected={@roast}
        label="Selected roasts"
      />
  """

  use Lavash.LiveComponent

  # Binding declaration - reads parent state
  bind :selected, {:array, :string}

  # Props
  prop :label, :string, default: "Selected"
  prop :empty_text, :string, default: "None selected"
  prop :labels, :map, default: %{}

  def render(assigns) do
    # Get the bound parent field name for optimistic updates
    binding_map = assigns[:__lavash_binding_map__] || %{}
    parent_field = Map.get(binding_map, :selected)

    assigns =
      assigns
      |> Phoenix.Component.assign(:parent_field, parent_field)
      |> Phoenix.Component.assign(:optimistic_enabled, parent_field != nil)

    # Generate script tag for optimistic updates if bound
    script_tag =
      if parent_field do
        js = generate_optimistic_js(parent_field)
        id = assigns.id
        Phoenix.HTML.raw(~s[<script id="#{id}-optimistic">#{js}</script>])
      else
        ""
      end

    assigns = Phoenix.Component.assign(assigns, :script_tag, script_tag)

    ~H"""
    <div class="space-y-2">
      <span class="text-sm font-medium text-gray-700">{@label}:</span>
      <div class="flex flex-wrap gap-1 min-h-[24px]">
        <%!-- Loading placeholder (shown optimistically while waiting for server) --%>
        <span
          :if={@optimistic_enabled}
          class="hidden items-center gap-1 text-sm text-gray-500"
          data-optimistic-class={"#{@parent_field}_loading"}
        >
          <svg class="animate-spin h-4 w-4 text-indigo-500" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          <span>Updating...</span>
        </span>
        <%!-- Content (hidden optimistically while loading) --%>
        <span
          class="contents"
          data-optimistic-class={"#{@parent_field}_content"}
        >
          <%= if @selected && @selected != [] do %>
            <span
              :for={item <- @selected}
              class="inline-flex items-center px-2 py-0.5 text-xs font-medium bg-indigo-100 text-indigo-800 rounded"
            >
              {Map.get(@labels || %{}, item, humanize(item))}
            </span>
          <% else %>
            <span class="text-sm text-gray-500 italic">{@empty_text}</span>
          <% end %>
        </span>
      </div>
      {@script_tag}
    </div>
    """
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp generate_optimistic_js(field) do
    loading_derive = "#{field}_loading"
    content_derive = "#{field}_content"

    """
    (function() {
      const wrapper = document.querySelector('[data-lavash-module]');
      if (!wrapper) return;
      const moduleName = wrapper.dataset.lavashModule;
      if (!moduleName) return;

      window.Lavash = window.Lavash || {};
      window.Lavash.optimistic = window.Lavash.optimistic || {};
      window.Lavash.optimistic[moduleName] = window.Lavash.optimistic[moduleName] || {};

      const fns = window.Lavash.optimistic[moduleName];

      // Loading state derive - shows spinner when client is ahead of server
      if (!fns.#{loading_derive}) {
        fns.#{loading_derive} = function(state, meta) {
          // meta.isPending is true when clientVersion > serverVersion
          return meta?.isPending ? "inline-flex items-center gap-1 text-sm text-gray-500" : "hidden";
        };
        if (!fns.__derives__) fns.__derives__ = [];
        if (!fns.__derives__.includes("#{loading_derive}")) {
          fns.__derives__.push("#{loading_derive}");
        }
      }

      // Content derive - hides content when loading
      if (!fns.#{content_derive}) {
        fns.#{content_derive} = function(state, meta) {
          return meta?.isPending ? "hidden" : "contents";
        };
        if (!fns.__derives__.includes("#{content_derive}")) {
          fns.__derives__.push("#{content_derive}");
        }
      }
    })();
    """
  end
end
