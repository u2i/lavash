defmodule Lavash.Template.PhxTargetTransformer do
  @moduledoc """
  Layer-1 token transformer: auto-injects `phx-target={@myself}` on
  any tag inside a `Lavash.Component` that carries a `phx-*` event
  attribute (phx-click, phx-submit, etc.).

  Without this injection, a `phx-click="bump"` button inside a
  component would send the event to the parent LiveView, not the
  component — almost never what the author meant. The injection is
  a quality-of-life DSL behavior, not optimism-related; it belongs
  with layer 1 (the base DSL plumbing).

  Only fires when `metadata[:context] == :component`, so plain
  LiveView templates pass through unchanged.
  """

  @behaviour Lavash.TokenTransformer

  alias Lavash.Template.{AttrHelpers, Walker}

  # The HTML/Phoenix attrs that, when given a value, target a
  # server event handler. Modifier attrs like `phx-throttle` /
  # `phx-debounce` are not in this list — they're configuration on
  # the events above, not events themselves.
  @phx_events ~w(phx-click phx-change phx-submit phx-blur phx-focus
                 phx-keydown phx-keyup phx-window-keydown phx-window-keyup
                 phx-mouseenter phx-mouseleave phx-mouseover phx-mouseout
                 phx-mousedown phx-mouseup
                 phx-viewport-top phx-viewport-bottom)

  @impl true
  def transform(nodes, state) do
    metadata = state[:lavash_metadata] || %{}

    Walker.walk(nodes,
      metadata: metadata,
      attrs_callback: &maybe_inject/4
    )
  end

  defp maybe_inject(_name, attrs, _meta, metadata) do
    cond do
      # Tag opted out of all auto-injection.
      AttrHelpers.has_attr?(attrs, "data-lavash-manual") ->
        attrs

      metadata[:context] == :component and has_phx_event?(attrs) ->
        AttrHelpers.add_attr_if_missing(attrs, "phx-target", {:expr, "@myself"})

      true ->
        attrs
    end
  end

  defp has_phx_event?(attrs) do
    Enum.any?(attrs, fn
      {name, _, _} -> name in @phx_events
      _ -> false
    end)
  end
end
