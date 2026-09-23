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
local FACTORY_TAP_ZONE = {
	ratio_x = 0.23,
	ratio_y = 0.05,
	ratio_w = 0.54,
	ratio_h = 0.9
}
-- Nới thêm khung chạm (Auto/Pixel) ra ngoài margin chữ, 
-- trái/phải; trên/dưới (đơn vị pixel).
local HORIZONTAL_TAP_PAD = Screen:scaleBySize(20)
local VERTICAL_TAP_PAD = Screen:scaleBySize(0)
-- Kích thước tối thiểu (theo tỉ lệ màn hình) của một vùng chạm,
-- để vùng không bao giờ co về 0 và trở nên không chạm được.
local MIN_ZONE_RATIO = 0.2
-- Tên các key cài đặt vùng chạm. Kiểu vùng chạm và vùng Custom được lưu
-- THEO TỪNG SÁCH (doc_settings). Vùng Default là mẫu dùng chung, lưu toàn cục.
local TAP_ZONE_TYPE_KEY = "dictionary_mode_tap_zone_type"
local CUSTOM_ZONE_KEY = "dictionary_mode_tap_zone"
local DictionaryMode = WidgetContainer:extend{
	name = "dictionarymode",
	is_doc_only = true
}
function DictionaryMode:onDispatcherRegisterActions()
	Dispatcher:registerAction("dictionarymode_action", {
		category = "none",
		event = "DictionaryMode",
		title = _("Dictionary Mode"),
		general = true
	})
end
function DictionaryMode:init()
	self:onDispatcherRegisterActions()
	self.ui.menu:registerToMainMenu(self)
	self:registerTap()
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
end

-- Đọc/ghi setting theo từng sách (doc_settings).
-- Nếu vì lý do nào đó không có doc_settings thì dùng cài đặt toàn cục,
-- và cả đọc lẫn ghi đều đi qua cùng một chỗ nên luôn nhất quán.
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

-- Lựa chọn của người dùng đã được lưu cho sách này.
-- Sách chưa từng chọn thì lấy giá trị toàn cục cũ (giữ nguyên lựa chọn
-- của người dùng trước khi có bản sửa này), cuối cùng mới là "default".
-- Bố cục (1 cột / 2 cột, lề...) KHÔNG được phép làm thay đổi giá trị này;
-- nó chỉ đổi khi người dùng chủ động chọn trong menu.
function DictionaryMode:getStoredTapZoneType()
	local zone_type = self:readBookSetting(TAP_ZONE_TYPE_KEY)
	if zone_type == nil then
		zone_type = G_reader_settings:readSetting(TAP_ZONE_TYPE_KEY, "default")
	end
	return zone_type
end

-- Vùng Custom của sách này (nil nếu chưa từng đặt).
-- Sách chưa đặt thì lấy vùng Custom toàn cục cũ, nếu có.
function DictionaryMode:getCustomTapZone()
	return self:readBookSetting(CUSTOM_ZONE_KEY) or G_reader_settings:readSetting(CUSTOM_ZONE_KEY)
end

-- Chế độ vùng chạm thực sự được áp dụng cho bố cục hiện tại.
-- Chỉ tính toán, không ghi gì vào settings. Nhờ vậy:
--   * sách này không làm thay đổi cài đặt của sách khác,
--   * quay lại 1 cột thì Default/Custom tự trở lại.
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
end
function DictionaryMode:getDefaultTapZone()
	return G_reader_settings:readSetting("dictionary_mode_default_tap_zone") or FACTORY_TAP_ZONE
