std = "luajit"

-- Don't complain about lines being too long
max_line_length = false

-- Global variables provided by KOReader runtime
read_globals = {
    "logger",
    "UIManager",
    "Device",
    "Screen",
    "_",            -- Gettext translation function
    "T",            -- Template translation function
    "G_reader_settings",
    "JSON",
    "DataStorage",
    "Dispatcher",
    "InputContainer",
    "Socket",
}

-- Ignore variable shadowing (common in KOReader UI widgets)
ignore = { "212/_" }

-- Exclude folders we don't need to check
exclude_files = {
    "**/*.zip",
    "**/*.png",
    ".github/*"
}
