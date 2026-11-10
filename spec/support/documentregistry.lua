-- Stand-in for document/documentregistry: a provider exists for the listed extensions and mimetypes.
--
--   helper.stub("document/documentregistry", require("support.documentregistry").new())
--   registry:add_mimetype("application/x-cbz")
--   registry.open_document = function(file) return fake_document end   -- what openDocument(file) gives
local M = {}

local DEFAULT_EXTENSIONS = { "epub", "pdf", "mobi", "azw3", "fb2", "djvu", "cbz", "txt", "html" }
local DEFAULT_MIMETYPES = {
	"application/epub+zip",
	"application/pdf",
	"application/x-mobipocket-ebook",
	"application/vnd.amazon.ebook",
	"image/vnd.djvu",
	"application/x-cbz",
	"application/vnd.comicbook+zip",
	"text/plain",
}
local MIMETYPE_EXTENSIONS = {
	["application/epub+zip"] = "epub",
	["application/pdf"] = "pdf",
	["application/x-mobipocket-ebook"] = "mobi",
	["application/vnd.amazon.ebook"] = "azw",
	["image/vnd.djvu"] = "djvu",
	["application/x-cbz"] = "cbz",
	["application/vnd.comicbook+zip"] = "cbz",
	["text/plain"] = "txt",
}

local function set(list)
	local result = {}
	for _, value in ipairs(list) do
		result[value] = true
	end
	return result
end

function M.new(opts)
	opts = opts or {}
	local registry = {
		extensions = set(opts.extensions or DEFAULT_EXTENSIONS),
		mimetypes = set(opts.mimetypes or DEFAULT_MIMETYPES),
		calls = {},
	}

	function registry:add_extension(extension)
		self.extensions[extension] = true
	end

	function registry:add_mimetype(mimetype)
		self.mimetypes[mimetype] = true
	end

	-- Same contract as the real one: called as DocumentRegistry:hasProvider(file, mimetype).
	function registry:hasProvider(file, mimetype)
		self.calls[#self.calls + 1] = { file = file, mimetype = mimetype }
		if mimetype and self.mimetypes[mimetype] then
			return true
		end
		local extension
		if type(file) == "string" then
			extension = file:match("%.([^./]+)$")
		end
		return extension ~= nil and self.extensions[extension:lower()] == true
	end

	function registry:mimeToExt(mimetype)
		return MIMETYPE_EXTENSIONS[mimetype]
	end

	-- A test sets registry.open_document to decide what opening a book gives.
	function registry:openDocument(file)
		if self.open_document then
			return self.open_document(file)
		end
	end

	return registry
end

return M
