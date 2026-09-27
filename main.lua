local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CenteredMultiInputDialog = MultiInputDialog:extend{}
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local ContentArea = require("contentarea")
local InnerGap = require("innergap")
local RestYourFinger = require("restyourfinger")

local FACTORY_TAP_ZONE = {
	ratio_x = 0.23,
	ratio_y = 0.05,
	ratio_w = 0.54,
	ratio_h = 0.9,
}
-- Kiểu vùng chạm + Custom: theo từng sách. Default: toàn cục.
local TAP_ZONE_TYPE_KEY = "dictionary_mode_tap_zone_type"
local CUSTOM_ZONE_KEY = "dictionary_mode_tap_zone"

local DictionaryMode = WidgetContainer:extend{
	name = "dictionarymode",
	is_doc_only = true,
}

ContentArea.install(DictionaryMode)
InnerGap.install(DictionaryMode)
RestYourFinger.install(DictionaryMode)

function DictionaryMode:onDispatcherRegisterActions()
	Dispatcher:registerAction("dictionarymode_action", {
		category = "none",
		event = "DictionaryMode",
		title = _("Dictionary Mode"),
		general = true,
	})
end

function DictionaryMode:init()
	self:onDispatcherRegisterActions()
	self.ui.menu:registerToMainMenu(self)
	self:registerTap()
	self:registerHold()
end

function DictionaryMode:isEnabled()
	if self.ui and self.ui.doc_settings then
		local per_book = self.ui.doc_settings:readSetting("enable_dictionary_mode")
		if per_book ~= nil then
			return per_book == true
		end
	end
	return false
end

function DictionaryMode:toggle()
	local new_state = not self:isEnabled()
	if self.ui and self.ui.doc_settings then
		self.ui.doc_settings:saveSetting("enable_dictionary_mode", new_state)
	end
	self:registerTap()
	self:registerHold()
	self:updateInnerGap(true)
end

function DictionaryMode:readBookSetting(key)
	if self.ui and self.ui.doc_settings then
		return self.ui.doc_settings:readSetting(key)
	end
	return nil
end

function DictionaryMode:saveBookSetting(key, value)
	if self.ui and self.ui.doc_settings then
		self.ui.doc_settings:saveSetting(key, value)
	else
		G_reader_settings:saveSetting(key, value)
	end
end

-- Lựa chọn đã lưu cho sách này; không đổi theo layout 1/2 cột.
function DictionaryMode:getStoredTapZoneType()
	local zone_type = self:readBookSetting(TAP_ZONE_TYPE_KEY)
	if zone_type == nil then
		zone_type = G_reader_settings:readSetting(TAP_ZONE_TYPE_KEY, "default")
	end
	return zone_type
end

function DictionaryMode:getCustomTapZone()
	return self:readBookSetting(CUSTOM_ZONE_KEY) or G_reader_settings:readSetting(CUSTOM_ZONE_KEY)
end

-- Effective zone for current layout (may fall back to auto). Does not write settings.
function DictionaryMode:getTapZoneType(r)
	local zone_type = self:getStoredTapZoneType()
	if self:isEnabled() and (zone_type == "default" or zone_type == "custom") and not self:isFixedTapZoneAllowed(r) then
		return "auto"
	end
	return zone_type
end

function DictionaryMode:setTapZoneType(zone_type, zone)
	self:saveBookSetting(TAP_ZONE_TYPE_KEY, zone_type)
	if zone then
		self:saveBookSetting(CUSTOM_ZONE_KEY, zone)
	end
	self:registerTap()
	self:registerHold()
end

function DictionaryMode:getDefaultTapZone()
	return G_reader_settings:readSetting("dictionary_mode_default_tap_zone") or FACTORY_TAP_ZONE
end

function DictionaryMode:isFixedZoneMenuEnabled()
	return self:isEnabled() and self:isFixedTapZoneAllowed()
end

function DictionaryMode:formatTapZone(zone, short)
	if short then
		return T("x=%1 y=%2 w=%3 h=%4",
			string.format("%.2f", zone.ratio_x),
			string.format("%.2f", zone.ratio_y),
			string.format("%.2f", zone.ratio_w),
			string.format("%.2f", zone.ratio_h))
	end
	return T("x=%1  y=%2  w=%3  h=%4", zone.ratio_x, zone.ratio_y, zone.ratio_w, zone.ratio_h)
end

function DictionaryMode:getWordScreenBox(word, pos)
	local sbox = word.sbox
	if not sbox then
		return nil
	end
	if self.ui.paging and self.view.pageToScreenTransform then
		sbox = self.view:pageToScreenTransform(pos.page, sbox)
	elseif self.transformInnerGapRect then
		sbox = self:transformInnerGapRect(sbox)
	end
	return sbox
end

