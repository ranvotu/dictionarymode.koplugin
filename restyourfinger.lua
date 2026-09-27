-- Rest your finger: swallow long-press on free space (margins, 2-col gutter).
--
-- Strict (optional, all tap-zone modes):
--   ON  → hold only when finger hits a word box (getWordFromPosition + sbox).
--   OFF → hold allowed anywhere inside the zone/frame (Pixel = same as Auto frame).
--
-- Heavy note: Strict calls getWordFromPosition once per hold *start* (not every frame).

local Screen = require("device").screen
local _ = require("gettext")

local REST_FINGER_KEY = "dictionary_mode_rest_finger"
local REST_FINGER_STRICT_KEY = "dictionary_mode_rest_finger_strict"

local RestYourFinger = {}

RestYourFinger.REST_FINGER_KEY = REST_FINGER_KEY
RestYourFinger.REST_FINGER_STRICT_KEY = REST_FINGER_STRICT_KEY

function RestYourFinger.install(DictionaryMode)
	function DictionaryMode:isSystemLongPressEnabled()
		return G_reader_settings:readSetting("default_highlight_action", "ask") ~= "nothing"
	end

	function DictionaryMode:isRestFingerEnabled()
		if not self:isEnabled() then
			return false
		end
		if not self:isSystemLongPressEnabled() then
			return false
		end
		return G_reader_settings:isTrue(REST_FINGER_KEY)
	end

	function DictionaryMode:isRestFingerStrict()
		return G_reader_settings:isTrue(REST_FINGER_STRICT_KEY)
	end

	function DictionaryMode:toggleRestFinger()
		G_reader_settings:flipNilOrFalse(REST_FINGER_KEY)
		self:registerHold()
	end

	function DictionaryMode:toggleRestFingerStrict()
		G_reader_settings:flipNilOrFalse(REST_FINGER_STRICT_KEY)
		-- No need to re-register zones; isHoldAllowedAt reads the flag live.
	end

	-- Inside the active dictionary zone? (frame / custom rect — no word check).
	function DictionaryMode:isHoldInZone(pos)
		if not pos then
			return false
		end
		local zone_type = self:getTapZoneType()
		if zone_type == "auto" or zone_type == "text" then
			return self:isInContentArea(pos)
		end
		local zone = (zone_type == "custom" and self:getCustomTapZone()) or self:getDefaultTapZone()
		if not zone then
			return false
		end
		local sw, sh = Screen:getWidth(), Screen:getHeight()
		local x0 = zone.ratio_x * sw
		local y0 = zone.ratio_y * sh
		local x1 = x0 + zone.ratio_w * sw
		local y1 = y0 + zone.ratio_h * sh
		return pos.x >= x0 and pos.x <= x1 and pos.y >= y0 and pos.y <= y1
	end

	-- Finger on a real word box at ges (CRE call — only when Strict is on).
	function DictionaryMode:isHoldOnWord(ges)
		local pos = ges and ges.pos
		if not pos then
			return false
		end
		local page_pos = self.view:screenToPageTransform(pos)
		if not page_pos then
			return false
		end
		local ok, word = pcall(function()
			return self.ui.document:getWordFromPosition(page_pos, true)
		end)
		if not ok or not word or not word.word or word.word == "" then
			return false
		end
		local text = word.word:match("^%s*(.-)%s*$") or ""
		if text == "" or text:find("%s") then
			return false
		end
		return self:tapHitsWord(ges, word, page_pos)
	end

	-- True if long-press may start text selection.
	function DictionaryMode:isHoldAllowedAt(ges)
		if not self:isRestFingerEnabled() then
			return false
		end
		local pos = ges and ges.pos
		if not pos then
			return false
		end
		if not self:isHoldInZone(pos) then
			return false
		end
		if self:isRestFingerStrict() then
			return self:isHoldOnWord(ges)
		end
		return true
	end

	function DictionaryMode:unregisterHoldZones()
		if not (self.ui and self.ui.unRegisterTouchZones) then
			return
		end
		pcall(function()
			self.ui:unRegisterTouchZones({
				{ id = "dictionarymode_hold" },
				{ id = "dictionarymode_hold_pan" },
				{ id = "dictionarymode_hold_release" },
			})
		end)
	end

	function DictionaryMode:registerHold()
		self:unregisterHoldZones()
		if not self:isRestFingerEnabled() then
			return
		end
		local function rest_handler(ges)
			if not self:isRestFingerEnabled() then
				return false
			end
			local hl = self.ui and self.ui.highlight
			if hl and hl.hold_pos then
				return false
			end
			if ges and self:isHoldAllowedAt(ges) then
				return false
			end
			return true
		end
		local full = {
			ratio_x = 0,
			ratio_y = 0,
			ratio_w = 1,
			ratio_h = 1,
		}
		self.ui:registerTouchZones({
			{
				id = "dictionarymode_hold",
				ges = "hold",
				screen_zone = full,
				overrides = { "readerhighlight_hold" },
				handler = rest_handler,
			},
			{
				id = "dictionarymode_hold_pan",
				ges = "hold_pan",
				screen_zone = full,
				overrides = { "readerhighlight_hold_pan" },
				handler = rest_handler,
			},
			{
				id = "dictionarymode_hold_release",
				ges = "hold_release",
				screen_zone = full,
				overrides = { "readerhighlight_hold_release" },
				handler = rest_handler,
			},
		})
	end

	--- Menu rows: section header + Enable + Strict pixel (like Tap zone block).
	function DictionaryMode:getRestFingerMenuItems()
		return {
			{
				text = _("Rest my thumb"),
				checked_func = function()
					return G_reader_settings:isTrue(REST_FINGER_KEY)
				end,
				enabled_func = function()
					return self:isEnabled() and self:isSystemLongPressEnabled()
				end,
				callback = function()
					self:toggleRestFinger()
				end,
				help_text = _("Long-press outside the dictionary tap zone does nothing (margins, two-column gutter), so you can rest a finger there without starting a selection."),
			},
			{
				text = _("Strict pixel"),
				checked_func = function()
					return G_reader_settings:isTrue(REST_FINGER_STRICT_KEY)
				end,
				enabled_func = function()
					return self:isEnabled()
						and self:isSystemLongPressEnabled()
						and G_reader_settings:isTrue(REST_FINGER_KEY)
				end,
				callback = function()
					self:toggleRestFingerStrict()
				end,
				help_text = _("When on, long-press inside the zone only starts a selection if the finger is on a word (all modes). When off, any long-press inside the zone is allowed — including blank space in Pixel mode."),
				separator = true,
			},
		}
	end
end

return RestYourFinger
