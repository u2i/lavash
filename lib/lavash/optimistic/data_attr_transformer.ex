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

  The show/hide-by-class idiom (element kept in the DOM) is covered
  by pattern 7 instead: `class={if !@open, do: "hidden"}` (or any
  conditional class expression) gets a reactive attribute derive
  that recomputes the class client-side.

  ### 4. Enabled/disabled

      <button disabled={not @valid}>...</button>

  gets `data-lavash-enabled="valid"` injected when `:valid` is an
  optimistic boolean field.

  ### 5. Class toggle (manual only)

  Conditional class expressions are handled generally by pattern 7
  (a transpiled derive recomputes the full attribute client-side),
  so no toggle is auto-injected. `data-lavash-toggle="field|on|off"`
  remains a supported hand-written annotation for places the
  pipeline can't reach — component calls (`<.form>`,
  `CoreComponents.button`) and non-lavash templates.

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
        attrs_callback: &inject/4,
        node_callback: &inject_node/3
      )
    end
  end

  # ============================================
  # Node-level patterns (need children access)
  # ============================================

  # Pattern 2b: select binding derived from option selected= exprs.
  #
  #     <select>
  #       <option value="name" selected={@sort == :name}>...</option>
  #       ...
  #     </select>
  #
  # gets data-lavash-bind="sort" when every option's selected=
  # expression references the same single optimistic state field.
  # Runs after attrs_callback, so a select already bound by the
  # form-input patterns (or by hand) is left alone.
  defp inject_node({:block, :tag, "select", attrs, children, om, cm} = node, _parent, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-bind") or
         AttrHelpers.has_attr?(attrs, "data-lavash-manual") do
      [node]
    else
      case single_optimistic_field(option_selected_exprs(children), metadata) do
        {:ok, field_name} ->
          new_attrs =
            AttrHelpers.add_attr_if_missing(attrs, "data-lavash-bind", {:string, field_name})

          [{:block, :tag, "select", new_attrs, children, om, cm}]

        :error ->
          [node]
      end
    end
  end

  # Pattern 2c: textarea binding from a bare body expression.
  #
  #     <textarea>{@notes}</textarea>
  #
  # gets data-lavash-bind="notes" when :notes is an optimistic
  # state field (textareas carry their value in the body, so the
  # value={...} form of pattern 2 never applies).
  defp inject_node({:block, :tag, "textarea", attrs, children, om, cm} = node, _parent, metadata) do
    with false <-
           AttrHelpers.has_attr?(attrs, "data-lavash-bind") or
             AttrHelpers.has_attr?(attrs, "data-lavash-manual"),
         [{:body_expr, expr, _meta}] <- Enum.reject(children, &blank_text?/1),
         "@" <> field_name <- String.trim(expr),
         true <- optimistic_state_field?(field_name, metadata) do
      new_attrs =
        AttrHelpers.add_attr_if_missing(attrs, "data-lavash-bind", {:string, field_name})

      [{:block, :tag, "textarea", new_attrs, children, om, cm}]
    else
      _ -> [node]
    end
  end

  defp inject_node(node, _parent, _metadata), do: [node]

  defp option_selected_exprs(children) do
    Enum.flat_map(children, fn
      {:block, :tag, "option", opt_attrs, _children, _om, _cm} ->
        selected_expr(opt_attrs)

      {:self_close, :tag, "option", opt_attrs, _meta} ->
        selected_expr(opt_attrs)

      _ ->
        []
    end)
  end

  defp selected_expr(opt_attrs) do
    case AttrHelpers.get_attr_value(opt_attrs, "selected") do
      {:expr, expr, _meta} -> [expr]
      _ -> []
    end
  end

  # All expressions must agree on exactly one optimistic state field.
  defp single_optimistic_field([], _metadata), do: :error

  defp single_optimistic_field(exprs, metadata) do
    fields =
      exprs
      |> Enum.flat_map(fn expr ->
        Regex.scan(~r/@(\w+[?!]?)/, expr) |> Enum.map(fn [_, f] -> f end)
      end)
      |> Enum.uniq()

    case fields do
      [field_name] ->
        if optimistic_state_field?(field_name, metadata), do: {:ok, field_name}, else: :error

      _ ->
        :error
    end
  end

  defp optimistic_state_field?(field_name, metadata) do
    is_map_key(metadata[:optimistic_fields] || %{}, String.to_atom(field_name))
  end

  defp blank_text?({:text, text, _meta}), do: String.trim(text) == ""
  defp blank_text?(_), do: false

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
            if derive_matches_expr?(derive, expr) do
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

  # A derive belongs to an element only when it was extracted from this
  # element's exact attribute expression. Matching by dependency overlap
  # (the old behavior) attached a derive from ANOTHER element whenever
  # two attr expressions shared an optimistic field — e.g. an element
  # whose own expression was untranspilable (and therefore had no
  # derive) inherited a sibling's derive and had its attribute
  # overwritten with the sibling's value (issue #43: the checkout
  # address list got the toggle arrow's "hidden" class).
  defp derive_matches_expr?(%{source: source}, expr) when is_binary(source) do
    normalize_expr(expr) == source
  end

  defp derive_matches_expr?(_derive, _expr), do: false

  defp normalize_expr(expr) do
    expr |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # ============================================
  # Parsing helpers
  # ============================================

  defp parse_form_field_expr(expr) do
    case Regex.run(~r/@(\w+[?!]?)\[:(\w+[?!]?)\]\.name/, expr) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  defp parse_form_field_string(name) do
    case Regex.run(~r/^(\w+[?!]?)\[(\w+[?!]?)\]$/, name) do
      [_, form, field] -> {:ok, form, field}
      nil -> :error
    end
  end

  defp parse_form_field_access_expr(expr) do
    case Regex.run(~r/@(\w+[?!]?)\[:(\w+[?!]?)\]$/, String.trim(expr)) do
      [_, form, field] -> {:ok, String.to_atom(form), String.to_atom(field)}
      nil -> :error
    end
  end

  defp parse_negated_field(expr) do
    case Regex.run(~r/^not\s+@(\w+[?!]?)$/, String.trim(expr)) do
      [_, field] -> {:ok, field}
      nil -> :error
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