function DictionaryMode:tapHitsWord(ges, word, pos)
	local sbox = self:getWordScreenBox(word, pos)
	if not sbox or not sbox.w or sbox.w <= 0 then
		return false
	end
	local slop_x = math.max(Screen:scaleBySize(8), math.min(Screen:scaleBySize(10), sbox.w * 0.15))
	local slop_y = math.max(Screen:scaleBySize(3), math.min(Screen:scaleBySize(5), (sbox.h or 0) * 0.10))
	local x, y = ges.pos.x, ges.pos.y
	if x < sbox.x - slop_x or x > sbox.x + sbox.w + slop_x then
		return false
	end
	if y < (sbox.y or 0) - slop_y or y > (sbox.y or 0) + (sbox.h or 0) + slop_y then
		return false
	end
	return true
end

function DictionaryMode:lookupSelection(selection)
	if self.ui.languagesupport and self.ui.languagesupport:hasActiveLanguagePlugins() then
		local new_selection = self.ui.languagesupport:improveWordSelection(selection)
		if new_selection then
			selection = new_selection
		end
	end
	local text = self:cleanupSelectedText(selection.text or "")
	if text == "" then
		return false
	end
	self.ui:handleEvent(Event:new("LookupWord", text))
	if self.ui.document.clearSelection then
		self.ui.document:clearSelection()
	end
	return true
end

