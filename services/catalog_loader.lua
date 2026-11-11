local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TrapWidget = require("ui/widget/trapwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local FeedFetcher = require("core.feed_fetcher")
local NavigationHandler = require("core.navigation_handler")
local Debug = require("utils.debug")
local Result = require("utils.result")

local CatalogLoader = {}

function CatalogLoader.prepare(url, context)
	local state = FeedFetcher.newRequestState(context.basic_auth_origin or false)
	context.fetch_state = state
	local result = Result.wrapPcall(function()
		local items, facets, search = FeedFetcher.genItemTableFromURL(url, context.username, context.password,
			nil, function(catalog, address)
				return NavigationHandler.genItemTableFromCatalog(catalog, address, context)
			end, state)
		return { items = items, facets = facets, search = search, state = state }
	end)()
	if result:isErr() then
		return { error = result.error, state = state }
	end
	return result.value
end

function CatalogLoader.start(url, context, callback)
	local job = { running = true, cancelled = false }
	local widget = TrapWidget:new { text = _("Loading catalog... (tap or press a key to cancel)") }
	job.widget = widget

	local function deliver(packet)
		if job.cancelled then return end
		if type(packet) ~= "table" then
			Debug.error("CatalogLoader:", "Catalog subprocess returned no result")
			UIManager:show(InfoMessage:new { text = _("Catalog loading failed. Please try again.") })
			callback(nil)
			return
		end
		FeedFetcher.applyRequestState(packet.state)
		if packet.error then
			Debug.error("CatalogLoader:", packet.error)
			UIManager:show(InfoMessage:new { text = _("Catalog loading failed. Please try again.") })
			callback(nil)
		else
			callback(packet)
		end
	end

	function job:cancel()
		if self.cancelled then return true end
		self.cancelled = true
		if self.running then widget.dismiss_callback() end
		if self.fallback then UIManager:close(self.fallback) end
		return true
	end

	local function dismiss() return job:cancel() end
	widget.onAnyKeyPressed = dismiss
	widget.onTapDismiss = dismiss
	widget.onHoldDismiss = dismiss
	widget.onSwipeDismiss = dismiss
	widget.onPanReleaseDismiss = dismiss
	function widget:onCloseWidget()
		if job.running then job:cancel() end
		return TrapWidget.onCloseWidget(self)
	end

	Trapper:wrap(function()
		UIManager:show(widget)
		UIManager:forceRePaint()
		local completed, packet = Trapper:dismissableRunInSubprocess(function()
			return CatalogLoader.prepare(url, context)
		end, widget)
		job.running = false
		UIManager:close(widget)
		if job.cancelled then
			callback(nil, true)
		elseif completed then
			deliver(packet)
		else
			Debug.error("CatalogLoader:", "Could not start catalog subprocess")
			job.fallback = ConfirmBox:new {
				text = _("Background catalog loading is unavailable. Load in the foreground instead? Input will pause until loading finishes."),
				ok_text = _("Load"),
				ok_callback = function()
					if not job.cancelled then deliver(CatalogLoader.prepare(url, context)) end
				end,
				cancel_callback = function()
					job:cancel()
					callback(nil, true)
				end,
			}
			UIManager:show(job.fallback)
		end
	end)
	return job
end

return CatalogLoader
