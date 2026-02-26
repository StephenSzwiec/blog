# --- Web Sources --- 
REDBEAN_URL    = https://redbean.dev/redbean-3.0.0.com
FM_URL         = https://raw.githubusercontent.com/pkulchenko/fullmoon/master/fullmoon.lua
HTMX_URL       = https://cdn.jsdelivr.net/npm/htmx.org@2.0.8/dist/htmx.min.js
PLEX_SERIF     = https://github.com/IBM/plex/raw/master/IBM-Plex-Serif/fonts/complete/ttf
PLEX_MONO      = https://github.com/IBM/plex/raw/master/IBM-Plex-Mono/fonts/complete/ttf

# --- Targets --- 
TARGET       = blog.com 
UPSTREAM_BIN = .deps/redbean.com
LUA_DIR      = .lua
ASSET_DIR    = static

LOCAL_LUA = .init.lua $(wildcard $(LUA_DIR)/*.lua)
LOCAL_ASSET = $(wildcard $(ASSET_DIR)/*) 

FILES = .init.lua .lua static
FONTS = $(ASSET_DIR)/plex-serif-400.ttf \
		$(ASSET_DIR)/plex-serif-500.ttf \
		$(ASSET_DIR)/plex-mono-400.ttf \
		$(ASSET_DIR)/plex-mono-500.ttf 


.PHONY: all clean fetch build setup 

all: $(TARGET)

$(LUA_DIR) $(ASSET_DIR) .deps:
	@mkdir -p $@

fetch: .deps/redbean.com $(LUA_DIR)/fm.lua $(ASSET_DIR)/htmx.min.js fetch-fonts

.deps/redbean.com: | .deps
	curl -L $(REDBEAN_URL) -o $@
	chmod +x $@

$(LUA_DIR)/fm.lua: | $(LUA_DIR)
	curl -L $(FM_URL) -o $@

$(ASSET_DIR)/htmx.min.js: | $(ASSET_DIR)
	curl -L $(HTMX_URL) -o $@

fetch-fonts: | $(ASSET_DIR)
	@echo "Fetching fonts..."
	curl -L $(PLEX_SERIF)/IBMPlexSerif-Regular.ttf -o $(ASSET_DIR)/plexserif400.ttf
	curl -L $(PLEX_SERIF)/IBMPlexSerif-Medium.ttf  -o $(ASSET_DIR)/plexserif500.ttf
	curl -L $(PLEX_MONO)/IBMPlexMono-Regular.ttf   -o $(ASSET_DIR)/plexmono400.ttf
	curl -L $(PLEX_MONO)/IBMPlexMono-Medium.ttf    -o $(ASSET_DIR)/plexmono500.ttf

$(TARGET): fetch $(LOCAL_LUA) $(LOCAL_ASSET)
	cp $(UPSTREAM_BIN) $(TARGET)
	zip -r $(TARGET) .init.lua $(LUA_DIR)/ $(ASSET_DIR)/
	@echo "Build complete: $(TARGET)"

setup: $(TARGET)
	./$(TARGET) -i setup_admin.lua 

clean:  
	rm -f $(TARGET)
	rm -f .lua/fm.lua 
	rm -f static/htmx.min.js
	rm -f $(FONTS)
	rm -f blog.db 
	rm -rf .deps
