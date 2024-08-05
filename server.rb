# typed: true
# frozen_string_literal: true

require "json"
require "./lib/tapioca_server.rb"

module TapiocaServer
  module Rails
    class Server
      def start
        routes_reloader = ::Rails.application.routes_reloader
        routes_reloader.execute_unless_loaded if routes_reloader&.respond_to?(:execute_unless_loaded)


        puts "listening for changes"

        listener = Listen.to('.') do |modified, added, removed|
          if TapiocaServer::Watcher.new(modified: modified, added: added, removed: removed).changed?
            puts "Change detected"

            TapiocaServer::Environment.load_requires
            command_args = TapiocaServer::CommandArgs.new(modified:, added:, removed:)
            generator = Tapioca::Commands::DslGenerate.new(**command_args.to_options)
            generator.run
          end
        end

        listener.start

        sleep
      end
    end
  end
end

TapiocaServer::Rails::Server.new.start