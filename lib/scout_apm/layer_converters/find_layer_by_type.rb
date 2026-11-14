# frozen_string_literal: true

# Scope is determined by the first Controller we hit.  Most of the time
# there will only be 1 anyway.  But if you have a controller that calls
# another controller method, we may pick that up:
#     def update
#       show
#       render :update
#     end

# This doesn't cache the negative result when searching for a controller / job,
# so that we can ask again later after more of the request has occurred and
# correctly find it.
module ScoutApm
  module LayerConverters
    class FindLayerByType
      # Frozen so a lookup doesn't allocate a fresh Array on every call.
      CONTROLLER_AND_JOB = ["Controller", "Job"].freeze
      CONTROLLER = ["Controller"].freeze
      JOB = ["Job"].freeze
      QUEUE = ["Queue"].freeze

      def initialize(request)
        @request = request
      end

      def scope
        @scope ||= call(CONTROLLER_AND_JOB)
      end

      def controller
        @controller ||= call(CONTROLLER)
      end

      def job
        @job ||= call(JOB)
      end

      def queue
        @queue ||= call(QUEUE)
      end

      # Pre-order depth-first search for the first layer matching one of
      # +layer_types+. Equivalent to the DepthFirstWalker based search this used
      # to do, but without allocating a walker and a block per lookup.
      def call(layer_types)
        find_in(@request.root_layer, layer_types)
      end

      private

      def find_in(layer, layer_types)
        return nil if layer.nil?
        return layer if layer_types.include?(layer.type)

        layer.each_child do |child|
          found = find_in(child, layer_types)
          return found if found
        end

        nil
      end
    end
  end
end
