-- The containment check behind the spec filesystem guards. Query-only: nothing here deletes anything.
local helper = require("helper")
local lfs = require("lfs")

describe("spec fs containment", function()
	local fs = helper.fs
	local root

	before_each(function()
		helper.reset()
		root = helper.tmpdir()
	end)

	after_each(helper.reset)

	it("creates fixture roots as /tmp/opds_plus_test_<hex> directories", function()
		assert.matches("^/tmp/opds_plus_test_%x+$", root)
		assert.equals("directory", lfs.symlinkattributes(root, "mode"))
	end)

	it("owns a root and the paths inside it", function()
		assert.equals(root, fs.owning_root(root))
		assert.equals(root, fs.owning_root(root .. "/a/b.txt"))
		assert.equals(root, fs.owning_root(root .. "/./a"))
	end)

	it("owns nothing outside the registered roots", function()
		local outside = {
			"", "/", "//", "~", "/tmp", "/tmp/", "/home", os.getenv("HOME") or "/root",
			root .. "/..", root .. "/../other", root .. "x", "/tmp/opds_plus_test_0", lfs.currentdir(),
		}
		for _, path in ipairs(outside) do
			assert.is_nil(fs.owning_root(path), path)
		end
		assert.is_nil(fs.owning_root(nil))
	end)

	it("does not own a path that passes through a symlink", function()
		assert(lfs.link("/tmp", root .. "/escape", true))
		assert.is_nil(fs.owning_root(root .. "/escape/file"))
		assert.equals(root, fs.owning_root(root .. "/escape"))
	end)

	it("forgets roots after cleanup", function()
		helper.reset()
		assert.is_nil(fs.owning_root(root))
	end)
end)
