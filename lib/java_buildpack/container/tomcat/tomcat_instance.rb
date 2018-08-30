# frozen_string_literal: true

# Cloud Foundry Java Buildpack
# Copyright 2013-2018 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'java_buildpack/component/versioned_dependency_component'
require 'java_buildpack/container'
require 'java_buildpack/container/tomcat/tomcat_utils'
require 'java_buildpack/util/tokenized_version'

module JavaBuildpack
  module Container

    # Encapsulates the detect, compile, and release functionality for the Tomcat instance.
    class TomcatInstance < JavaBuildpack::Component::VersionedDependencyComponent
      include JavaBuildpack::Container

      # Creates an instance
      #
      # @param [Hash] context a collection of utilities used the component
      def initialize(context)
        super(context) { |candidate_version| candidate_version.check_size(3) }
        @logger            = Logging::LoggerFactory.instance.get_logger TomcatInstance
      end

      # (see JavaBuildpack::Component::BaseComponent#compile)
      def compile
        @logger.debug { "Entering component compile".white.bold }
        download(@version, @uri) { |file| expand file }
        process_wars
        link_to(@application.root.children, root)
        @droplet.additional_libraries << tomcat_datasource_jar if tomcat_datasource_jar.exist?
        @droplet.additional_libraries.link_to web_inf_lib
      end

      # (see JavaBuildpack::Component::BaseComponent#release)
      def release; end

      protected

      # (see JavaBuildpack::Component::VersionedDependencyComponent#supports?)
      def supports?
        true
      end

      TOMCAT_8 = JavaBuildpack::Util::TokenizedVersion.new('8.0.0').freeze

      private_constant :TOMCAT_8

      # Checks whether Tomcat instance is Tomcat 7 compatible
      def tomcat_7_compatible
        @version < TOMCAT_8
      end

      private

      def configure_jasper
        return unless tomcat_7_compatible

        document = read_xml server_xml
        server   = REXML::XPath.match(document, '/Server').first

        listener = REXML::Element.new('Listener')
        listener.add_attribute 'className', 'org.apache.catalina.core.JasperListener'

        server.insert_before '//Service', listener

        write_xml server_xml, document
      end

      def configure_linking
        document = read_xml context_xml
        context  = REXML::XPath.match(document, '/Context').first

        if tomcat_7_compatible
          context.add_attribute 'allowLinking', true
        else
          context.add_element 'Resources', 'allowLinking' => true
        end

        write_xml context_xml, document
      end

      def expand(file)
        @logger.debug { "Entering expand(#{file})".white.bold }
        with_timing "Expanding #{@component_name} to #{@droplet.sandbox.relative_path_from(@droplet.root)}" do
          @logger.debug { "Making directory #{@droplet.sandbox}".white.bold }
          FileUtils.mkdir_p @droplet.sandbox
          @logger.debug { "Expanding file into #{@droplet.sandbox}".white.bold }
          shell "tar xzf #{file.path} -C #{@droplet.sandbox} --strip 1 --exclude webapps 2>&1"

          @logger.debug { "Copying Resources".white.bold }
          @droplet.copy_resources
          configure_linking
          configure_jasper
        end
      end

      def application_wars(files)
        s = Set.new
        @logger.debug { "Entering application_wars".white.bold }
        files.each { |file|
          iswar = File.extname(file).eql? '.war'
          @logger.debug { "Checking #{file} == '.war'......#{iswar}".white.bold }
          s << file if iswar
        }
        s
      end

      def expand_war(file)
        @logger.debug { "Entering expand_war with #{file}".white.bold }
        dirpath = @droplet.root + File.basename(file)
        @logger.debug { "Making directory #{dirpath}".white.bold }
        FileUtils.mkdir_p dirpath
        @logger.debug { "Extracting war into #{@droplet.root + File.basename(file)}".white.bold }
        shell "tar xzf #{file.path} -C #{@droplet.sandbox} --strip 1 --exclude webapps 2>&1"
      end

      def process_wars
        @logger.debug { "Entering process_wars".white.bold }
        application_wars(@application.root.children).each { |file| expand_war file }
      end

      def root
        #always make webapps the root
        @logger.debug { "Entering tomcat_instance:root".white.bold }
        context_path = (@configuration['context_path'] || 'ROOT').sub(%r{^/}, '').gsub(%r{/}, '#')
        #tomcat_webapps + context_path
        @logger.debug { "Root should be equal to #{tomcat_webapps}".white.bold }
        tomcat_webapps
      end

      def tomcat_datasource_jar
        tomcat_lib + 'tomcat-jdbc.jar'
      end

      def web_inf_lib
        @droplet.root + 'WEB-INF/lib'
      end

    end

  end
end
