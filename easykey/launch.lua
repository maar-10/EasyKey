--- Role dispatch for EasyKey. Requires ONLY the module for the active role, so a
--- role-specific installer that ships just that role's files still launches
--- cleanly (e.g. a pocket has no server.lua on disk).
return function(role)
    local entries = {
        pocket   = "easykey.pocket.run",
        server   = "easykey.server",
        control  = "easykey.control",
        manual   = "easykey.manual",
        elevator = "easykey.elevator",
        elevmon  = "easykey.elevmon",
    }
    local mod = entries[role]
    if not mod then
        error("Unknown role '" .. tostring(role) .. "' for easykey (use "
            .. "pocket|server|control|manual|elevator|elevmon)", 0)
    end
    require(mod)
end
