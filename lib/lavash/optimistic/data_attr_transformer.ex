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

  ### 3. Conditional visibility (manual only)

  `:if={@open}` blocks over optimistic fields ride subtree derives —
  the block is re-rendered client-side, which handles BOTH directions
  (a class-based directive can't show an element `:if` removed from
  the DOM), so no `data-lavash-visible` is auto-injected. The
  show/hide-by-class idiom (`class={if !@open, do: "hidden"}`) rides
  pattern-7 attribute derives.

  `data-lavash-visible="field"` remains a supported hand-written
  annotation for non-lavash templates; its JS toggles a `hidden`
  class.

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

  Also matched (#129): the nil-safe list (`value in (@selected ||
  [])`), prop-ref class branches (`do: @active_class` — the
  directive becomes an interpolated expression resolved at render),
  and a loop-variable value — which injects no `member-value` and
  requires the element to carry `phx-value-val`, the per-row value
  the JS reads inside `:for` loops (the ChipSet shape).

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

  # Component-call injection (#123) — same patterns as HTML tags.
  #
  # Component calls are opaque at transform time (Phoenix defers its
  # own component-call validation to post-compile verification, so
  # target attrs can't be resolved here), and injecting a LITERAL
  # `data-lavash-*` attr would trip "undefined attribute" warnings on
  # components without a `:global` rest.
  #
  # So the annotations are injected as a single **dynamic attr
  # spread** — `{%{"data-lavash-enabled" => "valid"}}` — which
  # compile-time validation ignores by construction (spread contents
  # are unknowable), and which at runtime merges into assigns and
  # follows the component's own `:global` forwarding. The result is
  # exactly HTML-tag parity in Phoenix's sense: the annotation lands
  # wherever the component splats `:rest` — the same place a
  # hand-written `phx-click` or `data-*` attr would go — and on a
  # component that doesn't forward, it goes nowhere, just like any
  # other passthrough attr.
  defp inject_node({:block, comp_type, name, attrs, children, om, cm}, _parent, metadata)
       when comp_type in [:local_component, :remote_component] do
    [{:block, comp_type, name, inject_component_attrs(attrs, metadata), children, om, cm}]
  end

  defp inject_node({:self_close, comp_type, name, attrs, meta}, _parent, metadata)
       when comp_type in [:local_component, :remote_component] do
    [{:self_close, comp_type, name, inject_component_attrs(attrs, metadata), meta}]
  end

  defp inject_node(node, _parent, _metadata), do: [node]

  defp inject_component_attrs(attrs, metadata) do
    if AttrHelpers.has_attr?(attrs, "data-lavash-manual") do
      attrs
    else
      annotations =
        %{}
        |> put_component_enabled(attrs, metadata)
        |> put_component_attr_derives(attrs, metadata)

      if annotations == %{} do
        attrs
      else
        attrs ++ [component_annotation_spread(annotations)]
      end
    end
  end

  defp put_component_enabled(annotations, attrs, metadata) do
    with false <- AttrHelpers.has_attr?(attrs, "data-lavash-enabled"),
         {:expr, expr, _meta} <- AttrHelpers.get_attr_value(attrs, "disabled"),
         {:ok, field_name} <- parse_negated_field(expr),
         field_atom = safe_existing_atom(field_name),
         true <- not is_nil(field_atom),
         true <- optimistic_boolean?(field_atom, metadata) do
      Map.put(annotations, "data-lavash-enabled", field_name)
    else
      _ -> annotations
    end
  end

  defp put_component_attr_derives(annotations, attrs, metadata) do
    Enum.reduce(metadata[:attr_derives] || [], annotations, fn derive, acc ->
      lavash_attr = "data-lavash-attr-#{derive.attr}"

      with false <- AttrHelpers.has_attr?(attrs, lavash_attr),
           {:expr, expr, _meta} <- AttrHelpers.get_attr_value(attrs, derive.attr),
           true <- derive_matches_expr?(derive, expr) do
        Map.put(acc, lavash_attr, derive.name)
      else
        _ -> acc
      end
    end)
  end

  defp component_annotation_spread(annotations) do
    # Component assigns are atom-keyed (string keys blow up inside
    # components that Keyword-process their extras, e.g. <.form>'s
    # to_form options) — emit atom keys; :global matching is by the
    # "data-" prefix of the stringified name either way.
    entries =
      annotations
      |> Enum.sort()
      |> Enum.map_join(", ", fn {key, value} ->
        "#{inspect(key)}: #{inspect(value)}"
      end)

    meta = %{line: 0, column: 0}
    {:root, {:expr, "%{#{entries}}", meta}, meta}
  end

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
           {:ok, member_value, field_name, true_cls, false_cls} <-
             parse_membership_class_if(expr),
           field_atom = safe_existing_atom(field_name),
           true <- not is_nil(field_atom),
           true <- is_map_key(metadata[:optimistic_fields] || %{}, field_atom),
           {:ok, attrs} <- add_member_value(attrs, member_value) do
        AttrHelpers.add_attr_if_missing(
          attrs,
          "data-lavash-member",
          member_directive(field_name, true_cls, false_cls)
        )
      else
        _ -> attrs
      end
    end
  end

  # Literal member values ride data-lavash-member-value; a loop
  # variable (the ChipSet shape — `value in @selected` inside :for)
  # can't be injected statically, so the element must already carry
  # phx-value-val, which the JS reads as the per-row value (#129).
  defp add_member_value(attrs, {:literal, value_str}) do
    {:ok,
     AttrHelpers.add_attr_if_missing(attrs, "data-lavash-member-value", {:string, value_str})}
  end

  defp add_member_value(attrs, :loop_var) do
    if AttrHelpers.has_attr?(attrs, "phx-value-val"), do: {:ok, attrs}, else: :error
  end

  # Literal class branches produce a static directive; prop-ref
  # branches (`do: @active_class`) produce an interpolated expression
  # attr so the directive resolves at render time (#129).
  defp member_directive(field_name, true_cls, false_cls) do
    if match?({:literal, _}, true_cls) and match?({:literal, _}, false_cls) do
      {:literal, t} = true_cls
      {:literal, f} = false_cls
      {:string, "#{field_name}|#{t}|#{f}"}
    else
      {:expr,
       ~s("#{field_name}|" <> #{member_cls_source(true_cls)} <> "|" <> #{member_cls_source(false_cls)}),
       %{line: 0, column: 0}}
    end
  end

  defp member_cls_source({:literal, s}), do: inspect(s)
  defp member_cls_source({:prop, name}), do: "(@#{name} || \"\")"

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
       {:if, _, [{:in, _, [value_ast, selected_ast]}, [do: true_branch, else: false_branch]]}} ->
        with {:ok, field} <- member_field(selected_ast),
             {:ok, val} <- as_member_value(value_ast),
             {:ok, t} <- as_member_class(true_branch),
             {:ok, f} <- as_member_class(false_branch) do
          {:ok, val, Atom.to_string(field), t, f}
        end

      _ ->
        :error
    end
  end

  # `value in @selected` and the nil-safe `value in (@selected || [])`
  defp member_field({:@, _, [{field, _, ctx}]}) when is_atom(field) and is_atom(ctx),
    do: {:ok, field}

  defp member_field({:||, _, [{:@, _, [{field, _, ctx}]}, []]})
       when is_atom(field) and is_atom(ctx),
       do: {:ok, field}

  defp member_field(_), do: :error

  # Class branches: string literals, or prop refs like @active_class
  # (resolved at render time via an interpolated directive)
  defp as_member_class({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: {:ok, {:prop, name}}

  defp as_member_class(branch) do
    with {:ok, s} <- as_class_string(branch), do: {:ok, {:literal, s}}
  end

  defp as_class_string(s) when is_binary(s), do: {:ok, s}
  defp as_class_string(nil), do: {:ok, ""}
  defp as_class_string(_), do: :error

  defp as_member_value(s) when is_binary(s), do: {:ok, {:literal, s}}

  # A bare lowercase variable (no @) is a :for loop binding — the
  # per-row value must come from phx-value-val at runtime (#129)
  defp as_member_value({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {:ok, :loop_var}

  defp as_member_value(a) when is_atom(a), do: {:ok, {:literal, Atom.to_string(a)}}
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
