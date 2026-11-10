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
end)
