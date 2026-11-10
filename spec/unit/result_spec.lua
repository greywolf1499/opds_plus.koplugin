local helper = require("helper")

describe("Result", function()
	local Result

	before_each(function()
		helper.reset()
		Result = helper.load("utils.result")
	end)

	after_each(helper.reset)

	describe("ok", function()
		it("holds the value of a successful result", function()
			local result = Result.ok({ 1, 2 })
			assert.is_true(result.success)
			assert.same({ 1, 2 }, result.value)
			assert.is_nil(result.error)
			assert.is_true(result:isOk())
			assert.is_false(result:isErr())
		end)

		it("can hold false as its value", function()
			local result = Result.ok(false)
			assert.is_true(result:isOk())
			assert.is_false(result.value)
		end)
	end)

	describe("err", function()
		it("holds the message and the code of a failed result", function()
			local result = Result.err("Not found", 404)
			assert.is_false(result.success)
			assert.equals("Not found", result.error)
			assert.equals(404, result.code)
			assert.is_nil(result.value)
			assert.is_true(result:isErr())
			assert.is_false(result:isOk())
		end)

		it("does not need a code", function()
			local result = Result.err("boom")
			assert.equals("boom", result.error)
			assert.is_nil(result.code)
		end)
	end)

	describe("unwrapOr", function()
		it("returns the value of a successful result", function()
			assert.equals(5, Result.ok(5):unwrapOr(0))
		end)

		it("returns a false value as it is instead of the default", function()
			assert.is_false(Result.ok(false):unwrapOr(true))
		end)

		it("returns the default for a failed result", function()
			assert.equals(0, Result.err("boom"):unwrapOr(0))
		end)
	end)

	describe("unwrapOrElse", function()
		it("returns the value without calling the function when successful", function()
			local called = false
			local value = Result.ok(5):unwrapOrElse(function()
				called = true
				return 0
			end)
			assert.equals(5, value)
			assert.is_false(called)
		end)

		it("calls the function with the message and the code when failed", function()
			local seen
			local value = Result.err("Not found", 404):unwrapOrElse(function(message, code)
				seen = { message, code }
				return "fallback"
			end)
			assert.equals("fallback", value)
			assert.same({ "Not found", 404 }, seen)
		end)
	end)

	describe("map", function()
		it("transforms the value of a successful result", function()
			local mapped = Result.ok(2):map(function(value)
				return value * 10
			end)
			assert.is_true(mapped:isOk())
			assert.equals(20, mapped.value)
		end)

		it("leaves the original result as it was", function()
			local original = Result.ok(2)
			original:map(function(value)
				return value * 10
			end)
			assert.equals(2, original.value)
		end)

		it("keeps a failed result and does not call the function", function()
			local called = false
			local mapped = Result.err("boom", 500):map(function()
				called = true
			end)
			assert.is_false(called)
			assert.is_true(mapped:isErr())
			assert.equals("boom", mapped.error)
			assert.equals(500, mapped.code)
		end)
	end)

	describe("mapErr", function()
		it("transforms the message of a failed result and keeps its code", function()
			local mapped = Result.err("boom", 500):mapErr(function(message)
				return "Failed: " .. message
			end)
			assert.is_true(mapped:isErr())
			assert.equals("Failed: boom", mapped.error)
			assert.equals(500, mapped.code)
		end)

		it("passes the code to the function", function()
			local mapped = Result.err("boom", 500):mapErr(function(message, code)
				return message .. " (" .. code .. ")"
			end)
			assert.equals("boom (500)", mapped.error)
		end)

		it("keeps a successful result and does not call the function", function()
			local called = false
			local mapped = Result.ok(1):mapErr(function()
				called = true
			end)
			assert.is_false(called)
			assert.is_true(mapped:isOk())
			assert.equals(1, mapped.value)
		end)
	end)

	describe("andThen", function()
		it("returns the result of the function for a successful result", function()
			local function double(value)
				return Result.ok(value * 2)
			end
			assert.equals(8, Result.ok(4):andThen(double).value)

			local failed = Result.ok(1):andThen(function()
				return Result.err("too small", 1)
			end)
			assert.is_true(failed:isErr())
			assert.equals("too small", failed.error)
			assert.equals(1, failed.code)
		end)

		it("skips the function for a failed result and keeps its error", function()
			local called = false
			local chained = Result.err("boom", 500):andThen(function()
				called = true
				return Result.ok("never")
			end)
			assert.is_false(called)
			assert.is_true(chained:isErr())
			assert.equals("boom", chained.error)
			assert.equals(500, chained.code)
		end)

		it("stops a chain at the first failure", function()
			local calls = {}
			local result = Result.ok(1)
				:andThen(function(value)
					table.insert(calls, "first")
					return Result.ok(value + 1)
				end)
				:andThen(function()
					table.insert(calls, "second")
					return Result.err("stop", 7)
				end)
				:andThen(function()
					table.insert(calls, "third")
					return Result.ok("never")
				end)
			assert.same({ "first", "second" }, calls)
			assert.equals("stop", result.error)
			assert.equals(7, result.code)
		end)
	end)

	describe("match", function()
		it("calls the success handler with the value and returns what it returns", function()
			local seen = {}
			local returned = Result.ok("v"):match(function(value)
				table.insert(seen, "ok:" .. value)
				return "from ok"
			end, function()
				table.insert(seen, "err")
				return "from err"
			end)
			assert.equals("from ok", returned)
			assert.same({ "ok:v" }, seen)
		end)

		it("calls the failure handler with the message and the code and returns what it returns", function()
			local seen = {}
			local returned = Result.err("boom", 500):match(function()
				table.insert(seen, "ok")
				return "from ok"
			end, function(message, code)
				table.insert(seen, "err:" .. message .. ":" .. code)
				return "from err"
			end)
			assert.equals("from err", returned)
			assert.same({ "err:boom:500" }, seen)
		end)
	end)

	describe("unpack", function()
		it("returns true and the value for a successful result", function()
			local success, value = Result.ok("v"):unpack()
			assert.is_true(success)
			assert.equals("v", value)
		end)

		it("returns false and the message for a failed result", function()
			local success, message = Result.err("boom", 500):unpack()
			assert.is_false(success)
			assert.equals("boom", message)
		end)
	end)

	describe("wrap", function()
		it("turns (true, value) into a successful result and passes the arguments on", function()
			local wrapped = Result.wrap(function(a, b)
				return true, a + b
			end)
			local result = wrapped(2, 3)
			assert.is_true(result:isOk())
			assert.equals(5, result.value)
		end)

		it("turns (false, message) into a failed result", function()
			local wrapped = Result.wrap(function()
				return false, "nope"
			end)
			local result = wrapped()
			assert.is_true(result:isErr())
			assert.equals("nope", result.error)
		end)
	end)

	describe("wrapPcall", function()
		it("returns the value of a function that succeeds, passing the arguments on", function()
			local wrapped = Result.wrapPcall(function(a, b)
				return a .. b
			end)
			local result = wrapped("x", "y")
			assert.is_true(result:isOk())
			assert.equals("xy", result.value)
		end)

		it("turns an error into a failed result with its message", function()
			local wrapped = Result.wrapPcall(function()
				error("boom", 0)
			end)
			local result = wrapped()
			assert.is_true(result:isErr())
			assert.equals("boom", result.error)
		end)

		it("turns a runtime error into a failed result", function()
			local wrapped = Result.wrapPcall(function(target)
				return target.field
			end)
			local result = wrapped()
			assert.is_true(result:isErr())
			assert.is_truthy(result.error:find("attempt to index", 1, true))
		end)

		it("always gives the message as text, even when the error is not text", function()
			local wrapped = Result.wrapPcall(function()
				error({ code = 1 })
			end)
			local result = wrapped()
			assert.is_true(result:isErr())
			assert.equals("string", type(result.error))
		end)
	end)

	describe("wrapNilable", function()
		it("returns a successful result for a value and passes the arguments on", function()
			local wrapped = Result.wrapNilable(function(a, b)
				return a .. b
			end, "failed")
			local result = wrapped("x", "y")
			assert.is_true(result:isOk())
			assert.equals("xy", result.value)
		end)

		it("returns a failed result with the message when the function returns nil", function()
			local wrapped = Result.wrapNilable(function()
				return nil
			end, "Could not read the file")
			local result = wrapped()
			assert.is_true(result:isErr())
			assert.equals("Could not read the file", result.error)
		end)

		it("uses a default message when none is given", function()
			local result = Result.wrapNilable(function() end)()
			assert.is_true(result:isErr())
			assert.equals("Operation failed", result.error)
		end)

		it("counts false as a value", function()
			local result = Result.wrapNilable(function()
				return false
			end, "failed")()
			assert.is_true(result:isOk())
			assert.is_false(result.value)
		end)
	end)

	describe("from", function()
		it("builds a successful result from (true, value)", function()
			local result = Result.from(true, "v")
			assert.is_true(result:isOk())
			assert.equals("v", result.value)
		end)

		it("builds a failed result from (false, message)", function()
			local result = Result.from(false, "boom")
			assert.is_true(result:isErr())
			assert.equals("boom", result.error)
		end)

		it("builds a failed result when the flag is nil", function()
			local result = Result.from(nil, "boom")
			assert.is_true(result:isErr())
			assert.equals("boom", result.error)
		end)
	end)

	describe("all", function()
		it("returns a successful result holding the values in order", function()
			local combined = Result.all({ Result.ok("a"), Result.ok("b"), Result.ok("c") })
			assert.is_true(combined:isOk())
			assert.same({ "a", "b", "c" }, combined.value)
		end)

		it("returns a successful result with an empty list when there are no results", function()
			local combined = Result.all({})
			assert.is_true(combined:isOk())
			assert.same({}, combined.value)
		end)

		it("returns the first failed result and ignores the later ones", function()
			local combined = Result.all({ Result.ok(1), Result.err("first", 1), Result.err("second", 2) })
			assert.is_true(combined:isErr())
			assert.equals("first", combined.error)
			assert.equals(1, combined.code)
		end)
	end)

	describe("orElse", function()
		it("returns the first result when it succeeded, without calling a fallback function", function()
			local called = false
			local result = Result.orElse(Result.ok("first"), function()
				called = true
				return Result.ok("fallback")
			end)
			assert.is_false(called)
			assert.equals("first", result.value)
		end)

		it("returns the fallback result when the first one failed", function()
			local result = Result.orElse(Result.err("boom"), Result.ok("fallback"))
			assert.is_true(result:isOk())
			assert.equals("fallback", result.value)
		end)

		it("returns what a fallback function returns when the first one failed", function()
			local calls = 0
			local result = Result.orElse(Result.err("boom"), function()
				calls = calls + 1
				return Result.ok("computed")
			end)
			assert.equals(1, calls)
			assert.equals("computed", result.value)
		end)

		it("returns the error of the fallback when both fail", function()
			local result = Result.orElse(Result.err("first"), Result.err("second", 2))
			assert.is_true(result:isErr())
			assert.equals("second", result.error)
			assert.equals(2, result.code)
		end)
	end)
end)
