local helper = require("helper")

describe("FileUtils", function()
	local FileUtils

	before_each(function()
		helper.reset()
		FileUtils = helper.load("utils.file_utils")
	end)

	after_each(helper.reset)

	describe("ensureExtension", function()
		it("returns nil when there is no file name", function()
			assert.is_nil(FileUtils.ensureExtension(nil, "epub"))
		end)

		it("returns the file name as it is when there is no file type", function()
			assert.equals("My Book", FileUtils.ensureExtension("My Book", nil))
		end)

		it("adds the file type in lowercase to a name without a suffix", function()
			assert.equals("My Book.epub", FileUtils.ensureExtension("My Book", "EPUB"))
		end)

		it("keeps a name that has a suffix when it cannot tell which suffixes are known", function()
			assert.equals("My Book.pdf", FileUtils.ensureExtension("My Book.pdf", "epub"))
			assert.equals("Dr. Who", FileUtils.ensureExtension("Dr. Who", "epub"))
		end)

		it("keeps a name whose suffix is known", function()
			local name = FileUtils.ensureExtension("My Book.pdf", "epub", function(suffix)
				return suffix == "pdf"
			end)
			assert.equals("My Book.pdf", name)
		end)

		it("adds the file type after a suffix that is not known instead of replacing it", function()
			local function nothing_is_known()
				return false
			end
			assert.equals("Dr. Who.epub", FileUtils.ensureExtension("Dr. Who", "epub", nothing_is_known))
			assert.equals("v1.2.epub", FileUtils.ensureExtension("v1.2", "epub", nothing_is_known))
		end)

		it("asks about the last suffix, as written and without the dot", function()
			local asked = {}
			FileUtils.ensureExtension("a.tar.GZ", "epub", function(suffix)
				table.insert(asked, suffix)
				return true
			end)
			assert.same({ "GZ" }, asked)
		end)

		it("does not ask about a suffix when the name has none", function()
			local asked = false
			local name = FileUtils.ensureExtension("My Book", "epub", function()
				asked = true
				return true
			end)
			assert.is_false(asked)
			assert.equals("My Book.epub", name)
		end)
	end)

	describe("sanitize", function()
		it("replaces the path separator but keeps other characters the file system allows", function()
			assert.equals("a_b:c.epub", FileUtils.sanitize("a/b:c.epub", "/books"))
		end)

		it("leaves nothing in a name that could point outside the directory", function()
			assert.is_nil(FileUtils.sanitize("../../etc/passwd", "/books"):find("/", 1, true))
		end)

		it("replaces every character that FAT does not allow when no directory is given", function()
			assert.equals("a_b_c_.epub", FileUtils.sanitize("a/b:c?.epub"))
		end)
	end)

	describe("fixUtf8", function()
		it("leaves valid UTF-8 as it is", function()
			assert.equals("caf\u{e9} \u{2615}.epub", FileUtils.fixUtf8("caf\u{e9} \u{2615}.epub"))
		end)

		it("replaces invalid bytes with an underscore", function()
			assert.equals("a_b", FileUtils.fixUtf8("a\255b"))
			assert.equals("caf_", FileUtils.fixUtf8("caf\195"))
		end)

		it("replaces invalid bytes with the given text", function()
			assert.equals("a?b", FileUtils.fixUtf8("a\255b", "?"))
		end)

		it("drops invalid bytes when the replacement is an empty string", function()
			assert.equals("ab", FileUtils.fixUtf8("a\255b", ""))
		end)
	end)

	describe("removeTree", function()
		local lfs = require("lfs")
		local fs = helper.fs
		local root

		before_each(function()
			root = helper.tmpdir()
		end)

		-- Files at every level and an empty folder
		local function tree(path)
			fs.write(path .. "/a.txt", "a")
			fs.write(path .. "/sub/b.txt", "b")
			fs.write(path .. "/sub/deeper/c.txt", "c")
			fs.mkdirs(path .. "/empty")
			return path
		end

		it("removes a folder with everything in it", function()
			local path = tree(root .. "/old")
			assert.is_true(FileUtils.removeTree(path))
			assert.is_false(fs.exists(path))
			assert.is_true(fs.exists(root))
		end)

		it("removes a single file", function()
			local path = fs.write(root .. "/old.zip", "zip")
			assert.is_true(FileUtils.removeTree(path))
			assert.is_false(fs.exists(path))
		end)

		it("has nothing to do for a path that does not exist", function()
			assert.is_true(FileUtils.removeTree(root .. "/missing"))
			assert.is_true(FileUtils.removeTree(root .. "/missing/deeper"))
		end)

		it("removes a link in the tree without touching what it points to", function()
			local repo = tree(root .. "/repo")
			local path = fs.mkdirs(root .. "/old/inner")
			assert(lfs.link(repo, path .. "/link", true))
			assert.is_true(FileUtils.removeTree(root .. "/old"))
			assert.is_false(fs.exists(root .. "/old"))
			assert.same({ "a.txt", "empty", "sub" }, fs.list(repo))
			assert.equals("c", fs.read(repo .. "/sub/deeper/c.txt"))
		end)

		it("removes a link that is the path itself, and only the link", function()
			local repo = tree(root .. "/repo")
			assert(lfs.link(repo, root .. "/old.bak", true))
			assert.is_true(FileUtils.removeTree(root .. "/old.bak"))
			assert.is_false(fs.exists(root .. "/old.bak"))
			assert.same({ "a.txt", "empty", "sub" }, fs.list(repo))
		end)

		it("does not follow a link that is given with a trailing slash", function()
			-- With a trailing slash the system looks through a link, and it would show the folder it points to
			local repo = tree(root .. "/repo")
			assert(lfs.link(repo, root .. "/old.bak", true))
			FileUtils.removeTree(root .. "/old.bak/")
			assert.is_false(fs.exists(root .. "/old.bak"))
			assert.same({ "a.txt", "empty", "sub" }, fs.list(repo))
			assert.equals("c", fs.read(repo .. "/sub/deeper/c.txt"))
		end)

		it("removes a link to a file without touching the file", function()
			local file = fs.write(root .. "/keep.txt", "keep")
			assert(lfs.link(file, root .. "/link", true))
			assert.is_true(FileUtils.removeTree(root .. "/link"))
			assert.is_false(fs.exists(root .. "/link"))
			assert.equals("keep", fs.read(file))
		end)

		it("removes a link that points nowhere", function()
			assert(lfs.link(root .. "/gone", root .. "/dangling", true))
			assert.is_true(FileUtils.removeTree(root .. "/dangling"))
			assert.is_false(fs.exists(root .. "/dangling"))
		end)

		it("takes a trailing slash on a folder", function()
			local path = tree(root .. "/old")
			assert.is_true(FileUtils.removeTree(path .. "/"))
			assert.is_false(fs.exists(path))
		end)

		it("reports what it could not remove, and removes the rest", function()
			local path = tree(root .. "/old")
			os.execute("chmod 555 '" .. path .. "/sub'")
			local ok, err = FileUtils.removeTree(path)
			os.execute("chmod 755 '" .. path .. "/sub'")
			if ok then
				return pending("this user can remove files from a read-only folder")
			end
			assert.is_nil(ok)
			assert.matches("sub", err, 1, true)
			assert.is_false(fs.exists(path .. "/a.txt"))
			assert.is_false(fs.exists(path .. "/empty"))
			assert.is_true(fs.exists(path .. "/sub/b.txt"))
		end)
	end)

	-- Refusals run against an in-memory lfs and os.remove: a dangerous path never reaches a live
	-- deletion primitive, even if the guard in removeTree is broken.
	describe("removeTree refusals", function()
		local live_remove
		local touched

		-- A fake filesystem in which "/" holds a whole tree, so a broken guard would visibly traverse it.
		local function fake_lfs()
			local tree = {
				["/"] = { "home", "tmp" },
				["/home"] = { "user" },
				["/home/user"] = {},
				["/tmp"] = { "opds_plus_test_fake" },
				["/tmp/opds_plus_test_fake"] = { "old" },
				["/tmp/opds_plus_test_fake/old"] = { "a.txt" },
			}
			local function record(name, path)
				touched[#touched + 1] = name .. " " .. tostring(path)
			end
			local function key(path)
				return path == "" and "/" or path
			end
			return {
				symlinkattributes = function(path)
					record("symlinkattributes", path)
					if tree[key(path)] then
						return "directory"
					end
					return path:match("%.txt$") and "file" or nil
				end,
				attributes = function(path)
					record("attributes", path)
					return tree[key(path)] and "directory" or nil
				end,
				dir = function(path)
					record("dir", path)
					local names, i = tree[key(path)] or {}, 0
					return function()
						i = i + 1
						return names[i]
					end
				end,
				rmdir = function(path)
					record("rmdir", path)
					return true
				end,
				mkdir = function(path)
					record("mkdir", path)
					return true
				end,
			}
		end

		before_each(function()
			helper.reset()
			touched = {}
			live_remove = os.remove
			os.remove = function(path) -- luacheck: ignore 122
				touched[#touched + 1] = "os.remove " .. tostring(path)
				return true
			end
			FileUtils = helper.load("utils.file_utils", { ["libs/libkoreader-lfs"] = fake_lfs() })
		end)

		after_each(function()
			os.remove = live_remove -- luacheck: ignore 122
			helper.reset()
		end)

		it("uses the fakes, not the live lfs and os.remove", function()
			assert.is_true(FileUtils.removeTree("/tmp/opds_plus_test_fake/old"))
			assert.is_truthy(table.concat(touched, "\n"):find("rmdir /tmp/opds_plus_test_fake/old", 1, true))
			assert.is_truthy(table.concat(touched, "\n"):find("os.remove /tmp/opds_plus_test_fake/old/a.txt", 1, true))
		end)

		it("refuses a path that could remove more than was meant, without touching anything", function()
			local old = "/tmp/opds_plus_test_fake/old"
			local refused = {
				"", "/", "//", "///", ".", "..", "~", "~/", "old", "relative/old",
				old .. "/..", old .. "/.", old .. "/../old", "/tmp/opds_plus_test_fake/./old", "/tmp/../",
			}
			for _, text in ipairs(refused) do
				local ok, err = FileUtils.removeTree(text)
				assert.is_nil(ok, text)
				assert.is_string(err, text)
			end
			assert.same({}, touched)
		end)

		it("refuses what is not a path, without touching anything", function()
			assert.is_nil(FileUtils.removeTree(nil))
			assert.is_nil(FileUtils.removeTree(42))
			assert.is_nil(FileUtils.removeTree({}))
			assert.same({}, touched)
		end)
	end)
end)
