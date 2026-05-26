defmodule Lavash.Optimistic.DataAttrTransformer do
  @moduledoc """
  Layer-4 token transformer: injects `data-lavash-*` annotations on
  HTML tag attributes so the JS hook can apply optimistic updates
  client-side.

  Handles seven patterns, each gated on the relevant metadata. All
  patterns are no-ops in `:base` mode (the whole transformer
  short-circuits if `metadata[:layer] == :base`).

  ## Patterns

  ### 1. Form input shorthand

      <input field={@form[:email]} />

  becomes:

      <input
        name={@form[:email].name}
        value={@form[:email].value || ""}
        data-lavash-bind="form_params.email"
        data-lavash-form="form"
        data-lavash-field="email"
        data-lavash-valid="form_email_valid"
      />

  The `field={...}` attribute is consumed (removed from the
  output). Variants exist for explicit-name inputs without the
  shorthand.

  ### 2. State binding on inputs

      <input value={@count} />

  gets `data-lavash-bind="count"` injected when `:count` is an
  optimistic state field.

  ### 3. Conditional visibility

      <div :if={@open}>...</div>

  gets `data-lavash-visible="open"` injected when `:open` is an
  optimistic boolean field.

  ### 4. Enabled/disabled

      <button disabled={not @valid}>...</button>

  gets `data-lavash-enabled="valid"` injected when `:valid` is an
  optimistic boolean field.

  ### 5. Class toggle

      <div class={if @active, do: "on", else: "off"}>...</div>

  gets `data-lavash-toggle="active|on|off"` injected when
  `:active` is an optimistic boolean field.

  ### 6. Class membership

      <span class={if "x" in @selected, do: "on", else: "off"}>

  gets `data-lavash-member="selected|on|off"` +
  `data-lavash-member-value="x"` injected when `:selected` is an
  optimistic array field.

  ### 7. Reactive attribute derives

  For any attr listed in `metadata[:attr_derives]` (computed by
  `Lavash.Optimistic.Transformers.AnalyzeOptimisticTemplate`), a
  matching `data-lavash-attr-<attr>="<derive_name>"` is injected
  so the JS hook can re-evaluate the attribute client-side.
  """

  @behaviour Lavash.TokenTransformer

  alias Lavash.Template.{AttrHelpers, Walker}

  @impl true
  def transform(nodes, state) do
    metadata = state[:lavash_metadata] || %{}

    if metadata[:layer] == :base do
      nodes
    else
      Walker.walk(nodes,
        metadata: metadata,
        attrs_callback: &inject/4
      )
    end
  end

  # `data-lavash-manual` short-circuits the whole pipeline for the
  # element: don't inject anything. This matches the original
  # behavior where the author wants to opt out of all auto-injection
  # for a specific tag.
  defp inject(name, attrs, _meta, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-manual") do
      attrs
    else
      attrs
      |> maybe_inject_form_input(name, metadata)
      |> maybe_inject_state_binding(name, metadata)
      |> maybe_inject_visibility(metadata)
      |> maybe_inject_enabled(metadata)
      |> maybe_inject_class_toggle(metadata)
      |> maybe_inject_class_member(metadata)
      |> maybe_inject_reactive_attrs(metadata)
    end
  end

  # ============================================
  # Pattern 1: form input shorthand
  # ============================================

  defp maybe_inject_form_input(attrs, name, metadata)
       when name in ["input", "textarea", "select"] do
    forms = metadata[:forms] || %{}

    case AttrHelpers.get_attr_value(attrs, "field") do
      {:expr, expr, _meta} ->
        case parse_form_field_access_expr(expr) do
          {:ok, form, field} ->
            if is_map_key(forms, form) do
              warn_if_form_field_unknown(form, field, forms, metadata)
              inject_full_form_attrs(attrs, form, field)
            else
              maybe_inject_form_input_explicit(attrs, metadata)
            end

          _ ->
            maybe_inject_form_input_explicit(attrs, metadata)
        end

      _ ->
        maybe_inject_form_input_explicit(attrs, metadata)
    end
  end

  defp maybe_inject_form_input(attrs, _name, _metadata), do: attrs

  defp warn_if_form_field_unknown(form, field, forms, metadata) do
    form_info = Map.get(forms, form, %{})
    fields = Map.get(form_info, :fields, []) || []

    if fields != [] and field not in fields do
      require Logger

      Logger.warning(
        "[lavash] <input field={@#{form}[:#{field}]}> in " <>
          "#{metadata[:caller_file] || "template"} — :#{field} is not an " <>
          "attribute of #{inspect(form_info[:resource])}. The input will " <>
          "bind to a non-existent field. Available: " <>
          Enum.map_join(fields, ", ", &inspect/1)
      )
    end

    :ok
  end

  defp maybe_inject_form_input_explicit(attrs, metadata) do
    forms = metadata[:forms] || %{}

    if AttrHelpers.has_attr?(attrs, "data-lavash-bind") do
      attrs
    else
      case AttrHelpers.get_attr_value(attrs, "name") do
        {:expr, expr, _meta} ->
          case parse_form_field_expr(expr) do
            {:ok, form, field} ->
              if is_map_key(forms, form),
                do: inject_form_attrs(attrs, form, field),
                else: attrs

            _ ->
              attrs
          end

        {:string, name_value, _meta} ->
          case parse_form_field_string(name_value) do
            {:ok, form_str, field_str} ->
              form = String.to_atom(form_str)

              if is_map_key(forms, form),
                do: inject_form_attrs(attrs, form, String.to_atom(field_str)),
                else: attrs

            _ ->
              attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp inject_full_form_attrs(attrs, form, field) do
    form_str = to_string(form)
    field_str = to_string(field)

    attrs
    |> AttrHelpers.reject_attr("field")
    |> AttrHelpers.add_attr_if_missing("name", {:expr, "@#{form_str}[:#{field_str}].name"})
    |> AttrHelpers.add_attr_if_missing(
      "value",
      {:expr, "@#{form_str}[:#{field_str}].value || \"\""}
    )
    |> AttrHelpers.add_attr_if_missing(
      "data-lavash-bind",
      {:string, "#{form_str}_params.#{field_str}"}
    )
    |> AttrHelpers.add_attr_if_missing("data-lavash-form", {:string, form_str})
    |> AttrHelpers.add_attr_if_missing("data-lavash-field", {:string, field_str})
    |> AttrHelpers.add_attr_if_missing(
      "data-lavash-valid",
      {:string, "#{form_str}_#{field_str}_valid"}
    )
  end

  defp inject_form_attrs(attrs, form, field) do
    form_str = to_string(form)
    field_str = to_string(field)

    attrs
    |> AttrHelpers.add_attr_if_missing(
      "data-lavash-bind",
      {:string, "#{form_str}_params.#{field_str}"}
    )
    |> AttrHelpers.add_attr_if_missing("data-lavash-form", {:string, form_str})
    |> AttrHelpers.add_attr_if_missing("data-lavash-field", {:string, field_str})
    |> AttrHelpers.add_attr_if_missing(
      "data-lavash-valid",
      {:string, "#{form_str}_#{field_str}_valid"}
    )
  end

  # ============================================
  # Pattern 2: state binding on inputs
  # ============================================

  defp maybe_inject_state_binding(attrs, name, metadata)
       when name in ["input", "textarea", "select"] do
    if AttrHelpers.has_attr?(attrs, "data-lavash-bind") do
      attrs
    else
      case AttrHelpers.get_attr_value(attrs, "value") do
        {:expr, "@" <> field_name, _meta} ->
          field_atom = String.to_atom(field_name)

          if is_map_key(metadata[:optimistic_fields] || %{}, field_atom) do
            AttrHelpers.add_attr_if_missing(attrs, "data-lavash-bind", {:string, field_name})
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  defp maybe_inject_state_binding(attrs, _name, _metadata), do: attrs

  # ============================================
  # Pattern 3: visibility
  # ============================================

  defp maybe_inject_visibility(attrs, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-visible") do
      attrs
    else
      case AttrHelpers.get_attr_value(attrs, ":if") do
        {:expr, "@" <> field_name, _meta} ->
          field_atom = String.to_atom(field_name)

          if optimistic_boolean?(field_atom, metadata) do
            AttrHelpers.add_attr_if_missing(attrs, "data-lavash-visible", {:string, field_name})
          else
            attrs
          end

        _ ->
          attrs
      end
    end
  end

  # ============================================
  # Pattern 4: enabled
  # ============================================

  defp maybe_inject_enabled(attrs, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-enabled") do
      attrs
    else
      case AttrHelpers.get_attr_value(attrs, "disabled") do
        {:expr, expr, _meta} ->
          case parse_negated_field(expr) do
            {:ok, field_name} ->
              field_atom = String.to_atom(field_name)

              if optimistic_boolean?(field_atom, metadata) do
                AttrHelpers.add_attr_if_missing(
                  attrs,
                  "data-lavash-enabled",
                  {:string, field_name}
                )
              else
                attrs
              end

            :error ->
              attrs
          end

        _ ->
          attrs
      end
    end
  end

  # ============================================
  # Pattern 5: class toggle
  # ============================================

  defp maybe_inject_class_toggle(attrs, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-toggle") do
      attrs
    else
      with {:expr, expr, _meta} <- AttrHelpers.get_attr_value(attrs, "class"),
           {:ok, field_name, true_str, false_str} <- parse_boolean_class_if(expr),
           field_atom = safe_existing_atom(field_name),
           true <- not is_nil(field_atom),
           true <- optimistic_boolean?(field_atom, metadata) do
        value = "#{field_name}|#{true_str}|#{false_str}"
        AttrHelpers.add_attr_if_missing(attrs, "data-lavash-toggle", {:string, value})
      else
        _ -> attrs
      end
    end
  end

  # ============================================
  # Pattern 6: class membership
  # ============================================

  defp maybe_inject_class_member(attrs, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-member") do
      attrs
    else
      with {:expr, expr, _meta} <- AttrHelpers.get_attr_value(attrs, "class"),
           {:ok, value_str, field_name, true_str, false_str} <- parse_membership_class_if(expr),
           field_atom = safe_existing_atom(field_name),
           true <- not is_nil(field_atom),
           true <- is_map_key(metadata[:optimistic_fields] || %{}, field_atom) do
        directive = "#{field_name}|#{true_str}|#{false_str}"

        attrs
        |> AttrHelpers.add_attr_if_missing("data-lavash-member", {:string, directive})
        |> AttrHelpers.add_attr_if_missing("data-lavash-member-value", {:string, value_str})
      else
        _ -> attrs
      end
    end
  end

  # ============================================
  # Pattern 7: reactive attribute derives
  # ============================================

  defp maybe_inject_reactive_attrs(attrs, metadata) do
    attr_derives = metadata[:attr_derives] || []

    Enum.reduce(attr_derives, attrs, fn derive, acc ->
      lavash_attr = "data-lavash-attr-#{derive.attr}"

      if AttrHelpers.has_attr?(acc, lavash_attr) do
        acc
      else
        case AttrHelpers.get_attr_value(acc, derive.attr) do
          {:expr, expr, _meta} ->
            deps = derive.deps
            has_dep = Enum.any?(deps, fn dep -> String.contains?(expr, "@#{dep}") end)

            if has_dep do
              AttrHelpers.add_attr_if_missing(acc, lavash_attr, {:string, derive.name})
            else
              acc
            end

          _ ->
            acc
        end
      end
    end)
  end

  # ============================================
  # Parsing helpers
  # ============================================

  defp parse_form_field_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]\.name/, expr) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  defp parse_form_field_string(name) do
    case Regex.run(~r/^(\w+)\[(\w+)\]$/, name) do
      [_, form, field] -> {:ok, form, field}
      nil -> :error
    end
  end

  defp parse_form_field_access_expr(expr) do
    case Regex.run(~r/@(\w+)\[:(\w+)\]$/, String.trim(expr)) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  defp parse_negated_field(expr) do
    case Regex.run(~r/^not\s+@(\w+)$/, String.trim(expr)) do
      [_, field] -> {:ok, field}
      nil -> :error
    end
  end

  defp parse_boolean_class_if(source) do
    case Code.string_to_quoted(source) do
      {:ok,
       {:if, _,
        [
          {:@, _, [{field, _, ctx}]},
          [do: true_branch, else: false_branch]
        ]}}
      when is_atom(field) and is_atom(ctx) ->
        with {:ok, t} <- as_class_string(true_branch),
             {:ok, f} <- as_class_string(false_branch) do
          {:ok, Atom.to_string(field), t, f}
        end

      _ ->
        :error
    end
  end

  defp parse_membership_class_if(source) do
    case Code.string_to_quoted(source) do
      {:ok,
       {:if, _,
        [
          {:in, _, [value_ast, {:@, _, [{field, _, ctx}]}]},
          [do: true_branch, else: false_branch]
        ]}}
      when is_atom(field) and is_atom(ctx) ->
        with {:ok, val} <- as_member_value(value_ast),
             {:ok, t} <- as_class_string(true_branch),
             {:ok, f} <- as_class_string(false_branch) do
          {:ok, val, Atom.to_string(field), t, f}
        end

      _ ->
        :error
    end
  end

  defp as_class_string(s) when is_binary(s), do: {:ok, s}
  defp as_class_string(nil), do: {:ok, ""}
  defp as_class_string(_), do: :error

  defp as_member_value(s) when is_binary(s), do: {:ok, s}
  defp as_member_value(a) when is_atom(a), do: {:ok, Atom.to_string(a)}
  defp as_member_value(_), do: :error

  defp optimistic_boolean?(field_atom, metadata) do
    cond do
      is_map_key(metadata[:optimistic_fields] || %{}, field_atom) ->
        field = metadata[:optimistic_fields][field_atom]
        field.type == :boolean

      is_map_key(metadata[:calculations] || %{}, field_atom) ->
        true

      true ->
        false
    end
  end

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
