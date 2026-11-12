local helper = require("helper")
local ui_stub = require("support.ui")

describe("SettingsMenu", function()
	-- Items whose job is done once they run, so the menu may close after them.
	local ACTIONS = {
		["Browse Catalogs"] = true,
		["Clear Cover Cache"] = true,
		["Check for updates"] = true,
		["Roll back to previous version"] = true,
	}

	local items

	-- Every item of the menu, submenus and the default-catalog choices included.
	local function walk(list, out)
		for _, item in ipairs(list) do
			table.insert(out, item)
			if item.sub_item_table then
				walk(item.sub_item_table, out)
			elseif item.sub_item_table_func then
				walk(item.sub_item_table_func(), out)
			end
		end
		return out
	end

	before_each(function()
		helper.reset()
		local stubs = ui_stub.new().stubs
		stubs["ui.dialogs.update_dialog"] = {}
		local SettingsMenu = helper.load("config.settings_menu", stubs)
		local plugin = {
			settings = {},
			servers = { { title = "Example catalog" } },
			getSetting = function() return nil end,
		}
		items = walk(SettingsMenu.create(plugin), {})
	end)

	after_each(helper.reset)

	-- KOReader keeps the menu open after a checkable item by itself; the others need the flag.
	it("keeps the menu open after an item that opens a setting's dialog", function()
		local dialogs = 0
		for _, item in ipairs(items) do
			local text = item.text or ""
			if item.callback and not item.checked_func and not ACTIONS[text] and not text:find("^About") then
				dialogs = dialogs + 1
				assert.is_true(item.keep_menu_open, text)
			end
		end
		assert.equals(9, dialogs)
	end)

	it("closes the menu after an action", function()
		local actions = 0
		for _, item in ipairs(items) do
			if ACTIONS[item.text] then
				actions = actions + 1
				assert.is_nil(item.keep_menu_open, item.text)
			end
		end
		assert.equals(4, actions)
	end)
end)
