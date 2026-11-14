# frozen_string_literal: true

require 'scout_apm/environment'

# Given a call stack Array, grabs the first +APP_FRAMES+ callers within the
# application root directory.
#
module ScoutApm
  module Utils
    class BacktraceParser
      # will return this many backtrace frames from the app stack.
      APP_FRAMES = 8
      BASE_DIRS = %w[lib app config].freeze
      REGEX_CACHE_MUTEX = Mutex.new
      REGEX_CACHE = {}

      def self.app_dir_regex(root, additional_dirs)
        key_dirs = additional_dirs ? Array(additional_dirs) : nil
        REGEX_CACHE_MUTEX.synchronize do
          by_root = REGEX_CACHE[root]
          if by_root
            cached = by_root[key_dirs]
            return cached if cached
          end

          all_dirs = key_dirs ? (BASE_DIRS + key_dirs) : BASE_DIRS
          dir_pattern = all_dirs.map { |d| Regexp.escape(d) + "/" }.join("|")
          regex = %r[#{root}/((?:#{dir_pattern}).*)]

          if REGEX_CACHE.size >= 64
            REGEX_CACHE.clear
            by_root = nil
          end
          by_root ||= (REGEX_CACHE[root] = {})
          by_root[key_dirs ? key_dirs.dup.freeze : nil] = regex
        end
      end

      attr_reader :call_stack

      # call_stack - an +Array+ of calls, typically generated via the +caller+ method.
      # Example single line:
      # "/Users/dlite/.rvm/rubies/ruby-2.4.5/lib/ruby/2.4.0/irb/workspace.rb:87:in `eval'"
      # additional_dirs - an +Array+ of additional directory names to include beyond lib/, app/, and config/
      def initialize(call_stack, root=ScoutApm::Agent.instance.context.environment.root, additional_dirs=ScoutApm::Agent.instance.context.config.value('backtrace_additional_directories'))
        @call_stack = call_stack
        @app_dir_regex = self.class.app_dir_regex(root, additional_dirs)
      end

      def call
        stack = []
        call_stack.each do |c|
          if m = c.match(@app_dir_regex)
            stack << ScoutApm::Utils::Scm.relative_scm_path(m[1])
            break if stack.size == APP_FRAMES
          end
        end
        stack
      end
    end
  end
end
