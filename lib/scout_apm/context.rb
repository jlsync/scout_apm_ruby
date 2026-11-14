# frozen_string_literal: true

# Encapsulates adding context to requests. Context is stored via a simple Hash.
#
# There are 2 types of context: User and Extra.
# For user-specific context, use @Context#add_user@.
# For misc context, use @Context#add@.
module ScoutApm
  class Context
    attr_reader :context

    VALID_TYPES = [String, Symbol, Numeric, Time, Date, TrueClass, FalseClass].freeze
    INVALID_KEY_CHARS = /[^\w-]/.freeze

    def initialize(context)
      @context = context
      @extra = {}
      @user = {}
    end

    def logger
      context.logger
    end

    # Generates a hash representation of the Context.
    # Example: {:monthly_spend => 100, :user => {:ip => '127.0.0.1'}}
    def to_hash
      @extra.merge({:user => @user})
    end

    def to_flat_hash
      h = to_hash
      user = h.delete(:user)
      if user
        user.each { |k,v| h["user_#{k}"] = v}
      end
      h
    end

    def self.current
      RequestManager.lookup.context
    end

    # Add context
    # ScoutApm::Context.add(account: current_account.name)
    def add(hash)
      update_context(@extra, hash)
    end

    def add_user(hash)
      update_context(@user, hash)
    end

    # Convenience accessor so you can just call @ScoutAPM::Context#add@
    def self.add(hash)
      self.current.add(hash)
    end

    # Convenience accessor so you can just call @ScoutAPM::Context#add_user@
    def self.add_user(hash)
      self.current.add_user(hash)
    end

    private

    def update_context(target, hash)
      added = false
      hash.each do |key, value|
        # does both checks so we can get logging info on the value even if the key is invalid.
        key_ok = key_valid?(key)
        value_ok = value_valid?(key, value)
        if key_ok && value_ok
          target[key] = value
          added = true
        end
      end
      added ? target : nil
    end

    # Returns true if the obj is one of the provided valid classes.
    def valid_type?(classes, obj)
      valid_type = false
      classes.each do |klass|
        if obj.is_a?(klass)
          valid_type = true
          break
        end
      end
      valid_type
    end

    # take key + value directly without wrapper hashes while keeping detailed log output.
    def value_valid?(key, value)
      # ensure one of our accepted types.
      if value.nil?
        false # don't log this ... easy to happen
      elsif !valid_type?(VALID_TYPES, value)
        logger.info "The value for [#{key}] is not a valid type [#{value.class}]."
        false
      else
        true
      end
    end

    def key_valid?(key)
      if key.nil?
        return false # don't log this ... easy to happen
      # ensure a string or a symbol
      elsif !key.is_a?(String) && !key.is_a?(Symbol)
        logger.info "The key [#{key}] is not a valid type [#{key.class}]."
        return false
      end
      # only alphanumeric, dash, and underscore allowed.
      if key =~ INVALID_KEY_CHARS
        logger.info "They key name [#{key}] is not valid."
        return false
      end
      true
    end
  end
end
