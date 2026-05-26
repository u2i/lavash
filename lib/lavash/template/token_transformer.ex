defmodule Lavash.Template.TokenTransformer do
  @moduledoc """
  Composer for lavash's template-time token transformations.

  HEEx accepts a single `:token_transformer` module per
  `compile_from_tokens/2` call. This module is that single entry
  point — it runs a list of single-purpose sub-transformers in
  order, each implementing `@behaviour Lavash.TokenTransformer`.

  ## Pipeline

  Order matters. Each pass walks the (already transformed) tree.

  1. **`Lavash.Template.PhxTargetTransformer`** (layer 1) —
     auto-inject `phx-target={@myself}` on `phx-*` events inside
     components.

  2. **`Lavash.Optimistic.ClientBindingsTransformer`** (layer 4) —
     inject `__lavash_client_bindings__` propagation +
     `bind={[...]}` shorthand expansion on `<.lavash_component>`
     invocations.

  3. **`Lavash.Optimistic.DataAttrTransformer`** (layer 4) — inject
     `data-lavash-*` attribute annotations (form shorthand, state
     binding, visibility, enabled, class toggle/member, reactive
     attr derives).

  4. **`Lavash.Optimistic.DisplaySpanTransformer`** (layer 4) —
     wrap bare `{@optimistic_field}` in `<span data-lavash-display>`
     so the JS hook can patch the displayed value optimistically.
     Runs **last** so it sees the final tree shape and doesn't
     wrap nodes other passes will modify.

  ## Layer filtering

  Each layer-4 sub-transformer is itself a no-op when
  `metadata[:layer] == :base` — this keeps the composer simple
  (single static list) while letting layer-2-only modules
  (`Lavash.LiveView.Base`) skip optimistic transformations
  entirely. The base check happens inside each sub-transformer's
  `transform/2`, so there's no conditional logic here.

  ## Previously a 800-line monolith

  This module was the original single-pass walker that did
  everything inline. Per `docs/ARCHITECTURE.md` punchlist item #5,
  it was split into the composer + sub-transformers so each layer
  owns its template-time concerns. See `Lavash.Template.Walker`
  for the shared tree-walking primitive each sub-transformer
  builds on.
  """

  @behaviour Lavash.TokenTransformer

  @sub_transformers [
    Lavash.Template.PhxTargetTransformer,
    Lavash.Optimistic.ClientBindingsTransformer,
    Lavash.Optimistic.DataAttrTransformer,
    Lavash.Optimistic.DisplaySpanTransformer
  ]

  @impl true
  def transform(nodes, state) when is_list(nodes) do
    Enum.reduce(@sub_transformers, nodes, fn mod, tree ->
      mod.transform(tree, state)
    end)
  end
end
