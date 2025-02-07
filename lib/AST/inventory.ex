defmodule Rez.AST.Inventory do
  @moduledoc """
  `Rez.AST.Inventory` contains the `Inventory` struct.

  An `Inventory` represents the idea of a container that uses `Slots` to
  control and reflect what it contains.
  """
  defstruct [
    status: :ok,
    position: {nil, 0, 0},
    id: nil,
    attributes: %{}
  ]
end

defimpl Rez.AST.Node, for: Rez.AST.Inventory do
  import Rez.AST.NodeValidator
  alias Rez.AST.{NodeHelper}

  def node_type(_inventory), do: "inventory"

  def pre_process(inventory) do
    inventory
    |> NodeHelper.set_boolean_attr("apply_effects", false)
  end

  def process(inventory), do: NodeHelper.process_collection(inventory, :slots)

  def children(_inventory), do: []

  def validators(_inventory) do
    [
      attribute_present?("slots",
        attribute_has_type?(:set,
          attribute_not_empty_coll?(
            attribute_coll_of?(:elem_ref,
              attribute_list_references?("slot")
            )))),

      attribute_if_present?("apply_effects",
        attribute_has_type?(:boolean)),

      attribute_if_present?("owner",
        attribute_has_type?(:elem_ref)),

      attribute_if_present?("on_insert",
        attribute_has_type?(:function)),

      attribute_if_present?("on_remove",
        attribute_has_type?(:function))
    ]
  end
end
