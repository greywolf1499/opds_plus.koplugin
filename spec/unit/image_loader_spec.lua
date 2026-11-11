local helper = require("helper")
local ui_stub = require("support.ui")

describe("ImageLoader scheduling", function()
	local ImageLoader, ui, clock, directory
	local children, paths, cached, writes, requests, kills, next_pid

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
		children, paths, cached, writes, requests, kills = {}, {}, {}, {}, {}, {}
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
				getUrlContent = function(url)
					requests[#requests + 1] = url
					return true, "downloaded " .. url
				end,
			},
			["services.cover_cache"] = {
				get = function(url) return cached[url] end,
				put = function(url, content) writes[#writes + 1] = { url, content } end,
			},
		})
	end)

	after_each(helper.reset)

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

	it("renders duplicate URLs one at a time and rejects stale continuations", function()
		local rendered, updated, current = 0, 0, true
		local CoverLoader = helper.load("services.cover_loader", {
			["ui/renderimage"] = {
				renderImageData = function()
					rendered = rendered + 1
					return { free = function() end }
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
		local callback = CoverLoader.createRenderCallback({ A = items }, 100, 150, function() return current end)
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
		}, 100, 150, function() return current end)
		callback("A", "bytes")
		assert.equals(1, freed)
		assert.equals(0, updated)
		assert.is_nil(entry.cover_bb)
		assert.is_true(entry.lazy_load_cover)
	end)
end)
