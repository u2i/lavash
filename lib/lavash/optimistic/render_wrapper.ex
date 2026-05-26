defmodule Lavash.Optimistic.RenderWrapper do
  @moduledoc """
  Layer-4 render wrapper: wraps the user's render output in a
  `<div phx-hook="LavashOptimistic" ...>` carrying the optimistic
  state JSON, version, and URL-field hints the JS client uses to
  hydrate.

  Originally `Lavash.LiveView.Runtime.wrap_render/3` (layer 1);
  relocated per `docs/ARCHITECTURE.md` punchlist item #8 so a
  layer-2-only build can skip the wrap entirely.

  ## How it gets invoked

  `Lavash.LiveView.Transformers.CompileLiveView` emits a `render/1`
  whose tail invokes `Lavash.LiveView.Runtime.wrap_render/3`. That
  layer-1 function checks for this module via
  `Code.ensure_loaded?` + `function_exported?` and, if present,
  calls into `wrap_render/3`. Modules without the optimism
  extension fall through to `inner_content` unchanged.

  ## What the wrapper produces

  A `Phoenix.LiveView.Rendered` struct whose static parts are the
  wrapper div tags and whose dynamic parts include the user's
  inner content plus the serialized optimistic state. Fingerprint
  is structural only (module name + URL field list) so LiveView's
  diff machinery doesn't treat each render as a brand-new
  template.
  """

  def wrap_render(module, assigns, inner_content) do
    optimistic_fields = module.__lavash__(:optimistic_fields)

    if optimistic_fields == [] do
      # No optimistic fields → no wrap needed even though the
      # extension is registered. Cheaper than a transformer-time
      # gate because some modules use optimism partially.
      inner_content
    else
      optimistic_state = Lavash.LiveView.Helpers.optimistic_state(module, assigns)
      module_name = inspect(module)
      optimistic_json = Lavash.JSON.encode!(optimistic_state)

      version =
        case assigns do
          %{__changed__: _} = a ->
            socket = Map.get(a, :socket)
            if socket, do: Lavash.Optimistic.Version.get(socket), else: 0

          _ ->
            0
        end

      has_optimistic_js = optimistic_fields != []

      url_field_names =
        module.__lavash__(:url_fields)
        |> Enum.map(& &1.name)

      escaped_module = Phoenix.HTML.Safe.to_iodata(module_name)
      escaped_json = Phoenix.HTML.Safe.to_iodata(optimistic_json)
      escaped_url_fields = Phoenix.HTML.Safe.to_iodata(Jason.encode!(url_field_names))
      version_str = to_string(version)

      %Phoenix.LiveView.Rendered{
        static: [
          ~s(<div id="lavash-optimistic-root" phx-hook="LavashOptimistic" data-lavash-module="),
          ~s(" data-lavash-state="),
          ~s(" data-lavash-version="),
          ~s(" data-lavash-url-fields="),
          ~s(">),
          ~s(</div>)
        ],
        dynamic: fn _ ->
          [
            escaped_module,
            escaped_json,
            version_str,
            escaped_url_fields,
            inner_content
          ]
        end,
        # IMPORTANT: fingerprint must NOT include dynamic values
        # (state, version) that change on every update. Including
        # them causes LiveView to treat this as a brand-new template,
        # wiping out the component registry and breaking CID-based
        # event targeting.
        fingerprint: :erlang.phash2({module_name, url_field_names, has_optimistic_js}),
        root: true
      }
    end
  end
end
