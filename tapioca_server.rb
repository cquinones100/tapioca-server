# typed: strict

require "tapioca/helpers/cli_helper"
require "tapioca/helpers/rbi_files_helper"
require "tapioca/helpers/gem_helper"
require "tapioca/dsl"
require "tapioca/commands"
require "tapioca/commands/abstract_dsl"
require "tapioca/loaders/loader"

module Tapioca
  module Dsl
    class Compiler
      class << self
        extend T::Sig

        sig { params(constant: Module).returns(T::Boolean) }
        def handles?(constant)
          processable_constants.include?(constant) || processable_constants.any? { |c| c.name == constant.name }
        end
      end
    end
  end

  module Commands
    class DslGenerate < AbstractDsl
      extend T::Sig

      private

      sig { override.void }
      def execute
        load_application

        say("Compiling DSL RBI files...")
        say("")

        generate_dsl_rbi_files(@outpath, quiet: @quiet && !@verbose)
        say("")

        say("Done", :green)

        if @auto_strictness
          say("")
          validate_rbi_files(
            command: default_command(:dsl, all_requested_constants.join(" ")),
            gem_dir: @gem_dir,
            dsl_dir: @outpath.to_s,
            auto_strictness: @auto_strictness,
            compilers: pipeline.active_compilers,
          )
        end

        say("All operations performed in working directory.", [:green, :bold])
        say("Please review changes and commit them.", [:green, :bold])
      ensure
        GitAttributes.create_generated_attribute_file(@outpath)
      end
    end
  end

  module Loaders
    class Dsl < Loader
      extend T::Sig

      sig do
        params(
          environment_load: T::Boolean,
          eager_load: T::Boolean,
          app_root: String,
          halt_upon_load_error: T::Boolean,
        ).void
      end
      def load_rails_application(environment_load: false, eager_load: false, app_root: ".", halt_upon_load_error: true)
        routes_reloader = ::Rails.application.routes_reloader
        routes_reloader.execute_unless_loaded if routes_reloader&.respond_to?(:execute_unless_loaded)
        ::Rails.autoloaders.main.reload
      end

      sig { void }
      def load_application
        say("Reloading Rails application... ")

        load_rails_application(
          environment_load: true,
          eager_load: @eager_load,
          app_root: @app_root,
          halt_upon_load_error: @halt_upon_load_error,
        )

        say("Done", :green)
      end
    end
  end
end

