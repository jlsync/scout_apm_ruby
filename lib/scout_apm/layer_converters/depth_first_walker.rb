# frozen_string_literal: true

module ScoutApm
  module LayerConverters
    class DepthFirstWalker
      attr_reader :root_layer

      # The three hook collections are created on first use: some walkers never
      # register any hooks at all. The `if @foo_blocks` guards in #walk keep the
      # nil case cheap without an extra method call per node.
      def initialize(root_layer)
        @root_layer = root_layer

        @on_blocks = nil
        @before_blocks = nil
        @after_blocks = nil
      end

      def before(&block)
        (@before_blocks ||= []) << block
      end

      def after(&block)
        (@after_blocks ||= []) << block
      end

      def on(&block)
        (@on_blocks ||= []) << block
      end

      def walk(layer=root_layer)
        # Need to run this for the root layer the first time through.
        if layer == root_layer
          @before_blocks.each{|b| b.call(layer) } if @before_blocks
          @on_blocks.each{|b| b.call(layer) } if @on_blocks
        end

        layer.each_child do |child|
          @before_blocks.each{|b| b.call(child) } if @before_blocks
          @on_blocks.each{|b| b.call(child) } if @on_blocks
          walk(child)
          @after_blocks.each{|b| b.call(child) } if @after_blocks
        end

        if layer == root_layer
          @after_blocks.each{|b| b.call(layer) } if @after_blocks
        end

        nil
      end
    end
  end
end