end
function DictionaryMode:getContentRect()
	local sw, sh = Screen:getWidth(), Screen:getHeight()
	local left, top, right, bottom = 0, 0, 0, 0
	local doc = self.ui.document
	local vpc = (doc and doc.getVisiblePageCount and doc:getVisiblePageCount()) or 1
	local page2_x = 0
	if doc and doc.getPageMargins then
		local m = doc:getPageMargins()
		if m then
			left = m.left or 0
			top = m.top or 0
			right = m.right or 0
			bottom = m.bottom or 0
		end
		if doc.getHeaderHeight then
			top = top + (doc:getHeaderHeight() or 0)
		end
		if vpc > 1 and doc.getPageOffsetX and doc.getCurrentPage then
			local ok, x = pcall(
                function()
				return doc:getPageOffsetX(doc:getCurrentPage(true) + 1)
			end)
			if ok and type(x) == "number" and x > 0 then
				page2_x = x
			else
				page2_x = math.floor(sw / 2)
			end
		end
	elseif self.ui.paging and self.view.getScreenPageArea then
		local page = self.view.state and self.view.state.page
		local area = self.view:getScreenPageArea(page)
		if area then
			left = area.x or 0
			top = area.y or 0
			right = sw - left - (area.w or sw)
			bottom = sh - top - (area.h or sh)
		end
	end
	if left < 0 then
		left = 0
	end
	if top < 0 then
		top = 0
	end
	if right < 0 then
		right = 0
	end
	if bottom < 0 then
		bottom = 0
	end
	local zone_left = math.max(0, left - HORIZONTAL_TAP_PAD)
	local zone_right = math.max(0, right - HORIZONTAL_TAP_PAD)
	local zone_top = math.max(0, top - VERTICAL_TAP_PAD)
	local zone_bottom = math.max(0, bottom - VERTICAL_TAP_PAD)
	local w = sw - zone_left - zone_right
	local h = sh - zone_top - zone_bottom
	if w < 0 then
		w = 0
	end
	if h < 0 then
		h = 0
	end
	return {
		x = zone_left,
		y = zone_top,
		w = w,
		h = h,
		sw = sw,
		sh = sh,
		left = left,
		right = right,
		vpc = vpc,
		page2_x = page2_x
	}
end

-- Default/Custom tap zones only make sense when there is one page
-- and the left/right margins are symmetrical.
function DictionaryMode:isFixedTapZoneAllowed(r)
	r = r or self:getContentRect()
	if r.vpc and r.vpc > 1 then
		return false
	end
	local tolerance = 1
	return math.abs(r.left - r.right) <= tolerance
end
function DictionaryMode:isFixedZoneMenuEnabled()
	return self:isEnabled() and self:isFixedTapZoneAllowed()
end
function DictionaryMode:getContentTapZone(r)
	r = r or self:getContentRect()
	if r.sw <= 0 or r.sh <= 0 or r.w <= 0 or r.h <= 0 then
		return self:getDefaultTapZone()
	end
	local zone = {
		ratio_x = r.x / r.sw,
		ratio_y = r.y / r.sh,
		ratio_w = r.w / r.sw,
		ratio_h = r.h / r.sh,
	}
	if zone.ratio_x < 0 then
		zone.ratio_x = 0
	end
	if zone.ratio_y < 0 then
		zone.ratio_y = 0
	end
	if zone.ratio_w < MIN_ZONE_RATIO then
		zone.ratio_w = MIN_ZONE_RATIO
	end
	if zone.ratio_h < MIN_ZONE_RATIO then
		zone.ratio_h = MIN_ZONE_RATIO
	end
	if zone.ratio_x + zone.ratio_w > 1 then
		zone.ratio_x = math.max(0, 1 - zone.ratio_w)
		zone.ratio_w = 1 - zone.ratio_x
	end
	if zone.ratio_y + zone.ratio_h > 1 then
		zone.ratio_y = math.max(0, 1 - zone.ratio_h)
		zone.ratio_h = 1 - zone.ratio_y
	end
	return zone
end
function DictionaryMode:isInContentArea(pos)
    local r = self:getContentRect()
    if r.w <= 0 or r.h <= 0 then
        return false
    end
    local slop = Screen:scaleBySize(12)
    if pos.y < r.y - slop or pos.y > r.y + r.h + slop then
        return false
    end
    if r.vpc and r.vpc > 1 then
        local page2 = r.page2_x
        if not page2 or page2 <= 0 then
            page2 = math.floor(r.sw / 2)
        end
        local left_rect_right = r.sw - page2
        local pad = HORIZONTAL_TAP_PAD
        -- ngoài: r.x / r.x+r.w đã có pad
        local left_x0 = r.x - slop
        local right_x1 = r.x + r.w + slop
        -- trong: nới vào rãnh (pad + slop, cùng 1 cột)
        local left_x1 = left_rect_right - r.right + pad + slop
        local right_x0 = page2 + r.left - pad - slop
        if left_x1 > right_x0 then
            local mid = (left_x1 + right_x0) / 2
            left_x1 = mid
            right_x0 = mid
        end
        local in_left = pos.x >= left_x0 and pos.x <= left_x1
        local in_right = pos.x >= right_x0 and pos.x <= right_x1
        return in_left or in_right
    end
    return pos.x >= (r.x - slop) and pos.x <= (r.x + r.w + slop)
