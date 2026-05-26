defmodule Lavash.Transformers.ValidateBase do
  @moduledoc """
  Layer-2 strictness check. Runs only when the module declares
  itself as layer-2-only (via `use Lavash.LiveView.Base` or
  `use Lavash.Component.Base`) and rejects any use of layer-4
  features:

    * `state :foo, optimistic: true`
    * `state :foo, animated: ...`
    * `calculate :foo, rx(...), optimistic: true`

  The schema still *accepts* these keys (they live in
  `Lavash.Optimistic.SchemaExtension` and are appended to the
  base schemas in `Lavash.Dsl.CommonEntities`). This transformer
  catches them after parse time and turns them into a friendly
  compile-time error explaining the layering choice.

  Why a transformer rather than removing the keys from the schema:
  swapping the schema would require parameterizing
  `base_state_schema/0` per-extension. The transformer approach
  produces better error messages and keeps the schema definition
  in one place.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def after?(Lavash.Transformers.ValidateDsl), do: true
  def after?(_), do: false

  def before?(_), do: false

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    # Only fire when the module is layer-2-only. The flag is set
    # by `Lavash.LiveView.Base`'s `handle_opts/1`.
    if Module.get_attribute(module, :__lavash_layer__) == :base do
      states = Transformer.get_entities(dsl_state, [:states]) || []

      # `calculate ..., optimistic: true` is not checked: the
      # field's default is `true` (set by
      # `Lavash.Optimistic.SchemaExtension.calculate_schema/0`) so
      # erroring on it would catch the default case too. In Base
      # mode the layer-4 transformers (notably ExtractColocatedJs)
      # short-circuit, so an `optimistic: true` calc just becomes
      # a server-only one. The flag is a no-op rather than a
      # rejected feature.
      with :ok <- check_no_optimistic_states(states, module),
           :ok <- check_no_animated_states(states, module) do
        {:ok, dsl_state}
      end
    else
      {:ok, dsl_state}
    end
  end

  defp check_no_optimistic_states(states, module) do
    case Enum.find(states, &(Map.get(&1, :optimistic) == true)) do
      nil ->
        :ok

      field ->
        {:error,
         DslError.exception(
           module: module,
           path: [:states, field.name],
           message: optimistic_message(field.name)
         )}
    end
  end

  defp check_no_animated_states(states, module) do
    case Enum.find(states, &animated?/1) do
      nil ->
        :ok

      field ->
        {:error,
         DslError.exception(
           module: module,
           path: [:states, field.name],
           message: animated_message(field.name)
         )}
    end
  end

  defp animated?(%{animated: nil}), do: false
  defp animated?(%{animated: false}), do: false
  defp animated?(%{animated: _}), do: true
  defp animated?(_), do: false

  defp optimistic_message(name) do
    """
    state :#{name}, optimistic: true is not supported in
    `Lavash.LiveView.Base` / `Lavash.Component.Base`.

    `Base` is the layer-2-only build — no client-side optimism.
    Either:

      - Remove `optimistic: true` and let the field be
        server-authoritative (server diff drives DOM updates).

      - Switch to `use Lavash.LiveView` (the full stack) if you
        want optimistic UI for this field.
    """
  end

  defp animated_message(name) do
    """
    state :#{name}, animated: ... is not supported in
    `Lavash.LiveView.Base` / `Lavash.Component.Base`.

    `animated:` drives the layer-4 phase machine
    (entering/loading/visible/exiting) which is part of the
    optimistic UI layer. Either:

      - Remove the `animated:` option and drive transitions with
        CSS classes on the rendered DOM (server-authoritative).

      - Switch to `use Lavash.LiveView` if you want animated
        overlays.
    """
  end
end
