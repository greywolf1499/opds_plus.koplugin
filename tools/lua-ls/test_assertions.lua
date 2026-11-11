---@meta

-- Supplement the bundled Luassert metadata, not the production Lua assert API.
-- Luassert accepts optional failure messages and exposes both singular and plural aliases.
---@class luassert.internal
---@field equals fun(expected: any, ...: any)
---@field errors fun(callback: function, message?: any)
---@field is_true fun(value: any, message?: any)
---@field is_false fun(value: any, message?: any)
---@field is_nil fun(value: any, message?: any)
---@field is_not_nil fun(value: any, message?: any)
---@field is_truthy fun(value: any, message?: any)
---@field is_falsy fun(value: any, message?: any)
---@field truthy fun(value: any, message?: any)
---@field is_string fun(value: any, message?: any)
---@field is_table fun(value: any, message?: any)
---@field is_function fun(value: any, message?: any)
---@field matches fun(pattern: string, actual: any, init?: integer, plain?: boolean, message?: any)
---@field not_equal fun(expected: any, ...: any)
local internal = {}

---@class luassert
---@overload fun<T>(value: T?, message?: any, ...: any): T, ...: any
local assertions = {}

-- A pending test does not require a callback.
-- luacheck: globals pending
---@param name string
---@param block? fun()
function pending(name, block) end

return internal, assertions
