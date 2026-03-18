defmodule Lavash.Component.OptimisticWrapper do
  @moduledoc false

  @doc """
  Wraps inner rendered content in a LavashOptimistic hook root div.

  Used for components with optimistic features (actions, calculations,
  subtree derives) that use data-lavash-* substitution instead of a
  full client-side JS render function.
  """
  def wrap(assigns, inner_rendered) do
    id = to_iodata(assigns.id)
    target = to_iodata(assigns.myself)
    module_name = to_iodata(assigns.__module_name__)
    state = escape_attr(assigns.__state_json__)
    version = to_iodata(assigns.__version__)
    bindings = escape_attr(assigns.__bindings_json__)

    %Phoenix.LiveView.Rendered{
      static: [
        "<div id=\"", "\" phx-hook=\"LavashOptimistic\" phx-target=\"",
        "\" data-lavash-component data-lavash-module=\"", "\" data-lavash-state=\"",
        "\" data-lavash-version=\"", "\" data-lavash-bindings=\"", "\">",
        "</div>"
      ],
      dynamic: fn _ ->
        [id, target, module_name, state, version, bindings, inner_rendered]
      end,
      fingerprint: :erlang.phash2({:lavash_optimistic_root, assigns.__module_name__}),
      root: true
    }
  end

  defp to_iodata(val) when is_binary(val), do: val
  defp to_iodata(val) when is_integer(val), do: Integer.to_string(val)
  defp to_iodata(val) when is_atom(val), do: Atom.to_string(val)
  defp to_iodata(%Phoenix.LiveComponent.CID{} = cid), do: to_string(cid)
  defp to_iodata(val), do: to_string(val)

  defp escape_attr(val) when is_binary(val) do
    val
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
