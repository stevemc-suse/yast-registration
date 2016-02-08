
# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2014 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------
#
#

require "singleton"
require "tempfile"

require "yast"
require "registration/autoinstall_io"

module Registration
  # a module holding data needed during (auto)installation
  module Storage
    # storage for changed repositories
    class RegCodes < Struct.new(:reg_codes)
      include Singleton
      include Yast::AutoinstallIoInclude
      include Yast
      include Yast::I18n
      include Yast::Logger

      def initialize
        Yast.import "XML"
        # TODO: package it better
        initialize_autoinstall_io(self)

        self.reg_codes = reg_codes_from_usb_stick || {}
      end

      private

      REGCODES_NAME_HANDLERS = {
        "regcodes.xml" => :reg_codes_from_xml,
        "regcodes.txt" => :reg_codes_from_txt
      }

      # @return [Hash{String => String},nil]
      def reg_codes_from_usb_stick
        REGCODES_NAME_HANDLERS.each do |name, handler|
          with_tempfile(name) do |path|
            if GetURL("usb:///#{name}", path)
              codes = send(handler, path)
              return codes if codes
            end
          end
        end
        nil
      end

      # @param template for tempfile name
      # @yieldparam actual file name
      def with_tempfile(pattern, &block)
        tempfile = Tempfile.new(pattern)
        block.call(tempfile.path)
      ensure
        tempfile.unlink
      end

      # @param filename [String]
      # @return [Hash{String => String},nil]
      def reg_codes_from_xml(filename)
        return nil unless File.readable?(filename)
        xml_hash = XML.XMLToYCPFile(filename)
        parse_xml(xml_hash)
      end

      # @param xml_hash [Hash] as used in AY and returned by XML.XMLToYCPFile
      # @return [Hash{String => String},nil]
      def parse_xml(xml_hash)
        suse_register = xml_hash.fetch("suse_register", {})
        addons = suse_register.fetch("addons", [])
        pairs = addons.map do |a|
          [a.fetch("name", ""), a.fetch("reg_code", "")]
        end
        Hash[pairs]
      end

      # The format is: lines with a key and a value,
      #   separated by white space
      # @param filename [String]
      # @return [Hash{String => String},nil]
      def reg_codes_from_txt(filename)
        return nil unless File.readable?(filename)
        text = File.read(filename)
        # TODO: report parse errors in log
        # TODO: allow for DOS line endings
        pairs = text.each_line.map do |l|
          l.chomp.split(/\s+/, 2)
        end
        Hash[pairs.reject(&:empty?)]
      end
    end

    # remember the values entered by user
    # TODO: use Config instead to allow easy export at installation
    class InstallationOptions
      include Singleton

      attr_accessor :install_updates, :email, :reg_code, :selected_addons,
        :base_registered, :custom_url, :imported_cert_sha256_fingerprint

      def initialize
        @email = ""
        @reg_code = ""
        @selected_addons = []
        @base_registered = false
      end
    end

    class Cache < Struct.new(:first_run, :addon_services,
      :reg_url, :reg_url_cached, :upgrade_failed)

      include Singleton

      def initialize
        self.addon_services = []
        self.first_run = true
        self.upgrade_failed = false
      end
    end

    # remember the details about SSL verification failure
    # the attributes are read from the SSL error context
    class SSLErrors < Struct.new(:ssl_error_code, :ssl_error_msg, :ssl_failed_cert)
      include Singleton

      def reset
        self.ssl_error_code = nil
        self.ssl_error_msg = nil
        self.ssl_failed_cert = nil
      end
    end

    # AutoYast configuration
    class Config
      include Singleton

      attr_accessor :modified, :do_registration, :reg_server, :reg_server_cert, :email,
        :reg_code, :install_updates, :addons, :slp_discovery,
        :reg_server_cert_fingerprint_type, :reg_server_cert_fingerprint

      def initialize
        reset
      end

      def reset
        @modified = false
        @do_registration = false
        @reg_server = ""
        @reg_server_cert = ""
        @email = ""
        @reg_code = ""
        @install_updates = false
        @addons = []
        @slp_discovery = false
        @reg_server_cert_fingerprint_type = nil
        @reg_server_cert_fingerprint = ""
      end

      def export
        ret = { "do_registration" => do_registration }
        # export only the boolean flag when registration is disabled,
        # all other config values are useless in that case
        return ret unless do_registration

        ret.merge!(
          "reg_server"      => reg_server,
          "slp_discovery"   => slp_discovery,
          "email"           => email,
          "reg_code"        => reg_code,
          "install_updates" => install_updates
        )

        ret["addons"] = export_addons
        ret.merge!(export_ssl_config)

        ret
      end

      def import(settings)
        reset

        @do_registration = settings.fetch("do_registration", false)
        @reg_server = settings["reg_server"] || ""
        @slp_discovery = settings.fetch("slp_discovery", false)
        @reg_server_cert = settings["reg_server_cert"] || ""
        @email = settings["email"] || ""
        @reg_code = settings["reg_code"] || ""
        @install_updates = settings.fetch("install_updates", false)
        @addons = import_addons(settings)
        @reg_server_cert_fingerprint_type = settings["reg_server_cert_fingerprint_type"] || ""
        @reg_server_cert_fingerprint = settings["reg_server_cert_fingerprint"] || ""
      end

      private

      def import_addons(settings)
        (settings["addons"] || []).map do |a|
          import_addon = a.dup
          # handle "nil" release_type, nil cannot be stored in XML profile
          import_addon["release_type"] = nil if a["release_type"] == "nil"
          import_addon
        end
      end

      def export_addons
        addons.map do |a|
          addon_export = a.dup
          # handle nil release_type at export, nil cannot be stored in XML profile
          addon_export["release_type"] = "nil" if addon_export["release_type"].nil?
          addon_export
        end
      end

      def export_ssl_config
        ret = { "reg_server_cert" => reg_server_cert }

        if reg_server_cert_fingerprint_type && !reg_server_cert_fingerprint_type.empty?
          ret["reg_server_cert_fingerprint_type"] = reg_server_cert_fingerprint_type
          ret["reg_server_cert_fingerprint"] = reg_server_cert_fingerprint
        end

        ret
      end
    end
  end
end
