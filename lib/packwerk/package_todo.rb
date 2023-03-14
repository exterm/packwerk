# typed: strict
# frozen_string_literal: true

require "yaml"

module Packwerk
  class PackageTodo
    extend T::Sig

    EntryType = T.type_alias { T::Hash[String, T::Hash[String, T::Array[String]]] }
    EntriesType = T.type_alias do
      T::Hash[String, EntryType]
    end

    sig { params(package: Packwerk::Package, filepath: String).void }
    def initialize(package, filepath)
      @package = package
      @filepath = filepath
      @new_entries = T.let({}, EntriesType)
      @todo_list = T.let(nil, T.nilable(EntriesType))
    end

    sig do
      params(reference: Packwerk::Reference, violation_type: String)
        .returns(T::Boolean)
    end
    def listed?(reference, violation_type:)
      violated_constants_found = todo_list.dig(reference.constant.package.name, reference.constant.name)
      return false unless violated_constants_found

      violated_constant_in_file = violated_constants_found.fetch("files", []).include?(reference.relative_path)
      return false unless violated_constant_in_file

      violated_constants_found.fetch("violations", []).include?(violation_type)
    end

    sig do
      params(reference: Packwerk::Reference, violation_type: String).returns(T::Boolean)
    end
    def add_entries(reference, violation_type)
      package_violations = @new_entries.fetch(reference.constant.package.name, {})
      entries_for_constant = package_violations[reference.constant.name] ||= {}

      entries_for_constant["violations"] ||= []
      entries_for_constant.fetch("violations") << violation_type

      entries_for_constant["files"] ||= []
      entries_for_constant.fetch("files") << reference.relative_path.to_s

      @new_entries[reference.constant.package.name] = package_violations
      listed?(reference, violation_type: violation_type)
    end

    sig { params(for_files: T::Set[String]).returns(T::Boolean) }
    def stale_violations?(for_files)
      prepare_entries_for_dump

      todo_list.any? do |package, violations|
        violations_for_files = package_violations_for(violations, files: for_files)

        # We `next false` because if we cannot find existing violations for `for_files` within
        # the `package_todo.yml` file, then there are no violations that
        # can be considered stale.
        next false if violations_for_files.empty?

        stale_violation_for_package?(package, violations: violations_for_files)
      end
    end

    sig { void }
    def dump
      if @new_entries.empty?
        delete_if_exists
      else
        prepare_entries_for_dump
        message = <<~MESSAGE
          # This file contains a list of dependencies that are not part of the long term plan for the
          # '#{@package.name}' package.
          # We should generally work to reduce this list over time.
          #
          # You can regenerate this file using the following command:
          #
          # bin/packwerk update-todo
        MESSAGE
        File.open(@filepath, "w") do |f|
          f.write(message)
          f.write(@new_entries.to_yaml)
        end
      end
    end

    sig { void }
    def delete_if_exists
      File.delete(@filepath) if File.exist?(@filepath)
    end

    private

    sig { params(package: String, violations: EntryType).returns(T::Boolean) }
    def stale_violation_for_package?(package, violations:)
      violations.any? do |constant_name, entries_for_constant|
        new_entries_violation_types = T.cast(
          @new_entries.dig(package, constant_name, "violations"),
          T.nilable(T::Array[String]),
        )
        # If there are no NEW entries that match the old entries `for_files`,
        # @new_entries is from the list of violations we get when we check this file.
        # If this list is empty, we also must have stale violations.
        next true if new_entries_violation_types.nil?

        if entries_for_constant.fetch("violations").all? { |type| new_entries_violation_types.include?(type) }
          stale_violations =
            entries_for_constant.fetch("files") - Array(@new_entries.dig(package, constant_name, "files"))
          stale_violations.any?
        else
          return true
        end
      end
    end

    sig { params(package_violations: EntryType, files: T::Set[String]).returns(EntryType) }
    def package_violations_for(package_violations, files:)
      {}.tap do |package_violations_for_files|
        package_violations_for_files = T.cast(package_violations_for_files, EntryType)

        package_violations.each do |constant_name, entries_for_constant|
          entries_for_files = files & entries_for_constant.fetch("files")
          next if entries_for_files.none?

          package_violations_for_files[constant_name] = {
            "violations" => entries_for_constant["violations"],
            "files" => entries_for_files.to_a,
          }
        end
      end
    end

    sig { returns(EntriesType) }
    def prepare_entries_for_dump
      @new_entries.each do |package_name, package_violations|
        package_violations.each do |_, entries_for_constant|
          entries_for_constant.fetch("violations").sort!.uniq!
          entries_for_constant.fetch("files").sort!.uniq!
        end
        @new_entries[package_name] = package_violations.sort.to_h
      end

      @new_entries = @new_entries.sort.to_h
    end

    sig { returns(EntriesType) }
    def todo_list
      @todo_list ||= if File.exist?(@filepath)
        load_yaml(@filepath)
      else
        {}
      end
    end

    sig { params(filepath: String).returns(EntriesType) }
    def load_yaml(filepath)
      YAML.load_file(filepath) || {}
    rescue Psych::Exception
      {}
    end
  end
end
