---@meta ssl.x509

---@class LuaSecCertificate
---@field extensions fun(self: LuaSecCertificate): table<string, table>

local x509 = {}

---@param pem string
---@return LuaSecCertificate?
---@return string?
function x509.load(pem) end

return x509
