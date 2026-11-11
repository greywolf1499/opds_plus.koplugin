local helper = require("helper")
local ui_stub = require("support.ui")

describe("ImageLoader scheduling", function()
	local ImageLoader, ui, clock, directory
	local children, paths, cached, writes, requests, kills, next_pid
	local can_fork, cache_ok, errors, fetch_content, cache_stores, cache_key

	local function use_http()
		package.loaded["services.http_client"] = nil
		local http = require("support.fake_http").new()
		local client = helper.load("services.http_client", {
			["socket.http"] = http, socketutil = require("support.socketutil").new(),
			["ffi/sha2"] = require("support.sha256_stub"),
		})
		fetch_content = client.getUrlContent
		cache_key = client.cacheKey
		return http, client
	end

	local function step()
		local task = table.remove(ui.scheduled, 1)
		assert(task, "no scheduled task")
		clock = clock + task.seconds
		task.callback()
	end

	local function complete(pid)
		children[pid].work()
		children[pid].done = true
	end

	local function finish(batch)
		for _ = 1, 100 do
			if not batch.loading then return end
			step()
		end
		error("batch never finished")
	end

	before_each(function()
		helper.reset()
		directory = helper.tmpdir()
		ui = ui_stub.new()
		clock, next_pid = 0, 0
		can_fork, cache_ok, errors = true, true, {}
		cache_stores = false
		cache_key = function(url) return url end
		children, paths, cached, writes, requests, kills = {}, {}, {}, {}, {}, {}
		fetch_content = function(url)
			requests[#requests + 1] = url
			return true, "downloaded " .. url
		end
		helper.global("os", setmetatable({
			tmpname = function()
				local path = directory .. "/image-" .. (#paths + 1)
				paths[#paths + 1] = path
				helper.fs.write(path, "")
				return path
			end,
		}, { __index = os }))
		ImageLoader = helper.load("services.image_loader", {
			["ui/uimanager"] = ui.UIManager,
			["ui/time"] = {
				now = function() return clock end,
				s = function(seconds) return seconds end,
			},
			["ffi/posix_h"] = {},
			ffi = {
				os = "Test",
				C = {
					getpid = function() return 100 end,
					kill = function(pid)
						kills[#kills + 1] = pid
						children[pid].done = true
					end,
				},
			},
			["ffi/util"] = {
				runInSubProcess = function(work)
					if not can_fork then return nil end
					next_pid = next_pid + 1
					children[next_pid] = { work = work }
					return next_pid
				end,
				isSubProcessDone = function(pid)
					local child = children[pid]
					assert.is_nil(child.reaped, "must never reap or kill an already reaped PID")
					if child.done then
						child.reaped = true
						return true
					end
					return false
				end,
			},
			["services.http_client"] = {
				getUrlContent = function(...) return fetch_content(...) end,
				cacheKey = function(...) return cache_key(...) end,
			},
			["services.cover_cache"] = {
				get = function(url) return cached[url] end,
				put = function(url, content)
					writes[#writes + 1] = { url, content }
					if cache_stores and cache_ok then cached[url] = { content = content } end
					return cache_ok
				end,
			},
			["utils.debug"] = {
				log = function() end,
				error = function(...) errors[#errors + 1] = { ... } end,
			},
		})
	end)

	after_each(helper.reset)

	it("scopes mixed-origin covers in workers, serial loads, fork fallback and prefetch", function()
		local http = use_http()
		http:on(function() return true end, { code = 200, body = "image" })
		for _, mode in ipairs({ "worker", "serial", "fallback", "prefetch" }) do
			can_fork = mode ~= "fallback"
			local urls = { "https://catalog.example/cover/" .. mode, "https://cdn.example/cover/" .. mode }
			local batch
			if mode == "prefetch" then
				batch = ImageLoader:prefetch(urls, "reader", "secret", nil, nil, nil, "https://catalog.example/opds")
			else
				batch = ImageLoader:loadImages(urls, nil, "reader", "secret", false,
					nil, nil, mode ~= "serial", "https://catalog.example/opds")
			end
			step()
			step()
			if mode == "worker" or mode == "prefetch" then
				complete(next_pid - 1)
				complete(next_pid)
			end
			finish(batch)
			assert.equals("reader", http.requests[#http.requests - 1].user, mode)
			assert.equals("secret", http.requests[#http.requests - 1].password, mode)
			assert.is_nil(http.requests[#http.requests].user, mode)
			assert.is_nil(http.requests[#http.requests].password, mode)
		end
	end)

	it("does not reuse a private cached cover for another account or an unauthenticated request", function()
		local http = use_http()
		local url = "https://catalog.example/cover"
		local delivered = {}
		cache_stores = true
		cached[url] = { content = "unscoped legacy cover" }
		http:on(url, function(request)
			if not request.user or request.password ~= "secret" then return { code = 401 } end
			return { code = 200, body = "private-" .. request.user }
		end)
		local function load(username, origin, password)
			local batch = ImageLoader:loadImages({ url }, function(_url, content)
				delivered[#delivered + 1] = content
			end, username, password or "secret", true, nil, nil, false, origin)
			finish(batch)
		end
		load("ann", "https://catalog.example/opds")
		load("bob", "https://catalog.example/opds")
		assert.same({ "private-ann", "private-bob" }, delivered)
		load("ann", "https://foreign.example/opds")
		assert.equals(3, #http.requests)
		assert.same({ "private-ann", "private-bob" }, delivered)
		load("ann", "https://catalog.example/opds", "pw")
		assert.equals(4, #http.requests)
		assert.same({ "private-ann", "private-bob" }, delivered)
		load("ann", "https://catalog.example/opds")
		assert.equals(4, #http.requests)
		assert.equals("private-ann", delivered[3])
	end)

	it("isolates redirect headers and commits a worker result under its original cache identity", function()
		local http, client = use_http()
		local url, other = "https://catalog.example/cover", "https://cdn.example/cover"
		local header = { name = "Authorization", value = "Bearer first" }
		local delivered = {}
		cache_stores = true
		client.setCatalogs({ { url = other, headers = { header } } })
		http:on(url, { code = 302, headers = { Location = other } })
		http:on(other, function(request)
			return { code = 200, body = request.headers.Authorization }
		end)
		local function load()
			return ImageLoader:loadImages({ url }, function(_url, content)
				delivered[#delivered + 1] = content
			end)
		end
		local first = load()
		step()
		complete(1)
		header.value = "Bearer second"
		finish(first)
		local second = load()
		step()
		assert.is_not_nil(children[2], "changed redirect credentials must not hit the first worker's cache")
		complete(2)
		finish(second)
		assert.same({ "Bearer first", "Bearer second" }, delivered)
		assert.equals(4, #http.requests)
		header.value = "Bearer first"
		finish(load())
		assert.equals("Bearer first", delivered[3])
		assert.equals(4, #http.requests)
	end)

	it("refreshes pending cache context after waiting for a worker slot", function()
		local http, client = use_http()
		local url, other = "https://catalog.example/cover", "https://cdn.example/cover"
		local header = { name = "Authorization", value = "Bearer first" }
		client.setCatalogs({ { url = other, headers = { header } } })
		cached[client.cacheKey(url)] = { content = "old-private", stale = true }
		http:on(url, { code = 302, headers = { Location = other } })
		http:on(other, { code = 403 })
		http:on(function() return true end, { code = 200, body = "busy" })
		local _, halt_busy = ImageLoader:loadImages({
			"https://catalog.example/busy1", "https://catalog.example/busy2",
		}, nil, nil, nil, false)
		step()
		step()
		local delivered = {}
		local pending = ImageLoader:loadImages({ url }, function(_url, content)
			delivered[#delivered + 1] = content
		end)
		step()
		step()
		assert.equals(2, next_pid)
		header.value = "Bearer second"
		complete(1)
		for _ = 1, 20 do
			if children[3] then break end
			step()
		end
		assert.is_not_nil(children[3])
		complete(3)
		finish(pending)
		halt_busy()
		assert.same({}, delivered, "a failed request must not fall back to another authentication context")
	end)

	it("shares one delivery slot between completed children and cache hits", function()
		cached.C = { content = "cached C" }
		local deliveries = {}
		local batch = ImageLoader:loadImages({ "A", "B", "C" }, function(url)
			deliveries[#deliveries + 1] = url
		end)
		step()
		step()
		complete(1)
		complete(2)
		step()
		assert.equals(1, #deliveries)
		assert.equals(1, #writes)
		for _ = 1, 100 do
			if not batch.loading then break end
			local before = #deliveries
			step()
			assert.is_true(#deliveries - before <= 1)
		end
		assert.is_false(batch.loading)
		assert.equals(3, #deliveries)
		assert.equals(2, #writes)
		assert.equals(2, #requests)
	end)

	it("reaps while input postpones delivery without killing or refetching", function()
		local deliveries = 0
		local batch = ImageLoader:loadImages({ "A", "B", "C" }, function() deliveries = deliveries + 1 end)
		step()
		step()
		batch:defer(1)
		complete(1)
		complete(2)
		step()
		assert.is_true(children[1].reaped)
		assert.is_true(children[2].reaped)
		assert.equals(0, deliveries)
		assert.same({}, writes)
		assert.same({}, kills)
		assert.is_true(helper.fs.exists(paths[1]))
		assert.equals(2, next_pid)
		for _ = 1, 100 do
			if children[3] then break end
			step()
		end
		assert.equals(2, deliveries)
		assert.equals(3, next_pid)
		complete(3)
		finish(batch)
		assert.equals(3, deliveries)
		assert.equals(3, #requests)
		assert.equals(3, next_pid)
		assert.same({}, kills)
	end)

	it("cancels paused completed jobs without signalling an already reaped PID", function()
		local calls = 0
		local batch, halt = ImageLoader:loadImages({ "A" }, function() calls = calls + 1 end)
		step()
		batch:defer(1)
		complete(1)
		step()
		halt()
		halt()
		assert.is_false(batch.loading)
		assert.equals(0, calls)
		assert.same({}, ui.scheduled)
		assert.same({}, kills)
		assert.is_false(helper.fs.exists(paths[1]))
	end)

	it("cancels render continuations at every stage of the repaint delay", function()
		cached.A = { content = "cached A" }
		for stages = 1, 3 do
			local calls = 0
			local batch, halt = ImageLoader:loadImages({ "A" }, function()
				calls = calls + 1
				return function() calls = calls + 1 end
			end)
			for _ = 1, stages do step() end
			halt()
			assert.is_false(batch.loading)
			assert.equals(1, calls)
			assert.same({}, ui.scheduled)
		end
	end)

	it("keeps serial fetches spaced apart when parallel downloading is disabled", function()
		local stamps = {}
		local batch = ImageLoader:loadImages({ "A", "B" }, function()
			stamps[#stamps + 1] = clock
		end, nil, nil, false, nil, nil, false)
		finish(batch)
		assert.equals(0, next_pid)
		assert.equals(2, #requests)
		assert.equals(2, #stamps)
		assert.is_true(stamps[2] - stamps[1] >= 0.2)
	end)

	it("shares worker slots across batches and releases them on reap and cancellation", function()
		local first, halt_first = ImageLoader:loadImages({ "A", "B" }, function() end)
		local second, halt_second = ImageLoader:loadImages({ "C", "D" }, function() end)
		for _ = 1, 4 do step() end
		assert.equals(2, next_pid)
		assert.equals(0, #requests, "slot contention must not fall back to blocking HTTP")
		complete(1)
		for _ = 1, 20 do
			if next_pid == 3 then break end
			step()
		end
		assert.equals(3, next_pid)
		halt_first()
		halt_second()
		assert.is_false(first.loading)
		assert.is_false(second.loading)
		assert.same({}, ui.scheduled)
		local fresh, halt_fresh = ImageLoader:loadImages({ "E", "F" }, function() end)
		step()
		step()
		assert.equals(5, next_pid)
		halt_fresh()
		assert.is_false(fresh.loading)
	end)

	it("prefetches only missing bytes without a render callback", function()
		cached.A = { content = "cached A" }
		local batch = ImageLoader:prefetch({ "A", "B" })
		for _ = 1, 20 do
			if children[1] then break end
			step()
		end
		assert.equals(1, next_pid)
		assert.is_nil(batch.callback)
		complete(1)
		finish(batch)
		assert.same({ "B" }, requests)
		assert.same({ { "B", "downloaded B" } }, writes)
	end)

	it("never falls back to synchronous HTTP for speculative covers", function()
		can_fork = false
		local batch = ImageLoader:prefetch({ "A", "B" })
		finish(batch)
		assert.equals(0, next_pid)
		assert.same({}, requests)
		assert.same({}, writes)
		assert.equals(1, #errors)
		assert.is_false(helper.fs.exists(paths[1]))
	end)

	it("cancels speculative children when their owner no longer allows warming", function()
		local current = true
		local batch = ImageLoader:prefetch({ "A", "B" }, nil, nil, nil, nil, function() return current end)
		step()
		current = false
		step()
		assert.is_false(batch.loading)
		assert.is_true(batch.cancelled)
		assert.same({ 1 }, kills)
		assert.same({}, ui.scheduled)
		assert.is_false(helper.fs.exists(paths[1]))
	end)

	it("reports a cache-write failure during prefetch", function()
		cache_ok = false
		local batch = ImageLoader:prefetch({ "A" })
		step()
		complete(1)
		finish(batch)
		assert.equals(1, #errors)
		assert.matches("Failed to cache cover", errors[1][2], 1, true)
	end)

	it("renders duplicate URLs one at a time and rejects stale continuations", function()
		local rendered, updated, current = 0, 0, true
		local CoverLoader = helper.load("services.cover_loader", {
			["ui/renderimage"] = {
				renderImageData = function()
					rendered = rendered + 1
					return { stride = 100, h = 150, free = function() end }
				end,
			},
		})
		local items = {}
		for index = 1, 3 do
			items[index] = {
				entry = { lazy_load_cover = true },
				widget = { update = function() updated = updated + 1 end },
			}
		end
		local callback = CoverLoader.createRenderCallback({ A = items }, 100, 150,
			function() return current end, CoverLoader.getMemory({}))
		local more = callback("A", "bytes")
		assert.equals(1, rendered)
		assert.equals(1, updated)
		assert.is_function(more)
		current = false
		assert.is_nil(more())
		assert.equals(1, rendered)
		assert.equals(1, updated)
		assert.is_true(items[2].entry.lazy_load_cover)
	end)

	it("frees a newly decoded bitmap if its owner changes during rendering", function()
		local current, freed, updated = true, 0, 0
		local CoverLoader = helper.load("services.cover_loader", {
			["ui/renderimage"] = {
				renderImageData = function()
					current = false
					return { free = function() freed = freed + 1 end }
				end,
			},
		})
		local entry = { lazy_load_cover = true }
		local callback = CoverLoader.createRenderCallback({
			A = { { entry = entry, widget = { update = function() updated = updated + 1 end } } },
		}, 100, 150, function() return current end, CoverLoader.getMemory({}))
		callback("A", "bytes")
		assert.equals(1, freed)
		assert.equals(0, updated)
		assert.is_nil(entry.cover_bb)
		assert.is_true(entry.lazy_load_cover)
	end)
end)
