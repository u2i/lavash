defmodule Lavash.Template.LinkRewriteTest do
  @moduledoc """
  `<.link>` rewriting in `Lavash.Template.parse/2`: the component is
  rewritten to the anchor `Phoenix.Component.link/1` renders, so links
  inside optimistic subtrees survive client-side re-renders instead of
  vanishing until the server repaints (the disappearing-checkout bug).
  """
  use ExUnit.Case, async: true

  defp parse!(source, opts \\ []) do
    source |> Lavash.Template.tokenize() |> Lavash.Template.parse(opts)
  end

  test "navigate rewrites to a redirect anchor with attrs passed through" do
    [{:element, "a", attrs, [{:text, "Checkout"}], _meta}] =
      parse!(~s(<.link navigate="/checkout" class="btn">Checkout</.link>))

    assert {"href", {:string, "/checkout"}} in attrs
    assert {"data-phx-link", {:string, "redirect"}} in attrs
    assert {"data-phx-link-state", {:string, "push"}} in attrs
    assert {"class", {:string, "btn"}} in attrs
    refute Enum.any?(attrs, &match?({"navigate", _}, &1))
  end

  test "patch rewrites to a patch anchor; replace flips the link state" do
    [{:element, "a", attrs, _, _}] = parse!(~s(<.link patch="/page?tab=2" replace>Tab</.link>))

    assert {"data-phx-link", {:string, "patch"}} in attrs
    assert {"data-phx-link-state", {:string, "replace"}} in attrs
    refute Enum.any?(attrs, &match?({"replace", _}, &1))
  end

  test "plain href rewrites to a bare anchor without phx attrs" do
    [{:element, "a", attrs, _, _}] = parse!(~s(<.link href="https://x.dev">X</.link>))

    assert {"href", {:string, "https://x.dev"}} in attrs
    refute Enum.any?(attrs, &match?({"data-phx-link", _}, &1))
  end

  test "expr-valued targets and non-GET methods fall back to component handling" do
    # Not rewritable → dropped by default, children spliced when descending;
    # never a half-correct anchor.
    assert [] = parse!(~s(<.link navigate={@path}>Dyn</.link>))

    assert [{:text, "Dyn"}] =
             parse!(~s(<.link navigate={@path}>Dyn</.link>), descend_components: true)

    assert [] = parse!(~s(<.link href="/x" method="delete">Del</.link>))

    assert [{:text, "Del"}] =
             parse!(~s(<.link href="/x" method="delete">Del</.link>), descend_components: true)
  end

  test "rewritten anchors transpile into subtree JS" do
    [node] =
      parse!(
        ~s(<div :if={@open}><.link navigate="/checkout" class="btn">Checkout</.link></div>),
        descend_components: true
      )

    js = Lavash.Component.JsGenerator.subtree_to_js(node)

    assert js =~
             ~s(<a href="/checkout" data-phx-link="redirect" data-phx-link-state="push" class="btn">Checkout</a>)
  end
end
