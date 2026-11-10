local helper = require("helper")

describe("ArchivePaths", function()
	local ArchivePaths
	local PREFIX = "opds_plus.koplugin"

	before_each(function()
		helper.reset()
		ArchivePaths = helper.load("utils.archive_paths")
	end)

	after_each(helper.reset)

	local function file(path, size)
		return { path = path, mode = "file", size = size or 1 }
	end

	local function dir(path)
		return { path = path, mode = "directory", size = 0 }
	end

	describe("entryPath", function()
		it("strips the top-level folder", function()
			assert.equals("main.lua", ArchivePaths.entryPath(PREFIX .. "/main.lua", PREFIX))
			assert.equals("core/parser.lua", ArchivePaths.entryPath(PREFIX .. "/core/parser.lua", PREFIX))
		end)

		it("takes a folder entry with a trailing slash", function()
			assert.equals("core", ArchivePaths.entryPath(PREFIX .. "/core/", PREFIX))
			assert.equals("", ArchivePaths.entryPath(PREFIX .. "/", PREFIX))
		end)

		it("refuses names that could escape the staging folder", function()
			local refused = {
				"/etc/passwd",
				"/" .. PREFIX .. "/main.lua",
				PREFIX .. "/../escaped.lua",
				PREFIX .. "/core/../../escaped.lua",
				PREFIX .. "/./main.lua",
				"..",
				PREFIX .. "//main.lua",
				PREFIX .. "\\..\\escaped.lua",
				PREFIX .. "/main.lua\0.txt",
				PREFIX .. "/line\nbreak.lua",
				PREFIX .. "/main.lua//",
				"",
			}
			for _, name in ipairs(refused) do
				local rel, err = ArchivePaths.entryPath(name, PREFIX)
				assert.is_nil(rel, name)
				assert.is_string(err, name)
			end
		end)

		it("refuses what is not a name", function()
			assert.is_nil(ArchivePaths.entryPath(nil, PREFIX))
			assert.is_nil(ArchivePaths.entryPath(42, PREFIX))
		end)

		it("refuses names outside the top-level folder", function()
			assert.is_nil(ArchivePaths.entryPath("main.lua", PREFIX))
			assert.is_nil(ArchivePaths.entryPath("other.koplugin/main.lua", PREFIX))
			assert.is_nil(ArchivePaths.entryPath(PREFIX .. ".evil/main.lua", PREFIX))
		end)

		it("refuses names that are too long or too deep", function()
			assert.is_nil(ArchivePaths.entryPath(PREFIX .. "/" .. ("a"):rep(256), PREFIX))
			assert.is_nil(ArchivePaths.entryPath(PREFIX .. ("/a"):rep(600), PREFIX))
			assert.is_nil(ArchivePaths.entryPath(PREFIX .. ("/a"):rep(16), PREFIX))
			assert.equals(("a/"):rep(14) .. "a", ArchivePaths.entryPath(PREFIX .. ("/a"):rep(15), PREFIX))
		end)
	end)

	describe("validate", function()
		it("returns every entry with its name inside the top-level folder and the total size", function()
			local checked, total = ArchivePaths.validate({
				dir(PREFIX .. "/"),
				file(PREFIX .. "/main.lua", 10),
				dir(PREFIX .. "/core/"),
				file(PREFIX .. "/core/parser.lua", 5),
			}, PREFIX)
			assert.equals(15, total)
			assert.same({ "", "main.lua", "core", "core/parser.lua" }, {
				checked[1].rel, checked[2].rel, checked[3].rel, checked[4].rel,
			})
			assert.equals("file", checked[2].mode)
		end)

		it("reads sizes that libarchive gives as 64-bit numbers", function()
			local _, total = ArchivePaths.validate({ file(PREFIX .. "/main.lua", 7LL) }, PREFIX)
			assert.equals(7, total)
		end)

		it("refuses links, devices and anything else that is not a file or folder", function()
			for _, mode in ipairs({ "link", "socket", "char device", "block device", "named pipe", "other" }) do
				local checked, err = ArchivePaths.validate({
					file(PREFIX .. "/main.lua"),
					{ path = PREFIX .. "/thing", mode = mode, size = 0 },
				}, PREFIX)
				assert.is_nil(checked, mode)
				assert.matches("not a file or folder", err)
			end
		end)

		it("refuses an archive with one unsafe name", function()
			local checked, err = ArchivePaths.validate({
				file(PREFIX .. "/main.lua"),
				file(PREFIX .. "/../../escaped.lua"),
			}, PREFIX)
			assert.is_nil(checked)
			assert.matches("unsafe", err)
		end)

		it("refuses an empty archive or one without files", function()
			assert.is_nil(ArchivePaths.validate({}, PREFIX))
			assert.is_nil(ArchivePaths.validate(nil, PREFIX))
			assert.is_nil(ArchivePaths.validate({ dir(PREFIX .. "/") }, PREFIX))
		end)

		it("refuses a top-level file", function()
			assert.is_nil(ArchivePaths.validate({ file(PREFIX) }, PREFIX))
		end)

		it("refuses names that collide, also when they differ only by case", function()
			assert.is_nil(ArchivePaths.validate({ file(PREFIX .. "/a.lua"), file(PREFIX .. "/a.lua") }, PREFIX))
			assert.is_nil(ArchivePaths.validate({ file(PREFIX .. "/a.lua"), file(PREFIX .. "/A.lua") }, PREFIX))
			assert.is_nil(ArchivePaths.validate({ file(PREFIX .. "/a"), dir(PREFIX .. "/a/") }, PREFIX))
			assert.is_truthy(ArchivePaths.validate({ dir(PREFIX .. "/a/"), dir(PREFIX .. "/a/"), file(PREFIX .. "/a/b") }, PREFIX))
		end)

		it("refuses a file that another entry uses as its folder", function()
			local checked, err = ArchivePaths.validate({ file(PREFIX .. "/a"), file(PREFIX .. "/a/b.lua") }, PREFIX)
			assert.is_nil(checked)
			assert.matches("file used as a folder", err)
		end)

		it("caps the number of entries and the total size", function()
			local many = {}
			for i = 1, 4 do
				many[i] = file(PREFIX .. "/" .. i .. ".lua", 10)
			end
			assert.is_nil(ArchivePaths.validate(many, PREFIX, { max_entries = 3 }))
			assert.is_nil(ArchivePaths.validate(many, PREFIX, { max_total_size = 39 }))
			assert.is_truthy(ArchivePaths.validate(many, PREFIX, { max_entries = 4, max_total_size = 40 }))
		end)

		it("refuses a file without a usable size", function()
			assert.is_nil(ArchivePaths.validate({ file(PREFIX .. "/a.lua", -1) }, PREFIX))
			assert.is_nil(ArchivePaths.validate({ { path = PREFIX .. "/a.lua", mode = "file" } }, PREFIX))
		end)
	end)
end)
