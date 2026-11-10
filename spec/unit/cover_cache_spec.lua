local helper = require("helper")
local lfs = require("lfs")
local datastorage = require("support.datastorage")

describe("CoverCache", function()
	local fs = helper.fs
	local URL = "https://example.org/cover.jpg"
	local URL_FILE = "b06864f92fa8780f.img"
	local NOW = 1700000000

	local CoverCache, data_dir, cache_dir, original_cwd

	-- The module reads the data directory once, when it is loaded, so loading again needs a fresh start.
	local function load(storage)
		package.loaded["services.cover_cache"] = nil
		CoverCache = helper.load("services.cover_cache", { datastorage = storage })
	end

	-- Names of the files in the cover directory.
	local function stored()
		if lfs.attributes(cache_dir, "mode") ~= "directory" then
			return {}
		end
		return fs.list(cache_dir)
	end

	-- Stores a cover that is not cached yet and returns the path of the file that holds it.
	local function store(url, content)
		local before = {}
		for _, name in ipairs(stored()) do
			before[name] = true
		end
		assert.is_true(CoverCache.put(url, content))
		for _, name in ipairs(stored()) do
			if not before[name] then
				return cache_dir .. "/" .. name
			end
		end
	end

	-- Makes a stored cover look as if it was written `seconds` ago.
	local function age(path, seconds)
		lfs.touch(path, NOW - seconds, NOW - seconds)
	end

	before_each(function()
		helper.reset()
		data_dir = helper.tmpdir()
		cache_dir = data_dir .. "/cache/opds_plus/covers"
		helper.global("os", setmetatable({
			time = function()
				return NOW
			end,
		}, { __index = os }))
		load(datastorage.new(data_dir))
	end)

	after_each(function()
		if original_cwd then
			lfs.chdir(original_cwd)
			original_cwd = nil
		end
		helper.reset()
	end)

	describe("file names", function()
		local cases = {
			{ "a typical cover URL", URL, URL_FILE },
			{ "a one-character URL", "x", "0002b5dd050c5d97.img" },
			{
				"a URL with a query",
				"https://example.org/opds/cover/1234?size=large&format=jpg",
				"02febc39233926e9.img",
			},
			{
				"a long URL",
				("https://example.org/very/long/path/"):rep(10) .. "cover.jpg",
				"4611725bbf3be5e9.img",
			},
			{ "a URL with non-ASCII characters", "https://example.org/caf\195\169.jpg", "0f9c9f9ab88bc906.img" },
		}
		for _, case in ipairs(cases) do
			it("keeps the cover of " .. case[1] .. " in " .. case[3], function()
				CoverCache.put(case[2], "data")

				assert.same({ case[3] }, stored())
			end)
		end

		it("gives URLs that differ in one character different files", function()
			for i = 1, 3 do
				CoverCache.put(URL .. "?x=" .. i, "data")
			end

			assert.equals(3, #stored())
		end)
	end)

	describe("location", function()
		it("is cache/opds_plus/covers under the data directory", function()
			CoverCache.put(URL, "data")

			assert.same({ URL_FILE }, fs.list(data_dir .. "/cache/opds_plus/covers"))
		end)

		it("is not created until a cover is stored", function()
			assert.is_nil(lfs.attributes(data_dir .. "/cache", "mode"))
		end)

		it("uses the data directory when KOReader has no getFullDataDir", function()
			load({
				getDataDir = function()
					return data_dir
				end,
			})

			CoverCache.put(URL, "data")

			assert.same({ URL_FILE }, stored())
		end)

		it("uses the data directory when getFullDataDir has no answer", function()
			load({
				getFullDataDir = function() end,
				getDataDir = function()
					return data_dir
				end,
			})

			CoverCache.put(URL, "data")

			assert.same({ URL_FILE }, stored())
		end)

		it("prefers the full data directory over the data directory", function()
			local other_dir = helper.tmpdir()
			load({
				getFullDataDir = function()
					return data_dir
				end,
				getDataDir = function()
					return other_dir
				end,
			})

			CoverCache.put(URL, "data")

			assert.same({ URL_FILE }, stored())
			assert.same({}, fs.list(other_dir))
		end)

		it("stays relative to the working directory when the data directory is relative", function()
			load({
				getDataDir = function()
					return "."
				end,
			})
			original_cwd = lfs.currentdir()
			assert.is_true(lfs.chdir(data_dir))

			CoverCache.put(URL, "data")

			assert.same({ URL_FILE }, stored())
		end)
	end)

	describe("get", function()
		it("returns nil for a cover that was never stored", function()
			assert.is_nil(CoverCache.get(URL))
		end)

		it("returns the stored bytes and how old they are", function()
			local content = "\255\216\255\224\0\16JFIF\0\r\n\26"
			age(store(URL, content), 90)

			assert.same({ content = content, stale = false, age_seconds = 90 }, CoverCache.get(URL))
		end)

		it("keeps the covers of different URLs apart", function()
			store(URL, "first")
			store("https://example.org/other.jpg", "second")

			assert.equals("first", CoverCache.get(URL).content)
			assert.equals("second", CoverCache.get("https://example.org/other.jpg").content)
		end)

		it("does not make a cover younger by reading it", function()
			age(store(URL, "data"), 500)

			CoverCache.get(URL)

			assert.equals(500, CoverCache.get(URL).age_seconds)
		end)

		describe("with a ttl", function()
			it("treats a cover younger than the ttl as fresh", function()
				age(store(URL, "data"), 3599)

				assert.is_false(CoverCache.get(URL, 3600).stale)
			end)

			it("treats a cover exactly as old as the ttl as fresh", function()
				age(store(URL, "data"), 3600)

				assert.is_false(CoverCache.get(URL, 3600).stale)
			end)

			it("marks a cover older than the ttl as stale but still returns it", function()
				age(store(URL, "data"), 3601)

				local cached = CoverCache.get(URL, 3600)

				assert.is_true(cached.stale)
				assert.equals("data", cached.content)
				assert.equals(3601, cached.age_seconds)
			end)

			it("never marks a cover stale when there is no ttl", function()
				age(store(URL, "data"), 10 * 365 * 24 * 3600)

				assert.is_false(CoverCache.get(URL).stale)
			end)
		end)

		it("returns nil for an empty cover file", function()
			fs.write(store(URL, "data"), "")

			assert.is_nil(CoverCache.get(URL))
		end)

		it("returns nil when the cover path is a directory", function()
			local path = store(URL, "data")
			os.remove(path)
			assert.is_true(lfs.mkdir(path))

			assert.is_nil(CoverCache.get(URL))
		end)
	end)

	describe("put", function()
		it("creates the cache directories on first use", function()
			assert.is_true(CoverCache.put(URL, "data"))

			assert.equals("directory", lfs.attributes(cache_dir, "mode"))
		end)

		it("uses cache directories that already exist", function()
			fs.mkdirs(cache_dir)

			assert.is_true(CoverCache.put(URL, "data"))

			assert.equals("data", CoverCache.get(URL).content)
		end)

		it("leaves one cover file and no temporary file", function()
			assert.is_true(CoverCache.put(URL, "data"))

			assert.same({ URL_FILE }, stored())
		end)

		it("replaces the cover of a URL that is already stored", function()
			store(URL, "old cover")

			assert.is_true(CoverCache.put(URL, "new"))

			assert.equals("new", CoverCache.get(URL).content)
			assert.same({ URL_FILE }, stored())
		end)

		it("makes a replaced cover young again", function()
			age(store(URL, "old cover"), 7200)

			CoverCache.put(URL, "new")

			assert.is_false(CoverCache.get(URL, 3600).stale)
		end)

		local unusable = { { "missing", nil }, { "empty", "" } }
		for _, case in ipairs(unusable) do
			it("returns false and stores nothing when the content is " .. case[1], function()
				assert.is_false(CoverCache.put(URL, case[2]))

				assert.same({}, stored())
				assert.is_nil(lfs.attributes(data_dir .. "/cache", "mode"))
			end)
		end

		it("keeps the earlier cover and returns false when the new one can't be written", function()
			local path = store(URL, "old cover")
			assert.is_true(lfs.mkdir(path .. ".tmp"))

			assert.is_false(CoverCache.put(URL, "new"))

			assert.equals("old cover", CoverCache.get(URL).content)
		end)

		it("returns false and leaves no temporary file when the cover can't be moved into place", function()
			local path = store(URL, "old cover")
			os.remove(path)
			assert.is_true(lfs.mkdir(path))

			assert.is_false(CoverCache.put(URL, "new"))

			assert.same({ URL_FILE }, stored())
		end)

		it("returns false when the cache directory can't be created", function()
			local blocker = fs.write(helper.tmpdir() .. "/not-a-directory", "x")
			load({
				getFullDataDir = function()
					return blocker .. "/data"
				end,
			})

			assert.is_false(CoverCache.put(URL, "data"))
			assert.equals("x", fs.read(blocker))
		end)

		describe("with a size cap", function()
			-- Three 10-byte covers whose modification times differ from the order they were stored in.
			local function threeCovers()
				local newest = store("https://example.org/newest.jpg", ("n"):rep(10))
				local oldest = store("https://example.org/oldest.jpg", ("o"):rep(10))
				local middle = store("https://example.org/middle.jpg", ("m"):rep(10))
				lfs.touch(newest, 3000, 3000)
				lfs.touch(oldest, 1000, 1000)
				lfs.touch(middle, 2000, 2000)
				return newest, oldest, middle
			end

			local FRESH = "https://example.org/fresh.jpg"

			it("evicts the oldest covers first, only until the total fits", function()
				local newest, oldest, middle = threeCovers()

				assert.is_true(CoverCache.put(FRESH, ("f"):rep(10), 25))

				assert.is_false(fs.exists(oldest))
				assert.is_false(fs.exists(middle))
				assert.is_true(fs.exists(newest))
				assert.equals("ffffffffff", CoverCache.get(FRESH).content)
			end)

			it("evicts nothing when the total is exactly the cap", function()
				threeCovers()

				CoverCache.put(FRESH, ("f"):rep(10), 40)

				assert.equals(4, #stored())
			end)

			it("evicts a cover when the total is one byte over the cap", function()
				local newest, oldest, middle = threeCovers()

				CoverCache.put(FRESH, ("f"):rep(10), 39)

				assert.is_false(fs.exists(oldest))
				assert.is_true(fs.exists(middle))
				assert.is_true(fs.exists(newest))
				assert.equals(3, #stored())
			end)

			it("neither counts nor removes files that are not covers", function()
				threeCovers()
				fs.write(cache_dir .. "/notes.txt", ("z"):rep(1000))
				fs.write(cache_dir .. "/leftover.img.tmp", ("z"):rep(1000))

				CoverCache.put(FRESH, ("f"):rep(10), 40)

				assert.equals(6, #stored())
			end)

			it("does not count a directory that has a cover-like name", function()
				threeCovers()
				assert.is_true(lfs.mkdir(cache_dir .. "/folder.img"))

				CoverCache.put(FRESH, ("f"):rep(10), 40)

				assert.equals(5, #stored())
			end)

			it("evicts nothing when the new cover can't be written", function()
				local newest, oldest, middle = threeCovers()
				local fresh_path = store(FRESH, "f")
				os.remove(fresh_path)
				assert.is_true(lfs.mkdir(fresh_path .. ".tmp"))

				assert.is_false(CoverCache.put(FRESH, ("f"):rep(10), 5))

				assert.is_true(fs.exists(newest))
				assert.is_true(fs.exists(oldest))
				assert.is_true(fs.exists(middle))
			end)

			local unlimited = { { "no cap", nil }, { "a cap of 0", 0 }, { "a negative cap", -5 } }
			for _, case in ipairs(unlimited) do
				it("evicts nothing with " .. case[1], function()
					threeCovers()

					CoverCache.put(FRESH, ("f"):rep(10), case[2])

					assert.equals(4, #stored())
				end)
			end
		end)
	end)

	describe("clear", function()
		it("removes every cached cover", function()
			store(URL, "one")
			store("https://example.org/other.jpg", "two")

			CoverCache.clear()

			assert.same({}, stored())
			assert.is_nil(CoverCache.get(URL))
		end)

		it("removes leftover temporary files", function()
			store(URL, "one")
			fs.write(cache_dir .. "/" .. URL_FILE .. ".tmp", "half a cover")

			CoverCache.clear()

			assert.same({}, stored())
		end)

		it("keeps the cache directory and files that are not covers", function()
			store(URL, "one")
			fs.write(cache_dir .. "/notes.txt", "keep me")

			CoverCache.clear()

			assert.same({ "notes.txt" }, stored())
		end)

		it("does nothing when nothing was ever cached", function()
			assert.has_no.errors(CoverCache.clear)

			assert.is_nil(lfs.attributes(data_dir .. "/cache", "mode"))
		end)
	end)

	describe("purge", function()
		it("removes the covers and the plugin's cache directories but keeps the shared cache directory", function()
			store(URL, "one")

			CoverCache.purge()

			assert.is_nil(lfs.attributes(data_dir .. "/cache/opds_plus", "mode"))
			assert.equals("directory", lfs.attributes(data_dir .. "/cache", "mode"))
			assert.is_nil(CoverCache.get(URL))
		end)

		it("keeps the directories when a file that is not a cover is still in them", function()
			store(URL, "one")
			fs.write(cache_dir .. "/notes.txt", "keep me")

			CoverCache.purge()

			assert.same({ "notes.txt" }, stored())
		end)

		it("keeps the plugin's cache directory when it holds something else too", function()
			store(URL, "one")
			fs.write(data_dir .. "/cache/opds_plus/other/data.bin", "keep me")

			CoverCache.purge()

			assert.is_nil(lfs.attributes(cache_dir, "mode"))
			assert.equals("keep me", fs.read(data_dir .. "/cache/opds_plus/other/data.bin"))
		end)

		it("does nothing when nothing was ever cached", function()
			assert.has_no.errors(CoverCache.purge)
		end)
	end)
end)
