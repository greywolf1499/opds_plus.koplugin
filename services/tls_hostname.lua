-- Checks that the certificate a TLS server presents was issued for the host we meant to reach.
-- LuaSec verifies the chain against the CA bundle (verify = "peer") but never compares the names in the
-- certificate with the host, so any valid certificate would do. TlsHostname.create() is a drop-in
-- `create` for socket.http requests that does the handshake like ssl.https and then checks the
-- certificate's subjectAltName DNS names (RFC 6125: exact match, or a wildcard for one leftmost label).

local TlsHostname = {}

TlsHostname.SAN_OID = "2.5.29.17"
TlsHostname.DEFAULT_OPTIONS = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" }
TlsHostname.TIMEOUT = 60

function TlsHostname.options(ca_file)
	local options = { verify = "peer", cafile = ca_file }
	options.create = TlsHostname.create(options)
	return options
end

--- Whether a name from a certificate covers a host
-- @param pattern string A dNSName from the certificate, such as "*.example.org"
-- @param host string The host connected to
function TlsHostname.matches(pattern, host)
	if type(pattern) ~= "string" or type(host) ~= "string" or pattern == "" or host == "" then
		return false
	end
	pattern = pattern:lower():gsub("%.$", "")
	host = host:lower():gsub("%.$", "")
	if pattern == host then
		return true
	end
	-- Only "*." followed by at least two labels; never a partial label such as "f*.example.org"
	local suffix = pattern:match("^%*%.(.+)$")
	if not suffix or suffix:find("*", 1, true) or not suffix:find(".", 1, true) then
		return false
	end
	local label, rest = host:match("^([^.]+)%.(.+)$")
	return label ~= nil and rest == suffix
end

--- Whether a certificate is valid for a host, judged by its subjectAltName DNS names only
-- @param cert userdata|table A LuaSec certificate (anything with :extensions())
-- @param host string
-- @return boolean
-- @return string|nil Why not
function TlsHostname.certificateMatches(cert, host)
	if not cert or not cert.extensions then
		return false, "no certificate"
	end
	local ok, extensions = pcall(cert.extensions, cert)
	local san = ok and type(extensions) == "table" and extensions[TlsHostname.SAN_OID] or nil
	local names = type(san) == "table" and san.dNSName or nil
	if type(names) ~= "table" or #names == 0 then
		return false, "certificate has no DNS names"
	end
	for _, name in ipairs(names) do
		if TlsHostname.matches(name, host) then
			return true
		end
	end
	return false, "certificate is not valid for " .. tostring(host)
end

--- A socket.http `create` function that checks the server's certificate covers the host
-- @param params table LuaSec settings: verify, cafile, and optionally protocol and options
-- @param deps table|nil { socket = LuaSocket, ssl = LuaSec } for specs
function TlsHostname.create(params, deps)
	deps = deps or {}
	local settings = {
		mode = "client",
		protocol = params.protocol or "any",
		options = params.options or TlsHostname.DEFAULT_OPTIONS,
		verify = params.verify or "peer",
		cafile = params.cafile,
		capath = params.capath,
	}
	return function()
		local socket = deps.socket or require("socket")
		local ssl = deps.ssl or require("ssl")
		local tcp, tcp_err = socket.tcp()
		if not tcp then
			return nil, tcp_err
		end
		local conn = { sock = tcp }
		function conn:settimeout()
			return self.sock:settimeout(TlsHostname.TIMEOUT)
		end
		function conn:connect(host, port)
			local connected, connect_err = self.sock:connect(host, port)
			if not connected then
				return nil, connect_err
			end
			local wrapped, wrap_err = ssl.wrap(self.sock, settings)
			if not wrapped then
				self.sock:close()
				return nil, wrap_err
			end
			self.sock = wrapped
			wrapped:sni(host)
			wrapped:settimeout(TlsHostname.TIMEOUT)
			local shaken, shake_err = wrapped:dohandshake()
			if not shaken then
				wrapped:close()
				return nil, shake_err
			end
			local valid, why = TlsHostname.certificateMatches(wrapped:getpeercertificate(), host)
			if not valid then
				wrapped:close()
				return nil, "certificate verify failed: " .. why
			end
			-- Forward everything else to the TLS connection, as ssl.https does
			for name, method in pairs(getmetatable(wrapped).__index) do
				if type(method) == "function" and name ~= "connect" and name ~= "settimeout" then
					self[name] = function(me, ...)
						return method(me.sock, ...)
					end
				end
			end
			return 1
		end
		function conn:close()
			return self.sock:close()
		end
		return conn
	end
end

return TlsHostname
