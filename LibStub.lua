-- LibStub 1.0 (public domain) -- minimal version registry for libraries.
-- Bundled so LibAsyncPriority-1.0 also works as a standalone addon.
-- If another addon already loaded LibStub, this file leaves it untouched.
local LIBSTUB_MAJOR, LIBSTUB_MINOR = "LibStub", 2

local LibStub = _G[LIBSTUB_MAJOR]
if not LibStub or LibStub.minor < LIBSTUB_MINOR then
	LibStub = LibStub or { libs = {}, minors = {} }
	_G[LIBSTUB_MAJOR] = LibStub
	LibStub.minor = LIBSTUB_MINOR

	--- Returns an existing library, or nil (or errors when silent is not set).
	-- @param major (string) Library name, e.g. "LibAsyncPriority-1.0".
	-- @param silent (boolean, optional) True to return nil instead of erroring.
	-- @return The library table, or nil.
	function LibStub:GetLibrary(major, silent)
		if not self.libs[major] and not silent then
			error(("Cannot find a library instance of %q."):format(tostring(major)), 2)
		end
		return self.libs[major], self.minors[major]
	end

	--- Registers or upgrades a library. Returns nil when a newer or equal
	-- minor version is already registered, so the caller must stop loading.
	-- @param major (string) Library name.
	-- @param minor (number|string) Minor version; strings must contain a number.
	-- @return The library table to populate, or nil.
	function LibStub:NewLibrary(major, minor)
		assert(type(major) == "string", "Bad argument #2 to `NewLibrary' (string expected)")
		minor = assert(tonumber(strmatch(minor, "%d+")), "Minor version must contain a number")
		local oldminor = self.minors[major]
		if oldminor and oldminor >= minor then return nil end
		self.minors[major], self.libs[major] = minor, self.libs[major] or {}
		return self.libs[major]
	end

	setmetatable(LibStub, { __call = LibStub.GetLibrary })
end
