defmodule Lavash.Optimistic.SchemaExtension do
  @moduledoc """
  Layer-4 (optimism) schema fragments that extend lavash's base DSL
  entities.

  The base `state` / `calculate` schemas in `Lavash.Dsl.CommonEntities`
  carry only layer-1/2/3 concerns. The optimistic-update keys —
  `optimistic:` and `animated:` — are layer-4 and live here. They're
  appended at schema-build time so the keys still show up in the
  user-facing DSL today, but they're declared in a layer-4-tagged
  module and can be conditionally compiled out by a future
  layer-2-only build configuration (see `docs/ARCHITECTURE.md`
  punchlist item #10).

  ## Why a module, not a `@compile_env` flag

  Compile-time module composition is the only way to make the
  schema's set of accepted keys differ between builds. A flag
  would require runtime detection inside Spark transformers, which
  doesn't compose with Spark's compile-time entity validation.

  When/if `Lavash.LiveView.Base` lands (punchlist item #10), a
  layer-2-only build will replace this module with a stub that
  returns `[]` — and Spark will then reject `state :foo, optimistic:
  true` at compile time with a clear "unknown option" error.
  """

  @doc """
  Schema fragment for `calculate` entities. Appended to the base
  calculate schema. Controls whether the calc's `rx()` body is also
  transpiled to JS and run client-side.

  Default `true` for backward compatibility — most calcs are
  transpilable. Layer-2-only consumers (a hypothetical
  `Lavash.LiveView.Base`) would replace this with `optimistic: []`
  in their schema-extension module, making every calc server-only.
  """
  def calculate_schema do
    [
      optimistic: [
        type: :boolean,
        default: true,
        doc: """
        Whether to transpile to JavaScript for client-side updates.
        Auto-set to false if the expression can't be transpiled.
        """
      ]
    ]
  end

  @doc """
  Schema fragment for `state` entities. Appended to
  `Lavash.Dsl.CommonEntities.base_state_schema/0`.
  """
  def state_schema do
    [
      optimistic: [
        type: :boolean,
        default: false,
        doc: "Enable optimistic updates with version tracking"
      ],
      animated: [
        type: {:or, [:boolean, :keyword_list]},
        default: false,
        doc: """
        Enable animated state transitions with phase tracking.

        Options (when keyword list):
        - `async: :field_name` - coordinate with async data loading
        - `preserve_dom: true` - keep DOM alive during exit animation
        - `duration: 200` - fallback timeout in ms
        """
      ]
    ]
  end
end
