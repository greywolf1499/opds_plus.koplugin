-- Stand-in for KOReader's frontend/socketutil.lua (v2026.07.1), for specs.
--
-- Constants, sink functions and header redaction are the real module's, minus its coupling to
-- socket.http/ssl.https timeouts. Each new() call gives fresh timeout state.
-- spec/contract checks the constants against a real KOReader install.
local ltn12 = require("ltn12")

local M = {}

--- @param opts table|nil { time = function } clock the sinks measure the total timeout with (default os.time)
function M.new(opts)
	local time = opts and opts.time or os.time
	local socketutil = {
		LARGE_BLOCK_TIMEOUT = 10,
		LARGE_TOTAL_TIMEOUT = 30,
		FILE_BLOCK_TIMEOUT = 15,
		FILE_TOTAL_TIMEOUT = 60,
		DEFAULT_BLOCK_TIMEOUT = 60,
		DEFAULT_TOTAL_TIMEOUT = -1,
		TIMEOUT_CODE = "timeout",
		SSL_HANDSHAKE_CODE = "wantread",
		SINK_TIMEOUT_CODE = "sink timeout",
	}
	socketutil.block_timeout = socketutil.DEFAULT_BLOCK_TIMEOUT
	socketutil.total_timeout = socketutil.DEFAULT_TOTAL_TIMEOUT

	function socketutil:set_timeout(block_timeout, total_timeout)
		self.block_timeout = block_timeout or 5
		self.total_timeout = total_timeout or 15
	end

	function socketutil:reset_timeout()
		self.block_timeout = self.DEFAULT_BLOCK_TIMEOUT
		self.total_timeout = self.DEFAULT_TOTAL_TIMEOUT
	end

	function socketutil.table_sink(t)
		if socketutil.total_timeout < 0 then
			return ltn12.sink.table(t)
		end

		local start_ts = time()
		t = t or {}
		local f = function(chunk)
			if chunk then
				if time() - start_ts > socketutil.total_timeout then
					return nil, socketutil.SINK_TIMEOUT_CODE
				end
				table.insert(t, chunk)
			end
			return 1
		end
		return f, t
	end

	function socketutil.file_sink(handle, io_err)
		if socketutil.total_timeout < 0 then
			return ltn12.sink.file(handle, io_err)
		end

		if handle then
			local start_ts = time()
			return function(chunk)
				if not chunk then
					handle:close()
					return 1
				else
					if time() - start_ts > socketutil.total_timeout then
						handle:close()
						return nil, socketutil.SINK_TIMEOUT_CODE
					end
					return handle:write(chunk)
				end
			end
		else
			return nil, io_err or "unable to open file"
		end
	end

	function socketutil.redact_headers(headers)
		local sensitive_headers = {
			["authorization"] = true,
			["cookie"] = true,
			["proxy-authorization"] = true,
			["set-cookie"] = true,
		}
		local safe_headers = {}
		for key, value in pairs(headers) do
			if sensitive_headers[key] then
				safe_headers[key] = "REDACTED"
			else
				safe_headers[key] = value
			end
		end
		return safe_headers
	end

	function socketutil.redact_request(request)
		local sensitive_props = {
			["password"] = true,
			["user"] = true,
		}
		local safe_request = {}
		for key, value in pairs(request) do
			if sensitive_props[key] then
				safe_request[key] = "REDACTED"
			elseif key == "headers" then
				safe_request[key] = socketutil.redact_headers(value)
			else
				safe_request[key] = value
			end
		end
		return safe_request
	end

	return socketutil
end

return M
