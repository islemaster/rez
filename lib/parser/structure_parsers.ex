defmodule Rez.Parser.StructureParsers do
  @moduledoc """
  `Rez.Parser.StructureParsers` implements functions for "templated" parsers
  for blocks and lists which have a different directive but share internal
  structure, e.g. a block with an id and attributes.
  """

  alias Ergo.Context
  import Ergo.{Combinators, Terminals, Meta}

  alias LogicalFile

  alias Rez.AST.Node
  import Rez.Parser.{UtilityParsers, AttributeParser}
  import Rez.Parser.ValueParsers, only: [keyword_value: 0]
  import Rez.Parser.IdentifierParser, only: [js_identifier: 1]

  import Rez.Utils, only: [attr_list_to_map: 1]

  def attribute_list() do
    many(
      sequence(
        [
          iws(),
          attribute()
        ],
        label: "attr_list",
        ast: &List.first/1
      )
    )
  end

  def attribute_and_child_list(child_parser) do
    many(
      sequence(
        [
          iws(),
          choice(
            [
              child_parser,
              attribute()
            ],
            debug: true,
            label: "attr_or_child_elem"
          )
        ],
        debug: true,
        label: "attr_or_child",
        ast: &List.first/1
      ),
      debug: true,
      label: "attr_and_child_list",
      ast: fn ast ->
        # Split the list into a tuple of lists {children (structs), attributes}
        Enum.split_with(ast, &is_struct(&1, Rez.AST.Attribute))
      end
    )
  end

  # def create_block(block_struct, nil, attributes, source_file, source_line, col)
  #     when is_map(attributes) and is_binary(source_file) do
  #   IO.puts("create_block:nil")
  #   Node.pre_process(
  #     struct(
  #       block_struct,
  #       position: {source_file, source_line, col},
  #       attributes: attributes))
  # end

  def create_block(block_struct, id, attributes, source_file, source_line, col)
      when is_map(attributes) and is_binary(source_file) do
    Node.pre_process(
      struct(
        block_struct,
        position: {source_file, source_line, col},
        id: id,
        attributes: attributes
      ))
  end

  # Does the twin jobs of setting the AST to point to the block and map the ID of
  # into the id_map.
  def ctx_with_block_and_id_mapped(%Context{data: %{id_map: id_map} = data} = ctx, block, id, label, file, line) do
    case Map.get(id_map, id) do
      nil ->
        %{ctx | ast: block, data: %{data | id_map: Map.put(id_map, id, {label, file, line})}}

      {o_label, o_file, o_line} ->
        %{ctx | ast: block, data: %{data | id_map: Map.put(id_map, id, [{label, file, line}, {o_label, o_file, o_line}])}}

      matches when is_list(matches) ->
        %{ctx | ast: block, data: %{data | id_map: Map.put(id_map, id, [{label, file, line} | matches])}}
    end
  end

  # Parser for a block that has no author assigned id or children. The id_fn
  # parameter is expected to return a generated ID, otherwise a random ID will
  # be assigned. The id_fn is passed the map of attributes
  def block(label, block_struct, id_fn) do
    sequence(
      [
        iliteral("@#{label}"),
        iws(),
        commit(),
        block_begin(label),
        attribute_list(),
        iws(),
        block_end(label)
      ],
      label: "#{label}-block",
      debug: true,
      ctx: fn %Context{
                entry_points: [{line, col} | _],
                ast: [attr_list | []],
                data: %{source: source}
              } = ctx ->
        attributes = attr_list_to_map(attr_list)
        {source_file, source_line} = LogicalFile.resolve_line(source, line)
        auto_id = id_fn.(attributes)
        block = create_block(block_struct, auto_id, attributes, source_file, source_line, col)
        ctx_with_block_and_id_mapped(ctx, block, auto_id, label, source_file, source_line)
      end,
      err: fn %Context{entry_points: [{line, col} | _]} = ctx ->
        Context.add_error(
          ctx,
          :block_not_matched,
          "#{to_string(block_struct)}/#{label} @ #{line}:#{col}"
        )
      end
    )
  end

  def block_with_id(label, block_struct) do
    sequence(
      [
        iliteral("@#{label}"),
        iws(),
        commit(),
        js_identifier("#{label}_id"),
        iws(),
        block_begin(label),
        attribute_list(),
        iws(),
        block_end(label)
      ],
      label: "#{label}-block",
      debug: true,
      ctx: fn %Context{
                entry_points: [{line, col} | _],
                ast: [id, attr_list | []],
                data: %{source: source}
              } = ctx ->
        attributes = attr_list_to_map(attr_list)
        {source_file, source_line} = LogicalFile.resolve_line(source, line)
        block = create_block(block_struct, id, attributes, source_file, source_line, col)
        ctx_with_block_and_id_mapped(ctx, block, id, label, source_file, source_line)
        end,
      err: fn %Context{entry_points: [{line, col} | _]} = ctx ->
        Context.add_error(
          ctx,
          :block_not_matched,
          "#{to_string(block_struct)}/#{label} @ #{line}:#{col}"
        )
      end
    )
  end

  def block_with_id_opt_attributes(label, block_struct) do
    sequence(
      [
        iliteral("@#{label}"),
        iws(),
        commit(),
        js_identifier("#{label}_id"),
        optional(
          sequence(
            [
              iws(),
              block_begin(label),
              attribute_list(),
              iws(),
              block_end(label)
            ],
            ast: &List.first/1
          )
        )
      ],
      label: "#{label}-block",
      debug: true,
      ctx: fn %Context{entry_points: [{line, col} | _], ast: ast, data: %{source: source}} = ctx ->
        {source_file, source_line} = LogicalFile.resolve_line(source, line)

        {id, block} = case ast do
          [id] ->
            {id, create_block(block_struct, id, %{}, source_file, source_line, col)}

          [id, attr_list] ->
            {id, create_block(block_struct, id, attr_list_to_map(attr_list), source_file, source_line, col)}
        end

        ctx_with_block_and_id_mapped(ctx, block, id, label, source_file, source_line)
      end,
      err: fn %Context{entry_points: [{line, col} | _]} = ctx ->
        Context.add_error(
          ctx,
          :block_not_matched,
          "#{to_string(block_struct)}/#{label} @ #{line}:#{col}"
        )
      end
    )
  end

  def block_with_children(label, block_struct, child_parser, add_fn) when is_function(add_fn) do
    sequence(
      [
        iliteral("@#{label}"),
        iws(),
        commit(),
        block_begin(label),
        attribute_and_child_list(child_parser),
        iws(),
        block_end(label)
      ],
      label: "#{label}-block",
      debug: true,
      ctx: fn %Context{
                entry_points: [{line, col} | _],
                ast: [{attr_list, children} | []],
                data: %{source: source}
              } = ctx ->
        {source_file, source_line} = LogicalFile.resolve_line(source, line)

        block =
          Enum.reduce(
            children,
            create_block(block_struct, nil, attr_list_to_map(attr_list), source_file, source_line, col),
            add_fn
          )

        ctx_with_block_and_id_mapped(ctx, block, label, label, source_file, source_line)
      end,
      err: fn %Context{} = ctx ->
        Context.add_error(
          ctx,
          :block_not_matched,
          "#{to_string(block_struct)}/#{label}"
        )
      end
    )
  end

  def block_with_id_children(label, block_struct, child_parser, add_fn)
      when is_function(add_fn) do
    sequence(
      [
        iliteral("@#{label}"),
        iws(),
        commit(),
        js_identifier("#{label}_id"),
        iws(),
        block_begin(label),
        attribute_and_child_list(child_parser),
        iws(),
        block_end(label)
      ],
      label: "#{label}-block",
      debug: true,
      ctx: fn %Context{
                entry_points: [{line, col} | _],
                ast: [id, {attr_list, children} | []],
                data: %{source: source}
              } = ctx ->
        {source_file, source_line} = LogicalFile.resolve_line(source, line)

        block =
          Enum.reduce(
            children,
            create_block(block_struct, id, attr_list_to_map(attr_list), source_file, source_line, col),
            add_fn
          )

        ctx_with_block_and_id_mapped(ctx, block, id, label, source_file, source_line)
      end,
      err: fn %Context{} = ctx ->
        Context.add_error(
          ctx,
          :block_not_matched,
          "#{to_string(block_struct)}/#{label}"
        )
      end
    )
  end

  def derive_define() do
    sequence([
      iliteral("@derive"),
      iws(),
      keyword_value(),
      iws(),
      keyword_value()
    ],
    label: "derive",
    ast: fn [{:keyword, tag}, {:keyword, parent}] ->
      {:derive, tag, parent}
    end)
  end

  @doc """
  ## Examples
      iex> alias Ergo.Context
      iex> import Ergo.{Terminals}
      iex> import Rez.Parser.Parser
      iex> p = text_delimited_by_parsers(literal("begin"), literal("end"))
      iex> input = "begin this is some text between delimiters end"
      iex> assert %Context{status: :ok, ast: " this is some text between delimiters ", input: ""} = Ergo.parse(p, input)
  """
  def text_delimited_by_parsers(open_parser, close_parser, options \\ []) do
    trim = Keyword.get(options, :trim, false)

    sequence(
      [
        ignore(open_parser),
        many(
          sequence(
            [
              not_lookahead(close_parser),
              any()
            ],
            ast: &List.first/1
          )
        ),
        ignore(close_parser)
      ],
      label: "delimited-text",
      ast: fn chars ->
        str = List.to_string(chars)

        case trim do
          true -> String.trim(str)
          false -> str
        end
      end
    )
  end

  def delimited_block(label, block_struct, content_key) do
    sequence(
      [
        iliteral("@#{label}"),
        iws(),
        text_delimited_by_parsers(literal("begin"), literal("end"), trim: true)
      ],
      label: "#{label}-block",
      ctx: fn %Context{entry_points: [{line, col} | _], ast: [text], data: %{source: source}} =
                ctx ->
        {source_file, source_line} = LogicalFile.resolve_line(source, line)

        block =
          struct(block_struct, [
            {:position, {source_file, source_line, col}},
            {content_key, text}
          ])

        %{ctx | ast: block}
      end
    )
  end
end
