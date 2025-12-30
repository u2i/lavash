defmodule Lavash.Components.TagEditorV2 do
  @moduledoc """
  TagEditor using ClientComponentV2 with Spark DSL.

  This demonstrates the new declarative approach where:
  - `bind` declares state bindings to parent
  - `prop` declares read-only props from parent
  - `calculate` declares computed fields for both client and server
  - `optimistic_action` declares actions with run/validate functions that compile to both
  - `client_template` declares the HEEx template that compiles to JS render
  """

  use Lavash.ClientComponentV2

  bind :tags, {:array, :string}

  prop :placeholder, :string, default: "Add tag..."
  prop :max_tags, :integer, default: nil
  prop :tag_class, :string,
    default: "inline-flex items-center gap-1 px-2 py-1 bg-blue-100 text-blue-800 rounded text-sm"

  prop :input_class, :string,
    default:
      "px-2 py-1 border border-gray-300 rounded text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"

  calculate :can_add, @max_tags == nil or length(@tags) < @max_tags
  calculate :tag_count, length(@tags)

  optimistic_action :add, :tags,
    run: fn tags, tag -> tags ++ [tag] end,
    validate: fn tags, tag -> tag not in tags end,
    max: :max_tags

  optimistic_action :remove, :tags,
    run: fn tags, tag -> Enum.reject(tags, &(&1 == tag)) end

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
end
