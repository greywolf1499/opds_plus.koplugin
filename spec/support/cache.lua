-- Stand-in for KOReader's frontend/cache.lua, for specs.
--
-- Covers what the plugin uses of a cache created with only `slots`: insert(key, value) and check(key)
-- take plain tables, and clear() empties it. There is no eviction, and no used_size() (the real Cache
-- has none either). spec/contract checks this against a real KOReader install.
--
--   local Cache = require("support.cache").new()
--   helper.stub("cache", Cache)
--   ... load the module under test ...
--   Cache.instances[1].items["opds|catalog|https://example.org/feed"]   -- what the module cached
local M = {}

function M.new()
	local Cache = { instances = {} }

	function Cache:new(options)
		local cache = { slots = options and options.slots, items = {} }

		function cache:insert(key, value)
			self.items[key] = value
		end

		function cache:check(key)
			return self.items[key]
		end

		function cache:clear()
			self.items = {}
		end

		Cache.instances[#Cache.instances + 1] = cache
		return cache
	end

	return Cache
end

return M
