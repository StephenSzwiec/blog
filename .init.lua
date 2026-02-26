-- special script called by main redbean process at startup
HidePath('/usr/share/zoneinfo/')
HidePath('/usr/share/ssl/') 

-- fm from https://github.com/pkulchenko/fullmoon  
local fm = require "fm"
local app = require "app"

-----------------------------------------------------------------
-- Basic Browser Launch Logic
-----------------------------------------------------------------
local function launch_browser(url)
    if os.getenv("OS") == "Windows_NT" then
        os.execute("start " .. url)
    else
        -- Try xdg-open for Linux, then open for macOS
        if not os.execute("xdg-open " .. url .. " 2>/dev/null") then
            os.execute("open " .. url)
        end
    end
end

-- Launch browser only on initial startup
if not _G.launched then
    launch_browser("http://localhost:8080")
    _G.launched = true
end

fm.run()
