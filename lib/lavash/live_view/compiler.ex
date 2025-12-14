defmodule Lavash.LiveView.Compiler do
  @moduledoc """
  Compiles the Lavash DSL into LiveView callbacks.
  """

  defmacro __before_compile__(_env) do
    quote do
      @impl Phoenix.LiveView
      def mount(params, session, socket) do
        Lavash.LiveView.Runtime.mount(__MODULE__, params, session, socket)
      end

      @impl Phoenix.LiveView
      def handle_params(params, uri, socket) do
        Lavash.LiveView.Runtime.handle_params(__MODULE__, params, uri, socket)
      end

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) do
        Lavash.LiveView.Runtime.handle_event(__MODULE__, event, params, socket)
      end

      @impl Phoenix.LiveView
      def handle_info(msg, socket) do
        Lavash.LiveView.Runtime.handle_info(__MODULE__, msg, socket)
      end

      # Introspection functions
      def __lavash__(:url_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :url])
      end

      def __lavash__(:ephemeral_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :ephemeral])
      end

      def __lavash__(:socket_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:state, :socket])
      end

      def __lavash__(:derived_fields) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:derived])
      end

      def __lavash__(:assigns) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:assigns])
      end

      def __lavash__(:actions) do
        Spark.Dsl.Extension.get_entities(__MODULE__, [:actions])
      end
    end
  end
end
