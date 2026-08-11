defmodule Lavash.Components.TagEditor do
  @moduledoc """
  Optimistic tag input component.

  ## Usage

      <.lavash_component
        module={Lavash.Components.TagEditor}
        id="product-tags"
        bind={[tags: :tags]}
        tags={@tags}
        max_tags={5}
        placeholder="Add a tag..."
      />
  """
  use Lavash.Component

  state :tags, {:array, :string}, from: :ephemeral, default: []

  prop :placeholder, :string, default: "Add tag..."
  prop :max_tags, :integer, default: nil

  prop :tag_class, :string,
    default: "inline-flex items-center gap-1 px-2 py-1 bg-blue-100 text-blue-800 rounded text-sm"

  # Default carries explicit foreground AND background: an input that
  # inherits its colors from the host theme can end up grey-on-white
  # (or worse, dark-on-dark). Hosts with a design system should pass
  # their own class (e.g. daisyUI `input input-bordered input-sm`).
  prop :input_class, :string,
    default:
      "px-2 py-1 bg-white text-gray-900 placeholder-gray-500 border border-gray-300 rounded " <>
        "text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"

  calculate :can_add, rx(@max_tags == nil or length(@tags) < @max_tags)
  calculate :tag_count, rx(length(@tags))

  actions do
    action :add, [:val] do
      set :tags, rx(@tags ++ [@val])
    end

    action :remove, [:val] do
      set :tags, rx(Enum.reject(@tags, &(&1 == @val)))
    end
  end

  template do
    ~H"""
    <div class="flex flex-wrap gap-2 items-center">
      <span
        :for={tag <- @tags}
        class={@tag_class}
      >
        {tag}
        <button
          type="button"
          class="text-blue-600 hover:text-blue-900"
          phx-click="remove"
          phx-value-val={tag}
        >×</button>
      </span>
      <input
        :if={@can_add}
        type="text"
        placeholder={@placeholder}
        class={@input_class}
        data-lavash-action="add"
        data-lavash-state-field="tags"
      />
      <span :if={@max_tags} class="text-xs text-gray-400">
        ({@tag_count}/{@max_tags})
      </span>
    </div>
    """
  end
end
