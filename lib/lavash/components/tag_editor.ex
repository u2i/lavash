defmodule Lavash.Components.TagEditor do
  @moduledoc """
  Optimistic tag input with full client re-render.

  This is a self-contained optimistic component with no slots or server content inside.
  Structure changes (adding/removing tags) happen instantly on the client.

  ## Usage

      <.live_component
        module={Lavash.Components.TagEditor}
        id="product-tags"
        bind={[tags: :tags]}
        tags={@tags}
        max_tags={5}
        placeholder="Add a tag..."
      />

  ## How it works

  1. User types a tag and presses Enter → client instantly adds tag to DOM
  2. Server receives event and updates state
  3. When server confirms, client syncs version

  The component handles:
  - Adding tags (Enter key in input)
  - Removing tags (click × button)
  - Max tags limit
  - Duplicate prevention
  """

  use Lavash.ClientComponent

  bind :tags, {:array, :string}

  prop :placeholder, :string, default: "Add tag..."
  prop :max_tags, :integer, default: nil
  prop :tag_class, :string, default: "inline-flex items-center gap-1 px-2 py-1 bg-blue-100 text-blue-800 rounded text-sm"
  prop :input_class, :string, default: "px-2 py-1 border border-gray-300 rounded text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"

  calculate :can_add, @max_tags == nil or length(@tags) < @max_tags
  calculate :tag_count, length(@tags)

  client_template """
  <div class="flex flex-wrap gap-2 items-center">
    <span
      :for={tag <- @tags}
      class={@tag_class}
    >
      {tag}
      <button
        type="button"
        class="hover:text-blue-600 text-blue-400"
        data-optimistic="remove"
        data-optimistic-field="tags"
        data-optimistic-value={tag}
      >×</button>
    </span>
    <input
      :if={@can_add}
      type="text"
      placeholder={@placeholder}
      class={@input_class}
      data-optimistic="add"
      data-optimistic-field="tags"
    />
    <span :if={@max_tags} class="text-xs text-gray-400">
      (<span data-optimistic-display="tag_count">{@tag_count}</span>/{@max_tags})
    </span>
  </div>
  """

  def client_state(assigns) do
    %{
      tags: assigns[:tags] || [],
      placeholder: assigns[:placeholder] || "Add tag...",
      max_tags: assigns[:max_tags],
      tag_class: assigns[:tag_class],
      input_class: assigns[:input_class]
    }
  end

  # Server-side handlers
  def handle_event("add_tag", %{"val" => tag}, socket) do
    tag = String.trim(tag)

    if tag == "" do
      {:noreply, socket}
    else
      binding_map = socket.assigns[:__lavash_binding_map__] || %{}

      case Map.get(binding_map, :tags) do
        nil ->
          # Not bound - update own assigns
          tags = socket.assigns[:tags] || []
          max_tags = socket.assigns[:max_tags]

          new_tags =
            cond do
              tag in tags -> tags
              max_tags && length(tags) >= max_tags -> tags
              true -> tags ++ [tag]
            end

          socket = bump_version(socket)
          {:noreply, Phoenix.Component.assign(socket, :tags, new_tags)}

        parent_field ->
          # Bound to parent - send message
          send(self(), {:lavash_component_add, parent_field, tag})
          {:noreply, socket}
      end
    end
  end

  def handle_event("remove_tag", %{"val" => tag}, socket) do
    binding_map = socket.assigns[:__lavash_binding_map__] || %{}

    case Map.get(binding_map, :tags) do
      nil ->
        # Not bound - update own assigns
        tags = socket.assigns[:tags] || []
        new_tags = Enum.reject(tags, &(&1 == tag))
        socket = bump_version(socket)
        {:noreply, Phoenix.Component.assign(socket, :tags, new_tags)}

      parent_field ->
        # Bound to parent - send message
        send(self(), {:lavash_component_remove, parent_field, tag})
        {:noreply, socket}
    end
  end
end
