require 'active_model'
require 'utils/uri_utils'
require 'models/helpers/health_check_types'
require 'models/helpers/metadata_error'
require 'models/helpers/metadata_helpers'
require 'models/helpers/label_selector_requirement'
require 'cloud_controller/domain_decorator'
require 'messages/metadata_validator_helper'

module VCAP::CloudController::Validators
  module StandaloneValidator
    def validate_each(*args)
      new(attributes: [nil]).validate_each(*args)
    end
  end

  class ArrayValidator < ActiveModel::EachValidator
    def validate_each(record, attr_name, value)
      record.errors.add(attr_name, 'must be an array') unless value.is_a? Array
    end
  end

  class StringValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      record.errors.add attribute, 'must be a string' unless value.is_a?(String)
    end
  end

  class BooleanValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      record.errors.add attribute, 'must be a boolean' unless boolean?(value)
    end

    private

    def boolean?(value)
      [true, false].include? value
    end
  end

  class HashValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      record.errors.add attribute, 'must be an object' unless value.is_a?(Hash)
    end
  end

  class GuidValidator < ActiveModel::EachValidator
    extend StandaloneValidator

    def validate_each(record, attribute, value)
      record.errors.add attribute, 'must be a string' unless value.is_a?(String)
      record.errors.add attribute, 'must be between 1 and 200 characters' unless value.is_a?(String) && (1..200).cover?(value.size)
    end
  end

  class UriValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      record.errors.add attribute, 'must be a valid URI' unless UriUtils.is_uri?(value)
    end
  end

  class UriPathValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      record.errors.add attribute, 'must be a valid URI path' unless UriUtils.is_uri_path?(value)
    end
  end

  class EnvironmentVariablesValidator < ActiveModel::EachValidator
    extend StandaloneValidator

    def validate_each(record, attribute, value)
      if !value.is_a?(Hash)
        record.errors.add(attribute, 'must be an object')
      else
        value.each_key do |key|
          if ![String, Symbol].include?(key.class)
            record.errors.add(attribute, 'key must be a string')
          elsif key.empty?
            record.errors.add(attribute, 'key must be a minimum length of 1')
          elsif key.match?(/\AVCAP_/i)
            record.errors.add(attribute, 'cannot start with VCAP_')
          elsif key.match?(/\AVMC/i)
            record.errors.add(attribute, 'cannot start with VMC_')
          elsif key.match?(/\APORT\z/i)
            record.errors.add(attribute, 'cannot set PORT')
          end
        end
      end
    end
  end

  class HealthCheckValidator < ActiveModel::Validator
    def validate(record)
      if record.health_check_type != VCAP::CloudController::HealthCheckTypes::HTTP
        record.errors.add(:health_check_type, 'must be "http" to set a health check HTTP endpoint')
      end
    end
  end

  class LifecycleValidator < ActiveModel::Validator
    def validate(record)
      data_message = {
        VCAP::CloudController::Lifecycles::BUILDPACK => VCAP::CloudController::BuildpackLifecycleDataMessage,
        VCAP::CloudController::Lifecycles::DOCKER => VCAP::CloudController::DockerLifecycleDataMessage,
      }

      lifecycle_data_message_class = data_message[record.lifecycle_type]
      if lifecycle_data_message_class.nil?
        record.errors[:lifecycle_type].concat ["is not included in the list: #{data_message.keys.join(', ')}"]
        return
      end

      return unless record.lifecycle_data.is_a?(Hash)

      lifecycle_data_message = lifecycle_data_message_class.new(record.lifecycle_data)
      unless lifecycle_data_message.valid?
        record.errors[:lifecycle].concat lifecycle_data_message.errors.full_messages
      end
    end
  end

  class RelationshipValidator < ActiveModel::Validator
    def validate(record)
      if !record.relationships.is_a?(Hash)
        record.errors[:relationships].concat ["'relationships' is not an object"]
        return
      end

      if record.relationships.empty?
        record.errors[:relationships].concat ["'relationships' must include one or more valid relationships"]
        return
      end

      rel = record.relationships_message

      if !rel.valid?
        record.errors[:relationships].concat(rel.errors.full_messages)
      end
    end
  end

  class DataValidator < ActiveModel::Validator
    def validate(record)
      return if !record.data.is_a?(Hash)

      data = record.class::Data.new(record.data.symbolize_keys)

      if !data.valid?
        record.errors[:data].concat(data.errors.full_messages)
      end
    end
  end

  class ToOneRelationshipValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, relationship)
      if has_correct_structure?(relationship)
        validate_guid(record, attribute, relationship) if relationship[:data]
      else
        record.errors.add(attribute, error_message(attribute))
      end
    end

    private

    def error_message(attribute)
      "must be structured like this: \"#{attribute}: {\"data\": {\"guid\": \"valid-guid\"}}\""
    end

    def validate_guid(record, attribute, relationship)
      VCAP::CloudController::BaseMessage::GuidValidator.
        validate_each(record, "#{attribute} Guid", relationship.values.first.values.first)
    end

    def has_correct_structure?(relationship)
      relationship.is_a?(Hash) &&
        had_data_key(relationship) &&
        data_has_correct_structure?(relationship[:data])
    end

    def had_data_key(relationship)
      relationship.keys == [:data]
    end

    def data_has_correct_structure?(data)
      data.nil? || (data.is_a?(Hash) && has_guid_key(data))
    end

    def has_guid_key(data)
      (data.keys == [:guid])
    end
  end

  class ToManyRelationshipValidator < ActiveModel::EachValidator
    def error_message(attribute)
      "must be structured like this: \"#{attribute}: {\"data\": [{\"guid\": \"valid-guid\"},{\"guid\": \"valid-guid\"}]}\""
    end

    def validate_each(record, attribute, value)
      if has_correct_structure?(value)
        validate_guids(record, attribute, value[:data])
      else
        record.errors.add(attribute, error_message(attribute))
      end
    end

    def validate_guids(record, attribute, value)
      guids = value.map(&:values).flatten
      guids.each_with_index do |guid, idx|
        VCAP::CloudController::BaseMessage::GuidValidator.
          validate_each(record, "#{attribute} Guid #{idx}", guid)
      end
    end

    def properly_formatted_data(data)
      (data.is_a?(Array) && data.all? { |hsh| is_a_guid_hash?(hsh) })
    end

    def has_correct_structure?(value)
      (value.is_a?(Hash) && value.dig(:data) && properly_formatted_data(value[:data]))
    end

    def is_a_guid_hash?(hsh)
      (hsh.keys.map(&:to_s) == ['guid'])
    end
  end

  class SpaceOrOrgPresentValidator < ActiveModel::Validator
    def validate(record)
      if record.space_guid.nil? && record.organization_guid.nil?
        record.errors[:relationships].concat ['Role must be associated with either a space or an organization.']
      end

      if record.space_guid && VCAP::CloudController::RoleTypes::ORGANIZATION_ROLES.include?(record.type)
        record.errors[:type].concat ["Role with type '#{record.type}' cannot be associated with a space."]
      end

      if record.organization_guid && VCAP::CloudController::RoleTypes::SPACE_ROLES.include?(record.type)
        record.errors[:type].concat ["Role with type '#{record.type}' cannot be associated with an organization."]
      end

      if record.space_guid && record.organization_guid
        record.errors[:relationships].concat ['Role cannot be associated with both an organization and a space.']
      end
    end
  end
end
