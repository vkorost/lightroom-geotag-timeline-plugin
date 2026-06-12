return {
    sectionsForTopOfDialog = function(f, _propertyTable)
        local LrView = import 'LrView'
        local LrPrefs = import 'LrPrefs'
        local prefs = LrPrefs.prefsForPlugin()

        if not prefs.pythonPath then
            prefs.pythonPath = "python"
        end

        return {
            {
                title = "Geotag from Google Timeline",
                synopsis = "Configure Python path",

                f:row {
                    spacing = f:label_spacing(),
                    f:static_text {
                        title = "Python executable:",
                        alignment = 'right',
                        width = LrView.share 'label_width',
                    },
                    f:edit_field {
                        value = LrView.bind {
                            key = 'pythonPath',
                            bind_to_object = prefs,
                        },
                        width_in_chars = 50,
                        tooltip = "Path to Python 3 executable (e.g. python, python3, or full path)",
                    },
                },
            },
        }
    end,
}
