defmodule Rez.AST.Helper do
  @moduledoc """
  `Rez.AST.Helper` defines the %Helper struct that represents a @helper in-game
  element. A Helper contains a function defining a Handlebars helper.
  """

  defstruct [
    status: :ok,
    position: {nil, 0, 0},
    id: nil,
    attributes: %{},
  ]
end

defimpl Rez.AST.Node, for: Rez.AST.Helper do
  import Rez.AST.NodeValidator
  alias Rez.AST.NodeHelper

  def node_type(_helper), do: "helper"

  def pre_process(helper), do: helper

  def process(helper), do: helper

  def children(_helper), do: []

  def validators(helper) do
    params = helper
    |> NodeHelper.get_attr_value("args", [])
    |> Enum.map(fn {:string, param} -> param end)

    [
      attribute_present?("name",
        attribute_has_type?(:string)),

      attribute_present?("args",
        attribute_has_type?(:list,
          attribute_coll_of?(:string))),

      attribute_present?("handler",
        attribute_has_type?(:function,
          validate_expects_params?(params)))
    ]
  end
end