module TapiocaServer
  Options = T.type_alias do
    {
      requested_constants: Constants,
      requested_paths: ModifiedPaths,
      only: Constants,
      exclude: T::Array[String],
      file_header: T::Boolean,
      tapioca_path: String,
      skip_constant: T::Array[String],
      quiet: T::Boolean,
      verbose: T::Boolean,
      number_of_workers: Integer,
      rbi_formatter: T.untyped,
      app_root: String,
      halt_upon_load_error: T::Boolean,
      compiler_options: {},
      outpath: Pathname
    }
  end

  ModifiedPaths = T.type_alias { T::Array[Pathname] }
  Constants = T.type_alias { T::Array[String] }

  class Environment
    class << self
      extend T::Sig

      sig { void }
      def load_requires
        require "listen"
        require "parallel"

        load_from_tapioca("", "dsl")
        load_from_tapioca("", "dsl/pipeline")
        load_from_tapioca("", "executor")

        load_from_tapioca("helpers", "cli_helper")
        load_from_tapioca("commands", "command")
        load_from_tapioca("commands", "command_without_tracker")
        load_from_tapioca("helpers")
        load_from_tapioca("loaders", "loader")
        load_from_tapioca("loaders")
        load_from_tapioca("commands")
        load_from_tapioca("sorbet_ext", "generic_name_patch.rb")
        load_from_tapioca("runtime", "trackers")
        load_from_tapioca("runtime/trackers", "tracker")
        load_from_tapioca("runtime")
        load_from_tapioca("static")
        load_from_tapioca("", "gemfile")
      end

      private

      sig { params(directory: String, file: T.nilable(String)).void }
      def load_from_tapioca(directory, file = nil)
        gem_path = Gem::Specification.find_by_name('tapioca').full_gem_path
        files_path = File.join(gem_path, "lib", "tapioca", directory)
      
        if file
          require "#{files_path}/#{file}"
        else
          Dir["#{files_path}/**/*.rb"].each do |p|
            require p
          end
        end
      end
    end
  end

  class Watcher
    extend T::Sig

    sig { params(modified: ModifiedPaths, added: ModifiedPaths, removed: ModifiedPaths).void }
    def initialize(modified:, added:, removed:)
      @modified = modified
      @added = added
      @removed = removed
    end

    sig { returns(T::Boolean) }
    def changed?
      (modified + added + removed).reject do |f|
        f.to_s.include?("sorbet") || !f.to_s.end_with?(".rb")
      end.present?
    end

    sig { returns(ModifiedPaths) }
    attr_reader :modified

    sig { returns(ModifiedPaths) }
    attr_reader :added

    sig { returns(ModifiedPaths) }
    attr_reader :removed
  end

  class CommandArgs
    extend T::Sig

    sig { params(modified: ModifiedPaths, added: ModifiedPaths, removed: ModifiedPaths).void }
    def initialize(modified:, added:, removed:)
      @modified = modified
      @added = added
      @removed = removed
      @all_constants = T.let(nil, T.nilable(Constants))
      @relevant_constants = T.let(nil, T.nilable(Constants))
      @all_compilers = T.let(nil, T.nilable(Constants))
      @relevant_compilers = T.let(nil, T.nilable(Constants))

      to_options
    end

    sig { returns(Options) }
    def to_options
      rbi_formatter = ::Tapioca::DEFAULT_RBI_FORMATTER

      rbi_formatter.max_line_length = 120
      {
        requested_constants: [],
        requested_paths: relevant_paths,
        only: [],
        exclude: [],
        file_header: true,
        tapioca_path: ::Tapioca::TAPIOCA_DIR,
        skip_constant: [],
        quiet: false,
        verbose: true,
        number_of_workers: 2,
        rbi_formatter:,
        app_root: ".",
        halt_upon_load_error: true,
        compiler_options: {},
        outpath: Pathname.new(::Tapioca::DEFAULT_DSL_DIR)
      }
    end

    sig { returns(Constants) }
    def all_constants
      @all_constants ||= begin
        T.cast(Module.constants, T::Array[Symbol])
          .find_all do |c| 
            Module === c.to_s.constantize
          rescue
            false
          end
          .map(&:to_s)
      end
    end

    sig { returns(Constants) }
    def relevant_constants
      @relevant_constants ||= begin
        if migration?
          models = all_constants.find_all do |symbol|
            symbol.to_s.constantize < ApplicationRecord
          rescue
            false
          end

          models.map(&:to_s)
        else
          []
        end
      end
    end

    sig { returns(Constants) }
    def all_compilers
      @all_compilers ||= ::Tapioca::Dsl::Compiler.descendants.map(&:to_s)
    end

    sig { returns(Constants) }
    def relevant_compilers
      @relevant_compilers ||= begin
        if migration?
          active_record_compilers
        else
          all_compilers
        end
      end
    end

    sig { returns(ModifiedPaths) }
    def relevant_paths
      if relevant_constants.empty?
        modified + added + removed
      else
        []
      end
    end

    sig { void }
    def print_summary
      puts "Detected the following constants to be changed: #{relevant_constants.join(", ")}" if relevant_constants.any?
      puts "Detected the following paths to be changed: #{relevant_paths.join(", ")}" if relevant_paths.any?
      puts "Using the following compilers to generate RBI files: #{relevant_compilers.join(", ")}" if relevant_compilers.any?
    end

    private

    sig { returns(ModifiedPaths) }
    attr_reader :modified

    sig { returns(ModifiedPaths) }
    attr_reader :added

    sig { returns(ModifiedPaths) }
    attr_reader :removed

    sig { returns(Constants) }
    def active_record_compilers
      all_compilers.select do |compiler|
        compiler.start_with?("Tapioca::Dsl::Compilers::ActiveRecord") ||
        compiler.start_with?("Tapioca::Dsl::Compilers::ActiveModel")
      end
    end

    sig { returns(T::Boolean) }
    def migration?
      (modified + added + removed).any? { |p| p.to_s.end_with? "schema.rb" }
    end
  end
end
