-- The OTA test doubles agree with known answers. spec/contract/ota_real_libs_spec.lua checks them
-- against KOReader's real ffi/archiver and ffi/sha2.
local helper = require("helper")
local zipbuilder = require("support.zipbuilder")
local fake_archiver = require("support.fake_archiver")
local sha256 = require("support.sha256_stub").sha256

describe("OTA test doubles", function()
	before_each(helper.reset)
	after_each(helper.reset)

	it("sha256_stub matches the FIPS 180-4 test vectors", function()
		assert.equals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sha256(""))
		assert.equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256("abc"))
		assert.equals(
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
			sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
		)
		assert.equals("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", sha256(("a"):rep(1000000)))
	end)

	it("zipbuilder.crc32 matches the standard check value", function()
		assert.equals(0xCBF43926, zipbuilder.crc32("123456789"))
	end)

	it("fake_archiver reads back what zipbuilder wrote", function()
		local dir = helper.tmpdir()
		local path = helper.fs.write(dir .. "/a.zip", zipbuilder.build({
			{ path = "p/", mode = "directory" },
			{ path = "p/main.lua", content = "return 1\n" },
			{ path = "p/link", mode = "link", content = "/etc" },
			{ path = "p/../evil", content = "x" },
		}))
		local archiver = fake_archiver.new()
		local reader = archiver.Reader:new()
		assert.is_true(reader:open(path))
		local seen = {}
		for entry in reader:iterate() do
			seen[#seen + 1] = { entry.path, entry.mode, entry.size }
		end
		assert.same({
			{ "p/", "directory", 0 },
			{ "p/main.lua", "file", 9 },
			{ "p/link", "link", 0 },
			{ "p/../evil", "file", 1 },
		}, seen)
		assert.equals("return 1\n", reader:extractToMemory("p/main.lua"))
		assert.is_true(reader:extractToPath("p/main.lua", dir .. "/out.lua"))
		assert.equals("return 1\n", helper.fs.read(dir .. "/out.lua"))
		reader:close()
	end)
end)