function DictionaryMode:addToMainMenu(menu_items)
	local unavailable_fixed = _("Unavailable in two-column view & uneven margins.")
	local sub = {
		{
			text = _("Enable dictionary mode"),
			checked_func = function()
				return self:isEnabled()
			end,
			keep_menu_open = true,
			callback = function()
				self:toggle()
			end,
			separator = true,
		},
	}
	for _, item in ipairs(self:getRestFingerMenuItems()) do
		item.keep_menu_open = true
		sub[#sub + 1] = item
	end
	sub[#sub + 1] = self:getInnerGapMenuItem()
	sub[#sub + 1] = self:getInnerGapBackgroundMenuItem()
	sub[#sub + 1] = self:getInnerGapStatusMenuItem()
	sub[#sub + 1] = {
		text = _("Tap zone"),
	}
	sub[#sub + 1] = {
		text_func = function()
			if not self:isEnabled() then
				return _("Auto")
			end
			return T(_("Auto (%1)"), self:formatTapZone(self:getContentTapZone(), true))
		end,
		enabled_func = function()
			return self:isEnabled()
		end,
		help_text_func = function()
			if not self:isEnabled() then
				return nil
			end
			return T(_("%1"), self:formatTapZone(self:getContentTapZone()))
		end,
		checked_func = function()
			return self:getTapZoneType() == "auto"
		end,
		radio = true,
		keep_menu_open = true,
		callback = function()
			self:setTapZoneType("auto")
		end,
	}
	sub[#sub + 1] = {
		text_func = function()
			if not self:isEnabled() then
				return _("Default")
			end
			return T(_("Default (%1)"), self:formatTapZone(self:getDefaultTapZone()))
		end,
		radio = true,
		enabled_func = function()
			return self:isFixedZoneMenuEnabled()
		end,
		checked_func = function()
			return self:getTapZoneType() == "default"
		end,
		help_text_func = function()
			if self:isEnabled() and not self:isFixedTapZoneAllowed() then
				return unavailable_fixed
			end
			return nil
		end,
		keep_menu_open = true,
		callback = function()
			self:setTapZoneType("default")
		end,
		hold_callback = function(touchmenu_instance)
			local current_custom = G_reader_settings:readSetting("dictionary_mode_default_tap_zone")
			if not current_custom then
				return
			end
			G_reader_settings:saveSetting("dictionary_mode_default_tap_zone", nil)
			self:setTapZoneType("default")
			if touchmenu_instance then
				touchmenu_instance:updateItems()
			end
			UIManager:show(InfoMessage:new{
				text = _("Default tap zone restored"),
				timeout = 1.5,
			})
		end,
	}
	sub[#sub + 1] = {
		text_func = function()
			if not self:isEnabled() then
				return _("Custom")
			end
			local zone = self:getCustomTapZone() or self:getDefaultTapZone()
			return T(_("Custom (%1)"), self:formatTapZone(zone))
		end,
		radio = true,
		enabled_func = function()
			return self:isFixedZoneMenuEnabled()
		end,
		checked_func = function()
			return self:getTapZoneType() == "custom"
		end,
		help_text_func = function()
			if self:isEnabled() and not self:isFixedTapZoneAllowed() then
				return unavailable_fixed
			end
			return nil
		end,
		keep_menu_open = true,
		callback = function(touchmenu_instance)
			self:showCustomTapZoneDialog(function()
				if touchmenu_instance then
					touchmenu_instance:updateItems()
				end
			end)
		end,
	}
	sub[#sub + 1] = {
		text = _("Pixel"),
		enabled_func = function()
			return self:isEnabled()
		end,
		checked_func = function()
			return self:getTapZoneType() == "text"
		end,
		radio = true,
		keep_menu_open = true,
		callback = function()
			self:setTapZoneType("text")
		end,
	}
	menu_items.dictionarymode = {
		text = _("Dictionary Mode"),
		sorting_hint = "taps_and_gestures",
		sub_item_table = sub,
	}
end

function DictionaryMode:onDictionaryMode()
	self:toggle()
	local text = _("Dictionary mode disabled")
	if self:isEnabled() then
		text = _("Dictionary mode enabled")
	end
	UIManager:show(InfoMessage:new{
		text = text,
		timeout = 1,
	})
end

function DictionaryMode:parseRatio(value, fallback)
	local n = tonumber(value)
	if not n then
		return fallback
	end
	if n > 1 then
		n = n / 100
	end
	if n < 0 then
		n = 0
	end
	if n > 1 then
		n = 1
	end
	return n
end

local function fitZoneAxis(pos, size)
	local min_ratio = ContentArea.MIN_ZONE_RATIO
	if pos + size > 1 then
		size = 1 - pos
	end
	if size < min_ratio then
		size = min_ratio
	end
	pos = math.min(pos, 1 - size)
	return pos, size
end

function DictionaryMode:readZoneFromDialog(dialog)
	local fields = dialog:getFields()
	local fallback = self:getDefaultTapZone()
	local x = self:parseRatio(fields[1], fallback.ratio_x)
	local y = self:parseRatio(fields[2], fallback.ratio_y)
	local w = self:parseRatio(fields[3], fallback.ratio_w)
	local h = self:parseRatio(fields[4], fallback.ratio_h)
	x, w = fitZoneAxis(x, w)
	y, h = fitZoneAxis(y, h)
	return {
		ratio_x = x,
		ratio_y = y,
		ratio_w = w,
		ratio_h = h,
	}
end

function CenteredMultiInputDialog:init(reinit)
	MultiInputDialog.init(self, reinit)
	if not reinit then
		self.keyboard_visible = false
		self.with_keyboard_h = self[1].dimen.h
		self[1].dimen.h = Screen:getHeight()
	end
end

function CenteredMultiInputDialog:onShowKeyboard(...)
	MultiInputDialog.onShowKeyboard(self, ...)
	if self[1] and self[1].dimen then
		self[1].dimen.h = self.with_keyboard_h
			or (Screen:getHeight() - (self._input_widget:getKeyboardDimen().h or 0))
		self[1].ignore = nil
		UIManager:setDirty(nil, "ui")
	end
end

function CenteredMultiInputDialog:onCloseKeyboard(...)
	MultiInputDialog.onCloseKeyboard(self, ...)
	if self[1] and self[1].dimen then
		self[1].dimen.h = Screen:getHeight()
		self[1].ignore = nil
		UIManager:setDirty(nil, "ui")
	end
end

function DictionaryMode:showCustomTapZoneDialog(on_applied)
	local zone = self:getCustomTapZone() or self:getDefaultTapZone()
	local dialog
	dialog = CenteredMultiInputDialog:new{
		title = _("Custom tap zone"),
		fields = {
			{
				description = _("X (left, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_x),
				hint = "0.23",
			},
			{
				description = _("Y (top, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_y),
				hint = "0.05",
			},
			{
				description = _("W (width, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_w),
				hint = "0.54",
			},
			{
				description = _("H (height, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_h),
				hint = "0.9",
			},
		},
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Default"),
					callback = function()
						local new_default = self:readZoneFromDialog(dialog)
						G_reader_settings:saveSetting("dictionary_mode_default_tap_zone", new_default)
						self:setTapZoneType("default")
						UIManager:close(dialog)
						if on_applied then
							on_applied()
						end
					end,
				},
				{
					text = _("Apply"),
					is_enter_default = true,
					callback = function()
						self:setTapZoneType("custom", self:readZoneFromDialog(dialog))
						UIManager:close(dialog)
						if on_applied then
							on_applied()
						end
					end,
				},
			},
		},
	}
	UIManager:show(dialog)
end

function DictionaryMode:registerTap()
	if not self:isEnabled() then
		if self.ui and self.ui.unRegisterTouchZones then
			pcall(function()
				self.ui:unRegisterTouchZones({
					{ id = "dictionarymode_tap" },
				})
			end)
		end
		return
	end
	local r = self:getContentRect()
	local zone_type = self:getTapZoneType(r)
	local screen_zone
	if zone_type == "auto" or zone_type == "text" then
		if r.vpc and r.vpc > 1 then
			screen_zone = {
				ratio_x = 0,
				ratio_y = 0,
				ratio_w = 1,
				ratio_h = 1,
			}
		else
			local zone = self:getContentTapZone(r)
			screen_zone = {
				ratio_x = zone.ratio_x,
				ratio_y = zone.ratio_y,
				ratio_w = zone.ratio_w,
				ratio_h = zone.ratio_h,
			}
		end
	else
		local zone = (zone_type == "custom" and self:getCustomTapZone()) or self:getDefaultTapZone()
		screen_zone = {
			ratio_x = zone.ratio_x,
			ratio_y = zone.ratio_y,
			ratio_w = zone.ratio_w,
			ratio_h = zone.ratio_h,
		}
	end
	self.ui:registerTouchZones({
		{
			id = "dictionarymode_tap",
			ges = "tap",
			screen_zone = screen_zone,
			overrides = {
				"tap_top_left_corner",
				"tap_top_right_corner",
				"tap_left_bottom_corner",
				"tap_right_bottom_corner",
				"readerfooter_tap",
				"readerconfigmenu_ext_tap",
				"readerconfigmenu_tap",
				"readermenu_ext_tap",
				"readermenu_tap",
				"tap_forward",
				"tap_backward",
			},
			handler = function(ges)
				return self:onTap(nil, ges)
			end,
		},
	})	
end

function DictionaryMode:onReaderReady()
    if self:isEnabled() then
        self:registerTap()
        self:registerHold()
    end
    self:updateInnerGap(true)
end

function DictionaryMode:onSetDimensions()
    self:updateInnerGap(true)
    if self:isEnabled() then
        self:registerTap()
        self:registerHold()
    end
end

function DictionaryMode:onSetVisiblePages()
    self:updateInnerGap(true)
end

function DictionaryMode:onChangeViewMode()
    self:updateInnerGap(true)
end

function DictionaryMode:onDocumentRerendered()
    self:updateInnerGap(false)
    if self:isEnabled() then
        self:registerTap()
        self:registerHold()
    end
end

function DictionaryMode:onUpdatePos()
    self:updateInnerGap(false)
end

function DictionaryMode:onCloseDocument()
    self:teardownInnerGap()
end

local function trimmedSingleWord(text)
	text = (text or ""):match("^%s*(.-)%s*$") or ""
	if text == "" or text:find("%s") then
		return nil
	end
	return text
end

function DictionaryMode:cleanupSelectedText(text)
	text = text:gsub("^[\n%s]*", "")
	text = text:gsub("[\n%s]*$", "")
	text = text:gsub("%s*\n%s*", "\n")
	text = text:gsub("%s%s+", " ")
	return text
end

function DictionaryMode:onTap(_, ges)
	if not self:isEnabled() then
		return false
	end
	local zone_type = self:getTapZoneType()
	local pos = self.view:screenToPageTransform(ges.pos)
	if not pos then
		return false
	end
	local function miss()
		if self.ui.document.clearSelection then
			self.ui.document:clearSelection()
		end
		return false
	end
	local function try_word()
		local ok, word = pcall(function()
			return self.ui.document:getWordFromPosition(pos, true)
		end)
		if not ok or not word or not word.word or word.word == "" then
			return miss()
		end
		local text = trimmedSingleWord(word.word)
		if not text then
			return miss()
		end
		if not self:tapHitsWord(ges, word, pos) then
			return miss()
		end
		return self:lookupSelection({
			text = text,
			pos0 = word.pos0 or word.pos,
			pos1 = word.pos1 or word.pos,
			sboxes = word.sbox and { word.sbox } or nil,
		})
	end
	if zone_type == "text" then
		if not self:isInContentArea(ges.pos) then
			return miss()
		end
		return try_word()
	end
	if zone_type == "auto" then
		if not self:isInContentArea(ges.pos) then
			return miss()
		end
		local ok, selection = pcall(function()
			return self.ui.document:getTextFromPositions(pos, pos, true)
		end)
		if ok and selection and selection.text then
			local text = trimmedSingleWord(selection.text)
			if text then
				selection.text = text
				return self:lookupSelection(selection)
			end
		end
		local ok2, word = pcall(function()
			return self.ui.document:getWordFromPosition(pos, true)
		end)
		if ok2 and word and word.word then
			local text = trimmedSingleWord(word.word)
			if text then
				return self:lookupSelection({
					text = text,
					pos0 = word.pos0 or word.pos,
					pos1 = word.pos1 or word.pos,
					sboxes = word.sbox and { word.sbox } or nil,
				})
			end
		end
		return miss()
	end
	local ok, selection = pcall(function()
		return self.ui.document:getTextFromPositions(pos, pos, true)
	end)
	if not ok or not selection or not selection.text then
		return miss()
	end
	local text = trimmedSingleWord(selection.text)
	if not text then
		return miss()
	end
	selection.text = text
	return self:lookupSelection(selection)
end

return DictionaryMode
