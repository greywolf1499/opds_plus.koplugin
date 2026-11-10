local helper = require("helper")

describe("Semver", function()
	local Semver

	before_each(function()
		helper.reset()
		Semver = helper.load("utils.semver")
	end)

	after_each(helper.reset)

	describe("parse", function()
		it("reads the three numbers of a version", function()
			local version = Semver.parse("1.4.0")
			assert.equals(1, version.major)
			assert.equals(4, version.minor)
			assert.equals(0, version.patch)
			assert.same({}, version.prerelease)
			assert.same({}, version.build)
		end)

		it("takes the leading v of a release tag", function()
			assert.same(Semver.parse("1.4.0"), Semver.parse("v1.4.0"))
			assert.same(Semver.parse("1.4.0"), Semver.parse("V1.4.0"))
		end)

		it("ignores whitespace around the version", function()
			assert.same(Semver.parse("1.4.0"), Semver.parse(" v1.4.0\n"))
		end)

		it("reads the pre-release identifiers", function()
			assert.same({ "rc", "1" }, Semver.parse("1.4.0-rc.1").prerelease)
			assert.same({ "0", "3", "7" }, Semver.parse("1.0.0-0.3.7").prerelease)
		end)

		it("starts the pre-release at the first hyphen, and keeps the others in it", function()
			assert.same({ "alpha-beta", "x-y-z" }, Semver.parse("1.0.0-alpha-beta.x-y-z").prerelease)
		end)

		it("takes a pre-release identifier with letters and a leading zero", function()
			assert.same({ "0a" }, Semver.parse("1.0.0-0a").prerelease)
		end)

		it("reads the build metadata, where leading zeros are fine", function()
			local version = Semver.parse("1.0.0-beta+exp.sha.5114f85")
			assert.same({ "beta" }, version.prerelease)
			assert.same({ "exp", "sha", "5114f85" }, version.build)
			assert.same({ "001" }, Semver.parse("1.0.0+001").build)
			assert.same({ "20130313144700" }, Semver.parse("1.0.0+20130313144700").build)
		end)

		it("takes the numbers up to nine digits", function()
			assert.equals(999999999, Semver.parse("999999999.0.0").major)
		end)

		it("refuses what is not a semantic version", function()
			local refused = {
				"", " ", "v", "latest", "1", "1.2", "1.2.3.4", "1.2.x", "a.b.c", "-1.2.3", "1..3", "1.2.",
				"v v1.2.3", "vv1.2.3", "1.2.3 beta", "1,2,3",
			}
			for _, text in ipairs(refused) do
				assert.is_nil(Semver.parse(text), text)
			end
		end)

		it("refuses numbers with leading zeros", function()
			for _, text in ipairs({ "01.2.3", "1.02.3", "1.2.03", "1.2.3-01", "1.2.3-0.01" }) do
				assert.is_nil(Semver.parse(text), text)
			end
		end)

		it("refuses empty identifiers", function()
			for _, text in ipairs({ "1.2.3-", "1.2.3+", "1.2.3-+", "1.2.3-a..b", "1.2.3-.a", "1.2.3-a.", "1.2.3+a..b" }) do
				assert.is_nil(Semver.parse(text), text)
			end
		end)

		it("refuses characters a version can't hold", function()
			for _, text in ipairs({ "1.2.3-a_b", "1.2.3-\195\169", "1.2.3+a b", "1.2.3-a+b+c", "1.2.3\0", "1.2.3-a\n.b" }) do
				assert.is_nil(Semver.parse(text), text)
			end
		end)

		it("refuses numbers too long to hold exactly", function()
			assert.is_nil(Semver.parse("1234567890.0.0"))
			assert.is_nil(Semver.parse("1.2.3456789012"))
		end)

		it("refuses what is not text, without raising", function()
			assert.is_nil(Semver.parse(nil))
			assert.is_nil(Semver.parse(1))
			assert.is_nil(Semver.parse(true))
			assert.is_nil(Semver.parse({}))
			assert.is_nil(Semver.parse(function() end))
		end)
	end)

	describe("compare", function()
		it("orders by major, then minor, then patch, as numbers", function()
			assert.equals(-1, Semver.compare("1.0.0", "2.0.0"))
			assert.equals(-1, Semver.compare("2.0.0", "2.1.0"))
			assert.equals(-1, Semver.compare("2.1.0", "2.1.1"))
			assert.equals(1, Semver.compare("1.4.0", "1.3.9"))
			assert.equals(1, Semver.compare("1.10.0", "1.9.0"))
			assert.equals(1, Semver.compare("1.0.10", "1.0.9"))
			assert.equals(0, Semver.compare("1.4.0", "1.4.0"))
		end)

		it("puts a pre-release before its release, in the order semver.org gives", function()
			local ascending = {
				"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
				"1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
			}
			for low = 1, #ascending - 1 do
				for high = low + 1, #ascending do
					assert.equals(-1, Semver.compare(ascending[low], ascending[high]), ascending[low] .. " < " .. ascending[high])
					assert.equals(1, Semver.compare(ascending[high], ascending[low]), ascending[high] .. " > " .. ascending[low])
				end
			end
		end)

		it("puts a pre-release of a newer version above an older release", function()
			assert.equals(1, Semver.compare("1.4.0-rc.1", "1.3.1"))
		end)

		it("ranks numeric identifiers by value, and below the ones with letters", function()
			assert.equals(-1, Semver.compare("1.0.0-2", "1.0.0-10"))
			assert.equals(-1, Semver.compare("1.0.0-10", "1.0.0-alpha"))
			assert.equals(-1, Semver.compare("1.0.0-9", "1.0.0-0a"))
		end)

		it("compares numeric identifiers of any length exactly", function()
			assert.equals(-1, Semver.compare("1.0.0-20240131235959", "1.0.0-20240201000000"))
			assert.equals(-1, Semver.compare("1.0.0-99999999999999999999", "1.0.0-100000000000000000000"))
			assert.equals(0, Semver.compare("1.0.0-99999999999999999999", "1.0.0-99999999999999999999"))
		end)

		it("orders identifiers with letters by ASCII, so capitals come first", function()
			assert.equals(-1, Semver.compare("1.0.0-Z", "1.0.0-a"))
			assert.equals(1, Semver.compare("1.0.0-a", "1.0.0-B"))
		end)

		it("keeps a hyphen inside its identifier", function()
			-- "rc-1" is one identifier, which ranks above the "rc" that starts "rc.1"
			assert.equals(1, Semver.compare("1.0.0-rc-1", "1.0.0-rc.1"))
		end)

		it("ignores build metadata", function()
			assert.equals(0, Semver.compare("1.0.0+a", "1.0.0+b"))
			assert.equals(0, Semver.compare("1.0.0+a", "1.0.0"))
			assert.equals(0, Semver.compare("1.0.0-rc.1+a", "1.0.0-rc.1+b"))
		end)

		it("ignores a leading v", function()
			assert.equals(0, Semver.compare("v1.4.0", "1.4.0"))
			assert.equals(1, Semver.compare("v1.4.1", "1.4.0"))
		end)

		it("has no answer when either side is not a version", function()
			assert.is_nil(Semver.compare("latest", "1.0.0"))
			assert.is_nil(Semver.compare("1.0.0", "latest"))
			assert.is_nil(Semver.compare("1.0.0", nil))
			assert.is_nil(Semver.compare(nil, nil))
		end)
	end)

	describe("normalize", function()
		it("drops the leading v and the whitespace", function()
			assert.equals("1.4.0", Semver.normalize("v1.4.0"))
			assert.equals("1.4.0", Semver.normalize("  1.4.0\n"))
		end)

		it("keeps the pre-release and the build metadata", function()
			assert.equals("1.4.0-rc.1+build.5", Semver.normalize(" V1.4.0-rc.1+build.5 "))
		end)

		it("has no answer for something that is not a version", function()
			assert.is_nil(Semver.normalize("latest"))
			assert.is_nil(Semver.normalize(nil))
		end)
	end)
end)
