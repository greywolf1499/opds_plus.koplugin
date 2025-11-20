std = "luajit"
unused_args = false
self = false
max_line_length = false

globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}

read_globals = {
    -- Core API
    "logger",
    "UIManager",
    "Device",
    "Screen",
    "DataStorage",
    "Dispatcher",
    "InputContainer",
    "Socket",
    "JSON",

    -- Translation functions
    "_",
    "T",
    "N_",

    -- Lua internals
    "_ENV",
}

exclude_files = {
    "**/*.zip",
    "**/*.png",
    ".github/*"
}

ignore = {
    "211/__*", -- Ignore unused local variables if they start with __
    "212/_",   -- Ignore unused arguments if named _
    "231/__",  -- Ignore global variable '__'
    "631",     -- Ignore line length
    "dummy",   -- Ignore variables named 'dummy'
}
