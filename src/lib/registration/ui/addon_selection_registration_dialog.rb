# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.

require "registration/ui/addon_selection_base_dialog"

module Registration
  module UI
    # this class displays and runs the dialog with addon selection
    class AddonSelectionRegistrationDialog < AddonSelectionBaseDialog
      # display and run the dialog with addon selection
      # @param registration [Registration::Registration] use this Registration object for
      #   communication with SCC
      # @return [Symbol] user input symbol
      def self.run(registration)
        dialog = AddonSelectionRegistrationDialog.new(registration)
        dialog.run
      end

      # constructor
      # @param registration [Registration::Registration] use this Registration object for
      #   communication with SCC
      def initialize(registration)
        textdomain "registration"
        super(registration)
      end

      # display the extension selection dialog and wait for a button click
      # @return [Symbol] user input
      def run
        Wizard.SetContents(
          # dialog title
          _("Extension and Module Selection"),
          content,
          # help text (1/3)
          _("<p>Here you can select available extensions and modules for your"\
              "system.</p>") + generic_help_text,
          # always enable Back/Next, the dialog cannot be the first in workflow
          true,
          true
        )
        show_addons

        @old_selection = Addon.selected.dup

        handle_dialog
      end

    private

      # @return [String] the main dialog label
      def heading
        _("Available Extensions and Modules")
      end
    end
  end
end