end
function DictionaryMode:formatTapZone(zone, short)
	if short then
		return T("x=%1 y=%2 w=%3 h=%4", string.format("%.2f", zone.ratio_x), string.format("%.2f", zone.ratio_y), string.format("%.2f", zone.ratio_w), string.format("%.2f", zone.ratio_h))
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
	local _1 = _("Unavailable in two-column view & uneven margins.")
	menu_items.dictionarymode = {
		text = _("Dictionary Mode"),
		sorting_hint = "taps_and_gestures",
		sub_item_table = {
			{
				text = _("Enable dictionary mode"),
				checked_func = function()
					return self:isEnabled()
				end,
				callback = function()
					self:toggle()
				end,
				separator = true
			},
			{
				text = _("Tap zone")
			},
			{
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
				callback = function()
					self:setTapZoneType("auto")
				end
			},
			{
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
						return _1
					end
					return nil
				end,
				callback = function()
					self:setTapZoneType("default")
				end,
				hold_callback = function(touchmenu_instance)
        -- restore factory (chỉ khi không xám; xám thì KOReader hiện help_text_func)
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
			},
			{
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
						return _1
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
			},
			{
				text = _("Pixel"),
				enabled_func = function()
					return self:isEnabled()
				end,
				checked_func = function()
					return self:getTapZoneType() == "text"
				end,
				radio = true,
				callback = function()
					self:setTapZoneType("text")
				end
			}
		}
	}
end
function DictionaryMode:onDictionaryMode()
	self:toggle()
	local text = _("Dictionary mode disabled")
	if self:isEnabled() then
		text = _("Dictionary mode enabled")
	end
	UIManager:show(
		InfoMessage:new{
		text = text,
		timeout = 1
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

-- Đưa một trục (x/w hoặc y/h) về khoảng hợp lệ:
--   * không tràn ra ngoài màn hình,
--   * kích thước không nhỏ hơn MIN_ZONE_RATIO (nếu cần thì dịch vị trí vào trong).
local function fitZoneAxis(pos, size)
	if pos + size > 1 then
		size = 1 - pos
	end
	if size < MIN_ZONE_RATIO then
		size = MIN_ZONE_RATIO
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
		ratio_h = h
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
function CenteredMultiInputDialog:onShowKeyboard( ...)
	MultiInputDialog.onShowKeyboard(self, ...)
	if self[1] and self[1].dimen then
		self[1].dimen.h = self.with_keyboard_h or (Screen:getHeight() - (self._input_widget:getKeyboardDimen().h or 0))
		self[1].ignore = nil
		UIManager:setDirty(nil, "ui")
	end
end
function CenteredMultiInputDialog:onCloseKeyboard( ...)
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
				hint = "0.23"
			},
			{
				description = _("Y (top, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_y),
				hint = "0.05"
			},
			{
				description = _("W (width, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_w),
				hint = "0.54"
			},
			{
				description = _("H (height, 0 -> 1 or %)"),
				input_type = "number",
				text = tostring(zone.ratio_h),
				hint = "0.9"
			}
		},
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end
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
					end
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
					end
				}
			}
		}
	}
	UIManager:show(dialog)
end
function DictionaryMode:registerTap()
	if not self:isEnabled() then
		if self.ui and self.ui.unRegisterTouchZones then
			pcall(function()
				self.ui:unRegisterTouchZones({
					{
						id = "dictionarymode_tap"
					},
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
	end
end
function DictionaryMode:onSetDimensions()
    -- Layout (1 column <-> 2 columns, rotation...) may have changed.
    -- The effective zone type is recomputed in getTapZoneType().
	if self:isEnabled() then
		self:registerTap()
	end
end
function DictionaryMode:onDocumentRerendered()
    -- Margins can change after a document rerender, so register again.
	if self:isEnabled() then
		self:registerTap()
	end
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
		local ok, word = pcall(
            function()
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
		return self:lookupSelection(
            {
			text = text,
			pos0 = word.pos0 or word.pos,
			pos1 = word.pos1 or word.pos,
			sboxes = word.sbox and {
				word.sbox
			} or nil
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
		local ok, selection = pcall(
            function()
			return self.ui.document:getTextFromPositions(pos, pos, true)
		end)
		if ok and selection and selection.text then
			local text = trimmedSingleWord(selection.text)
			if text then
				selection.text = text
				return self:lookupSelection(selection)
			end
		end

        -- fallback
		local ok2, word = pcall(
            function()
			return self.ui.document:getWordFromPosition(pos, true)
		end)
		if ok2 and word and word.word then
			local text = trimmedSingleWord(word.word)
			if text then
				return self:lookupSelection(
                    {
					text = text,
					pos0 = word.pos0 or word.pos,
					pos1 = word.pos1 or word.pos,
					sboxes = word.sbox and {
						word.sbox
					} or nil
				})
			end
		end
		return miss()
	end
	local ok, selection = pcall(
        function()
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
