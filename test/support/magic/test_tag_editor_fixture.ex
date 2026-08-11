defmodule Lavash.Test.Magic.TagHostLive do
  @moduledoc """
  Fixture: hosts `Lavash.Components.TagEditor` with its tags bound to
  parent state — exercises the `data-lavash-action` input primitive
  (Enter commits the value to the component's `:add` action:
  optimistic chip + server push + input clear) and the child→parent
  binding propagation of the resulting list.
  """
  use Lavash.LiveView
  import Lavash.LiveView.Helpers, only: [lavash_component: 1]

  state :tags, {:array, :string}, from: :ephemeral, default: ["one"], optimistic: true

  calculate :tags_text, rx(Enum.join(@tags, ","))

  template do
    ~H"""
    <div>
      <.lavash_component
        module={Lavash.Components.TagEditor}
        id="tags-editor"
        bind={[tags: :tags]}
        tags={@tags}
        max_tags={5}
        placeholder="Add tag"
      />
      <p>host sees: <span id="host-tags">{@tags_text}</span></p>
    </div>
    """
  end
end
