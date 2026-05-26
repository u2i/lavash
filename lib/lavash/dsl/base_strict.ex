defmodule Lavash.Dsl.BaseStrict do
  @moduledoc """
  Marker DSL extension that pairs with `Lavash.Dsl` to make
  layer-2-only modules reject layer-4 features at compile time.

  Adds a single transformer, `Lavash.Transformers.ValidateBase`,
  which fires only when the module sets
  `@__lavash_layer__ :base` (done automatically by
  `Lavash.LiveView.Base` / `Lavash.Component.Base`).

  The transformer rejects any `optimistic: true`, `animated: ...`,
  or `calculate ..., optimistic: true` usage with a friendly
  compile-time error explaining the layering choice.

  ## Why this lives in its own extension

  Spark assembles a module's effective transformer pipeline by
  unioning the transformers from each listed extension. We can't
  edit `Lavash.Dsl`'s transformer list at use-site, so `Base`
  ships an extra extension that *adds* the strict-mode check
  alongside the standard pipeline.
  """

  use Spark.Dsl.Extension,
    transformers: [Lavash.Transformers.ValidateBase]
end
