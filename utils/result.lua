-- Result Module for Consistent Error Handling
-- Provides a standardized pattern for operations that can fail
-- Based on the Result/Either pattern common in functional programming

local Result = {}
Result.__index = Result

--- Create a successful result
-- @param value any The success value
-- @return table Result object with success=true
function Result.ok(value)
	return setmetatable({
		success = true,
		value = value,
		error = nil,
	}, Result)
end

--- Create a failed result
-- @param message string Error message describing the failure
-- @param code number|nil Optional error code (e.g., HTTP status)
-- @return table Result object with success=false
function Result.err(message, code)
	return setmetatable({
		success = false,
		value = nil,
		error = message,
		code = code,
	}, Result)
end

--- Check if result is successful
-- @return boolean True if operation succeeded
function Result:isOk()
	return self.success == true
end

--- Check if result is an error
-- @return boolean True if operation failed
function Result:isErr()
	return self.success == false
end

--- Get the value, or default if error
-- @param default any Value to return if result is an error
-- @return any The success value or the default
function Result:unwrapOr(default)
	if self.success then
		return self.value
	end
	return default
end

--- Get the value, or call function to get default if error
-- @param fn function Function to call if result is an error
-- @return any The success value or result of fn()
function Result:unwrapOrElse(fn)
	if self.success then
		return self.value
	end
	return fn(self.error, self.code)
end

--- Transform the success value
-- @param fn function Function to apply to success value
-- @return table New Result with transformed value (or same error)
function Result:map(fn)
	if self.success then
		return Result.ok(fn(self.value))
	end
	return self
end

--- Transform the error message
-- @param fn function Function to apply to error message
-- @return table New Result with transformed error (or same value)
function Result:mapErr(fn)
	if not self.success then
		return Result.err(fn(self.error, self.code), self.code)
	end
	return self
end

--- Chain results - transform value into new Result
-- @param fn function Function that returns a Result
-- @return table The returned Result (or same error)
function Result:andThen(fn)
	if self.success then
		return fn(self.value)
	end
	return self
end

--- Handle both success and error cases
-- @param on_ok function Called with value if success
-- @param on_err function Called with error and code if failure
-- @return any Result of the called function
function Result:match(on_ok, on_err)
	if self.success then
		return on_ok(self.value)
	end
	return on_err(self.error, self.code)
end

--- Convert to the legacy (bool, value_or_error) pattern
-- For gradual migration - allows Result to work with existing code
-- @return boolean, any Success flag and value/error
function Result:unpack()
	if self.success then
		return true, self.value
	end
	return false, self.error
end

--- Wrap a function that returns (success, value_or_error) pattern
-- This allows gradual migration of existing functions
-- @param fn function Function returning (boolean, any)
-- @return function Wrapped function returning Result
function Result.wrap(fn)
	return function(...)
		local success, value_or_error = fn(...)
		if success then
			return Result.ok(value_or_error)
		end
		return Result.err(value_or_error)
	end
end

--- Wrap a function that uses pcall internally
-- Converts pcall style (ok, result_or_error) to Result
-- @param fn function Function to wrap with pcall
-- @return function Wrapped function returning Result
function Result.wrapPcall(fn)
	return function(...)
		local ok, result_or_error = pcall(fn, ...)
		if ok then
			return Result.ok(result_or_error)
		end
		return Result.err(tostring(result_or_error))
	end
end

--- Wrap a function that returns nil on error
-- @param fn function Function returning value or nil
-- @param error_msg string Error message to use when nil is returned
-- @return function Wrapped function returning Result
function Result.wrapNilable(fn, error_msg)
	error_msg = error_msg or "Operation failed"
	return function(...)
		local value = fn(...)
		if value ~= nil then
			return Result.ok(value)
		end
		return Result.err(error_msg)
	end
end

--- Create Result from (success, value_or_error) tuple
-- Useful for converting existing function returns
-- @param success boolean Success flag
-- @param value_or_error any Value if success, error message if failure
-- @return table Result object
function Result.from(success, value_or_error)
	if success then
		return Result.ok(value_or_error)
	end
	return Result.err(value_or_error)
end

--- Combine multiple Results - all must succeed
-- Returns first error encountered, or Result.ok with list of values
-- @param results table Array of Result objects
-- @return table Result containing array of values or first error
function Result.all(results)
	local values = {}
	for i, result in ipairs(results) do
		if not result.success then
			return result
		end
		values[i] = result.value
	end
	return Result.ok(values)
end

--- Try first Result, fall back to second if error
-- @param result1 table First Result to try
-- @param result2 table|function Fallback Result or function returning Result
-- @return table First successful Result, or last error
function Result.orElse(result1, result2)
	if result1.success then
		return result1
	end
	if type(result2) == "function" then
		return result2()
	end
	return result2
end

return Result
