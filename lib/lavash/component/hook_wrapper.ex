defmodule Lavash.Component.HookWrapper do
  @moduledoc false

  @doc """
  Wraps inner rendered content in a hook root div.
  Returns a Phoenix.LiveView.Rendered struct.
  """
  def wrap(assigns, inner_rendered) do
    id = to_iodata(assigns.id)
    hook = to_iodata(assigns.__hook_name__)
    target = to_iodata(assigns.myself)
    state = escape_attr(assigns.__state_json__)
    version = to_iodata(assigns.__version__)
    bindings = escape_attr(assigns.__bindings_json__)

    %Phoenix.LiveView.Rendered{
      static: [
        "<div id=\"", "\" phx-hook=\"", "\" phx-target=\"",
        "\" data-lavash-state=\"", "\" data-lavash-version=\"",
        "\" data-lavash-bindings=\"", "\">", "</div>"
      ],
      dynamic: fn _ ->
        [id, hook, target, state, version, bindings, inner_rendered]
      end,
      fingerprint: :erlang.phash2({:lavash_hook_root, assigns.__hook_name__}),
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
