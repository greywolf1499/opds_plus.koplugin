# Contributing to OPDS Plus

First off, thank you for considering contributing to OPDS Plus! It's people like you that make OPDS Plus such a great tool for the KOReader community.

## Table of Contents

- [Contributing to OPDS Plus](#contributing-to-opds-plus)
	- [Table of Contents](#table-of-contents)
	- [Code of Conduct](#code-of-conduct)
	- [How Can I Contribute?](#how-can-i-contribute)
		- [Reporting Bugs](#reporting-bugs)
		- [Suggesting Enhancements](#suggesting-enhancements)
		- [Your First Code Contribution](#your-first-code-contribution)
		- [Pull Requests](#pull-requests)
			- [Pull Request Process](#pull-request-process)
	- [Style Guidelines](#style-guidelines)
		- [Lua Code Style](#lua-code-style)
		- [Git Commit Messages](#git-commit-messages)
		- [Documentation Style](#documentation-style)
	- [Development Setup](#development-setup)
		- [Prerequisites](#prerequisites)
		- [Setting Up Development Environment](#setting-up-development-environment)
		- [File Structure Understanding](#file-structure-understanding)
		- [Key Components](#key-components)
	- [Testing](#testing)
		- [Manual Testing Checklist](#manual-testing-checklist)
		- [Test on Multiple Catalogs](#test-on-multiple-catalogs)
		- [Device Testing](#device-testing)
		- [Debug Mode Testing](#debug-mode-testing)
	- [Questions?](#questions)
	- [Recognition](#recognition)

## Code of Conduct

This project and everyone participating in it is governed by a code of respect and professionalism. By participating, you are expected to uphold this code. Please report unacceptable behavior to the repository owner.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates. When you create a bug report, include as many details as possible:

**Use the bug report template** (if available) and include:

- **Clear, descriptive title** for the issue
- **Exact steps to reproduce** the problem
- **Expected behavior** and what actually happened
- **Screenshots** if applicable
- **KOReader version** and device information
- **OPDS Plus version** (found in Settings → About)
- **OPDS catalog** you were browsing when the issue occurred
- **Log files** if available (enable Debug Mode in Developer settings)

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion:

- **Use a clear, descriptive title**
- **Provide a detailed description** of the suggested enhancement
- **Explain why this enhancement would be useful** to most OPDS Plus users
- **List any similar features** in other applications if applicable
- **Include mockups or examples** if you have them

### Your First Code Contribution

Unsure where to begin? Look for issues labeled:

- `good first issue` - Simple issues that are good for newcomers
- `help wanted` - Issues where we need community assistance
- `documentation` - Documentation improvements

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Make your changes** following our style guidelines
3. **Test your changes** on a real KOReader device or emulator
4. **Update documentation** if you've changed functionality
5. **Write clear commit messages** following our guidelines
6. **Submit a pull request** with a clear description

#### Pull Request Process

1. Ensure your code follows the [Lua style guidelines](#lua-code-style)
2. Update the README.md with details of changes if applicable
3. Update the CHANGELOG.md following the existing format
4. Increment version numbers in `opds_plus_version.lua` and `_meta.lua` if appropriate
5. Your PR will be reviewed by maintainers
6. Address any requested changes
7. Once approved, your PR will be merged

## Style Guidelines

### Lua Code Style

Follow KOReader's Lua coding conventions:

```lua
-- Use 4 spaces for indentation (no tabs)
function MyModule:myFunction(param1, param2)
    local result = self:someHelper(param1)
    if result then
        -- Do something
    end
    return result
end

-- Use descriptive variable names
local cover_height_ratio = 0.10  -- Good
local chr = 0.10                  -- Avoid

-- Add comments for complex logic
-- Calculate the optimal cover size based on screen dimensions
-- and user preferences while maintaining aspect ratio
local calculated_height = self:calculateCoverHeight()

-- Use local variables when possible
local function helperFunction()
    -- Implementation
end

-- Proper module structure
local MyModule = {
    setting1 = "default",
    setting2 = 100,
}

function MyModule:init()
    -- Initialization
end

return MyModule
```

**Key conventions:**
- 4 spaces for indentation
- `snake_case` for variables and functions
- `PascalCase` for class/module names
- Descriptive names over abbreviations
- Comment complex logic
- Use `local` keyword when possible
- Group related functions together

### Git Commit Messages

- Use the present tense ("Add feature" not "Added feature")
- Use the imperative mood ("Move cursor to..." not "Moves cursor to...")
- Limit the first line to 72 characters or less
- Reference issues and pull requests liberally after the first line
- Consider starting the commit message with an applicable emoji:
  - 🎨 `:art:` - Improving structure/format of the code
  - 🐛 `:bug:` - Fixing a bug
  - ✨ `:sparkles:` - New feature
  - 📝 `:memo:` - Documentation changes
  - 🚀 `:rocket:` - Performance improvements
  - ♻️ `:recycle:` - Refactoring code
  - 🔧 `:wrench:` - Configuration changes
  - ✅ `:white_check_mark:` - Adding tests

**Example:**
```
✨ Add custom border color option for grid view

- Implement border color selection (light gray, dark gray, black)
- Add color picker UI in grid settings menu
- Update grid rendering to use selected color
- Add border_color to default settings

Closes #42
```

### Documentation Style

- Use clear, concise language
- Include code examples where helpful
- Use headings to organize content
- Add emojis sparingly for visual appeal
- Keep line length reasonable (80-100 characters)
- Use proper markdown formatting

## Development Setup

### Prerequisites

- KOReader installed on a device or emulator
- Basic understanding of Lua programming
- Text editor (VS Code, Sublime, vim, etc.)
- Git for version control

### Setting Up Development Environment

1. **Clone your fork:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/opds_plus.koplugin.git
   cd opds_plus.koplugin
   ```

2. **Create a development branch:**
   ```bash
   git checkout -b feature/my-new-feature
   ```

3. **Link to KOReader plugins directory:**
   ```bash
   # Linux example
   ln -s $(pwd) ~/.config/koreader/plugins/opds_plus.koplugin

   # Or copy the directory
   cp -r . ~/.config/koreader/plugins/opds_plus.koplugin
   ```

4. **Enable Debug Mode:**
   - In KOReader: OPDS Plus → Settings → Developer → Debug Mode
   - This enables detailed logging for development

5. **Make your changes** and test in KOReader

6. **View logs:**
   - Check KOReader's crash.log for errors
   - Debug output appears in the log when debug mode is enabled

### File Structure Understanding

```
opds_plus.koplugin/
├── _meta.lua                 # Plugin metadata (name, version, description)
├── main.lua                  # Plugin initialization, settings UI, main entry point
├── opdsbrowserplus.lua       # Catalog browser logic, OPDS feed handling
├── opdslistmenuplus.lua      # List view rendering and layout
├── opdsgridmenuplus.lua      # Grid view rendering and layout
├── opdscovermenuplus.lua     # Cover display coordination between views
├── opdsparser.lua            # OPDS XML feed parsing
├── opdspse.lua               # Page streaming engine (Kavita support)
├── image_loader.lua          # Cover image downloading and caching
├── url_content.lua           # HTTP network operations
├── debug_helper.lua          # Debug logging utilities
└── opds_plus_version.lua     # Version number (single source of truth)
```

### Key Components

- **main.lua**: Settings management, menu structure, plugin lifecycle
- **opdsbrowserplus.lua**: OPDS feed navigation, download management
- **List/Grid Menu**: View-specific rendering logic
- **Cover Menu**: Coordinates between list and grid views
- **Parser**: Converts OPDS XML to usable data structures
- **Image Loader**: Asynchronous image loading with caching

## Testing

### Manual Testing Checklist

Before submitting a PR, test the following:

- [ ] List view displays correctly
- [ ] Grid view displays correctly
- [ ] Switching between views works
- [ ] Cover images load properly
- [ ] Settings persist after restart
- [ ] Font changes apply correctly
- [ ] Grid border settings work as expected
- [ ] Catalog browsing functions normally
- [ ] Book downloads work
- [ ] Search functionality works (if applicable)
- [ ] No crashes or errors in crash.log
- [ ] Memory usage is reasonable
- [ ] Performance is acceptable on e-ink devices

### Test on Multiple Catalogs

Test with different OPDS catalogs:
- Project Gutenberg (large catalog)
- Standard Ebooks (high-quality covers)
- Your local Calibre library (if available)
- Custom catalog with authentication

### Device Testing

If possible, test on:
- E-ink device (Kindle, Kobo)
- Android device
- Desktop (Linux/Windows/macOS)

### Debug Mode Testing

1. Enable Debug Mode in settings
2. Reproduce your changes
3. Check logs for any warnings or errors
4. Ensure debug output is helpful for troubleshooting

## Questions?

Feel free to:
- Open an issue for discussion
- Ask questions in pull requests
- Reach out to the maintainer

## Recognition

Contributors will be recognized in:
- Git commit history
- Release notes
- README credits (for significant contributions)

---

Thank you for contributing to OPDS Plus! 📚✨
