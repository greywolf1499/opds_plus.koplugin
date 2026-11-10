local helper = require("helper")

describe("TlsHostname", function()
	local TlsHostname

	before_each(function()
		helper.reset()
		TlsHostname = require("services.tls_hostname")
	end)

	describe("matches", function()
		it("matches exact names, ignoring case and a trailing dot", function()
			assert.is_true(TlsHostname.matches("api.github.com", "api.github.com"))
			assert.is_true(TlsHostname.matches("API.GitHub.com", "api.github.com"))
			assert.is_true(TlsHostname.matches("api.github.com.", "api.github.com"))
			assert.is_false(TlsHostname.matches("github.com", "api.github.com"))
		end)

		it("lets a wildcard stand for exactly one leftmost label", function()
			assert.is_true(TlsHostname.matches("*.githubusercontent.com", "objects.githubusercontent.com"))
			assert.is_false(TlsHostname.matches("*.githubusercontent.com", "githubusercontent.com"))
			assert.is_false(TlsHostname.matches("*.githubusercontent.com", "a.b.githubusercontent.com"))
			assert.is_false(TlsHostname.matches("*.githubusercontent.com", "x.githubusercontent.com.evil.com"))
		end)

		it("refuses wildcards it can't match safely", function()
			assert.is_false(TlsHostname.matches("*", "localhost"))
			assert.is_false(TlsHostname.matches("*.com", "github.com"))
			assert.is_false(TlsHostname.matches("f*.github.com", "foo.github.com"))
			assert.is_false(TlsHostname.matches("*.*.github.com", "a.b.github.com"))
			assert.is_false(TlsHostname.matches("", "github.com"))
			assert.is_false(TlsHostname.matches(nil, "github.com"))
		end)
	end)

	describe("certificateMatches", function()
		local function cert(names)
			return {
				extensions = function()
					return { [TlsHostname.SAN_OID] = { dNSName = names } }
				end,
			}
		end

		it("accepts a certificate with a name for the host", function()
			assert.is_true(TlsHostname.certificateMatches(cert({ "github.com", "www.github.com" }), "www.github.com"))
		end)

		it("refuses a certificate for another host, or with no DNS names", function()
			assert.is_false(TlsHostname.certificateMatches(cert({ "badssl.com" }), "github.com"))
			assert.is_false(TlsHostname.certificateMatches(cert({}), "github.com"))
			assert.is_false(TlsHostname.certificateMatches({ extensions = function()
				return {}
			end }, "github.com"))
			assert.is_false(TlsHostname.certificateMatches({ extensions = function()
				error("broken")
			end }, "github.com"))
			assert.is_false(TlsHostname.certificateMatches(nil, "github.com"))
		end)
	end)

	describe("create", function()
		local wrapped_with, closed

		-- LuaSocket and LuaSec stand-ins: the server presents a certificate for `names`
		local function deps(names, handshake_error)
			closed = 0
			local tls_methods = {
				sni = function() end,
				settimeout = function() end,
				dohandshake = function()
					if handshake_error then
						return nil, handshake_error
					end
					return true
				end,
				getpeercertificate = function()
					return {
						extensions = function()
							return { [TlsHostname.SAN_OID] = { dNSName = names } }
						end,
					}
				end,
				receive = function()
					return "data"
				end,
				close = function()
					closed = closed + 1
				end,
			}
			local tcp = {
				connect = function()
					return 1
				end,
				settimeout = function() end,
				close = function()
					closed = closed + 1
				end,
			}
			return {
				socket = {
					tcp = function()
						return tcp
					end,
				},
				ssl = {
					wrap = function(_, settings)
						wrapped_with = settings
						return setmetatable({}, { __index = tls_methods })
					end,
				},
			}
		end

		it("connects when the certificate covers the host, with chain verification on", function()
			local create = TlsHostname.create({ verify = "peer", cafile = "/ca.crt" }, deps({ "api.github.com" }))
			local conn = create()
			assert.equal(1, conn:connect("api.github.com", 443))
			assert.equal("peer", wrapped_with.verify)
			assert.equal("/ca.crt", wrapped_with.cafile)
			assert.equal("client", wrapped_with.mode)
			assert.equal("data", conn:receive())
		end)

		it("refuses a certificate for another host and closes the connection", function()
			local conn = TlsHostname.create({ verify = "peer" }, deps({ "evil.example.com" }))()
			local ok, err = conn:connect("api.github.com", 443)
			assert.is_nil(ok)
			assert.matches("certificate verify failed", err)
			assert.equal(1, closed)
		end)

		it("passes a failed handshake on", function()
			local conn = TlsHostname.create({}, deps({ "api.github.com" }, "certificate verify failed"))()
			local ok, err = conn:connect("api.github.com", 443)
			assert.is_nil(ok)
			assert.equal("certificate verify failed", err)
		end)
	end)
end)
