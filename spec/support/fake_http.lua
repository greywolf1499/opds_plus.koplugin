-- Scriptable stand-in for LuaSocket's socket.http, for specs.
--
--   local http = fake_http.new()
--   http:on("https://example.org/feed.xml", { code = 200, body = "<feed/>", headers = { etag = '"1"' } })
--   http:on(function(url) return url:find("/cover/", 1, true) end, { code = 404 })
--   http:on(url, function(request) return { code = 304 } end)   -- decide per request
--   http:on(url, { error = "timeout" })                         -- the transport itself fails
--   helper.stub("socket.http", http)
--
-- Routes are tried in the order they were added. Every request is recorded in http.requests
-- (url, method, headers, user, password, body); requests no route matches are recorded in
-- http.unmatched and fail like an unreachable host.
--
-- Mimics the shapes LuaSocket returns: with a request table, `1, code, headers, status` (header
-- names lower-cased) or `nil, err`; with a URL string, `body, code, headers, status`. The sink gets
-- the body and then nil, except for responses that have no body (1xx, 204, 304, HEAD). Redirects are
-- not followed: tests script a 301/302 response and assert on what the code under test does with it.
local M = {}

local function shallow_copy(tbl)
	local copy = {}
	for key, value in pairs(tbl or {}) do
		copy[key] = value
	end
	return copy
end

local function matches(route, request)
	if type(route.match) == "string" then
		return route.match == request.url
	end
	return route.match(request.url, request) and true or false
end

local function has_body(code, method)
	return not (method == "HEAD" or code == 204 or code == 304 or (code >= 100 and code < 200))
end

function M.new()
	local fake = { requests = {}, routes = {}, unmatched = {} }

	--- Adds a route.
	-- @param match string|function Exact URL, or function(url, request) returning true for a match
	-- @param response table|function { code, body, headers, status } or { error }; a function gets the
	--   request and returns one of those
	function fake:on(match, response)
		self.routes[#self.routes + 1] = { match = match, response = response }
		return self
	end

	--- Requests made so far to `url` (all requests when nil).
	function fake:requests_to(url)
		local found = {}
		for _, request in ipairs(self.requests) do
			if url == nil or request.url == url then
				found[#found + 1] = request
			end
		end
		return found
	end

	function fake.request(reqt, body)
		local string_form = type(reqt) == "string"
		local request
		if string_form then
			request = { url = reqt, method = body and "POST" or "GET", body = body }
		else
			request = {
				url = reqt.url,
				method = reqt.method or "GET",
				headers = shallow_copy(reqt.headers),
				user = reqt.user,
				password = reqt.password,
			}
			if reqt.source then
				local chunks = {}
				while true do
					local chunk = reqt.source()
					if not chunk then
						break
					end
					chunks[#chunks + 1] = chunk
				end
				request.body = table.concat(chunks)
			end
		end
		request.headers = request.headers or {}
		fake.requests[#fake.requests + 1] = request

		local response
		for _, route in ipairs(fake.routes) do
			if matches(route, request) then
				response = route.response
				break
			end
		end
		if response == nil then
			fake.unmatched[#fake.unmatched + 1] = request.url
			return nil, "connection refused"
		end
		if type(response) == "function" then
			response = response(request)
		end
		if response == nil or response.error then
			return nil, response and response.error or "connection refused"
		end

		local code = response.code or 200
		local headers = {}
		for name, value in pairs(response.headers or {}) do
			headers[name:lower()] = value
		end
		local status = response.status or ("HTTP/1.1 " .. code)
		local payload = response.body or ""

		local sink = not string_form and reqt.sink or nil
		if sink and has_body(code, request.method) then
			-- A sink that refuses a chunk (for example on a timeout) aborts the request, as in LuaSocket
			if payload ~= "" then
				local ok, err = sink(payload)
				if not ok then
					return nil, err
				end
			end
			sink(nil)
		end

		if string_form then
			return has_body(code, request.method) and payload or "", code, headers, status
		end
		return 1, code, headers, status
	end

	return fake
end

return M
