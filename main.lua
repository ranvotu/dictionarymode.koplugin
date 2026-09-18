local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULT_TAP_ZONE = {
    ratio_x = 0.23,
    ratio_y = 0.05,
    ratio_w = 0.54,
    ratio_h = 0.9,
}

local DictionaryMode = WidgetContainer:extend{
    name = "dictionarymode",
    is_doc_only = true,
}

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
end

function DictionaryMode:isEnabled()
    return G_reader_settings:isTrue("enable_dictionary_mode")
end

function DictionaryMode:toggle()
    G_reader_settings:saveSetting("enable_dictionary_mode", not self:isEnabled())
end

function DictionaryMode:getTapZoneType()
    return G_reader_settings:readSetting("dictionary_mode_tap_zone_type", "default")
end

function DictionaryMode:setTapZoneType(zone_type, zone)
    G_reader_settings:saveSetting("dictionary_mode_tap_zone_type", zone_type)
    if zone then
        G_reader_settings:saveSetting("dictionary_mode_tap_zone", zone)
    end
    self:registerTap()
end

function DictionaryMode:getContentRect()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local left, top, right, bottom = 0, 0, 0, 0
    local doc = self.ui.document

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

    if left < 0 then left = 0 end
    if top < 0 then top = 0 end
    if right < 0 then right = 0 end
    if bottom < 0 then bottom = 0 end

    local w = sw - left - right
    local h = sh - top - bottom
    if w < 0 then w = 0 end
    if h < 0 then h = 0 end

    return {
        x = left,
        y = top,
        w = w,
        h = h,
        sw = sw,
        sh = sh,
        left = left,
        right = right,
        vpc = (doc and doc.getVisiblePageCount and doc:getVisiblePageCount()) or 1,
    }
end

function DictionaryMode:getContentTapZone()
    local r = self:getContentRect()
    if r.sw <= 0 or r.sh <= 0 or r.w <= 0 or r.h <= 0 then
        return DEFAULT_TAP_ZONE
    end
    local zone = {
        ratio_x = r.x / r.sw,
        ratio_y = r.y / r.sh,
        ratio_w = r.w / r.sw,
        ratio_h = r.h / r.sh,
    }
    if zone.ratio_x < 0 then zone.ratio_x = 0 end
    if zone.ratio_y < 0 then zone.ratio_y = 0 end
    if zone.ratio_x + zone.ratio_w > 1 then
        zone.ratio_w = 1 - zone.ratio_x
    end
    if zone.ratio_y + zone.ratio_h > 1 then
        zone.ratio_h = 1 - zone.ratio_y
    end
    if zone.ratio_w < 0.2 then zone.ratio_w = 0.2 end
    if zone.ratio_h < 0.2 then zone.ratio_h = 0.2 end
    return zone
end

function DictionaryMode:isInContentArea(pos)
    local r = self:getContentRect()
    if r.w <= 0 or r.h <= 0 then
        return false
    end
    if pos.x < r.x or pos.x > r.x + r.w then
        return false
    end
    if pos.y < r.y or pos.y > r.y + r.h then
        return false
    end
    -- Two-page mode: middle gutter is treated as margin (page turns)
    if r.vpc and r.vpc > 1 then
        local mid = r.sw / 2
        if pos.x > mid - r.right and pos.x < mid + r.left then
            return false
        end
    end
    return true
end

function DictionaryMode:getTapZone()
    local zone_type = self:getTapZoneType()
    if zone_type == "auto" then
        return self:getContentTapZone()
    end
    if zone_type == "custom" then
        local zone = G_reader_settings:readSetting("dictionary_mode_tap_zone")
        if zone then
            return zone
        end
    end
    return DEFAULT_TAP_ZONE
end

function DictionaryMode:formatTapZone(zone)
    return T("x=%1  y=%2  w=%3  h=%4",
        zone.ratio_x, zone.ratio_y, zone.ratio_w, zone.ratio_h)
end

function DictionaryMode:addToMainMenu(menu_items)
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
                separator = true,
            },
            {
                text = _("Tap zone"),
            },
            {
                text_func = function()
                    return T(_("Auto, text area (%1)"), self:formatTapZone(self:getContentTapZone()))
                end,
                checked_func = function()
                    return self:getTapZoneType() == "auto"
                end,
                radio = true,
                callback = function()
                    self:setTapZoneType("auto")
                end,
            },
            {
                text_func = function()
                    return T(_("Default (%1)"), self:formatTapZone(DEFAULT_TAP_ZONE))
                end,
                checked_func = function()
                    return self:getTapZoneType() == "default"
                end,
                radio = true,
                callback = function()
                    self:setTapZoneType("default")
                end,
            },
            {
                text_func = function()
                    local zone = G_reader_settings:readSetting("dictionary_mode_tap_zone") or DEFAULT_TAP_ZONE
                    return T(_("Custom (%1)"), self:formatTapZone(zone))
                end,
                checked_func = function()
                    return self:getTapZoneType() == "custom"
                end,
                radio = true,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showCustomTapZoneDialog(function()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
        },
    }
end

function DictionaryMode:onDictionaryMode()
    self:toggle()
    local text = _("Dictionary mode disabled")
    if G_reader_settings:isTrue("enable_dictionary_mode") then
        text = _("Dictionary mode enabled")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 1,
    })
end

function DictionaryMode:enableWithNotice()
    if not self:isEnabled() then
        G_reader_settings:saveSetting("enable_dictionary_mode", true)
    end
    UIManager:show(InfoMessage:new{
        text = _("Dictionary mode enabled"),
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
    if n < 0 then n = 0 end
    if n > 1 then n = 1 end
    return n
end

function DictionaryMode:showCustomTapZoneDialog(on_applied)
    local zone = G_reader_settings:readSetting("dictionary_mode_tap_zone") or DEFAULT_TAP_ZONE
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Custom tap zone"),
        fields = {
            {
                description = _("X (left, 0–1 or %)"),
                input_type = "number",
                text = tostring(zone.ratio_x),
                hint = "0.23",
            },
            {
                description = _("Y (top, 0–1 or %)"),
                input_type = "number",
                text = tostring(zone.ratio_y),
                hint = "0.05",
            },
            {
                description = _("W (width, 0–1 or %)"),
                input_type = "number",
                text = tostring(zone.ratio_w),
                hint = "0.54",
            },
            {
                description = _("H (height, 0–1 or %)"),
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
                        self:setTapZoneType("default")
                        UIManager:close(dialog)
                        if on_applied then on_applied() end
                    end,
                },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local custom = {
                            ratio_x = self:parseRatio(fields[1], DEFAULT_TAP_ZONE.ratio_x),
                            ratio_y = self:parseRatio(fields[2], DEFAULT_TAP_ZONE.ratio_y),
                            ratio_w = self:parseRatio(fields[3], DEFAULT_TAP_ZONE.ratio_w),
                            ratio_h = self:parseRatio(fields[4], DEFAULT_TAP_ZONE.ratio_h),
                        }
                        if custom.ratio_x + custom.ratio_w > 1 then
                            custom.ratio_w = 1 - custom.ratio_x
                        end
                        if custom.ratio_y + custom.ratio_h > 1 then
                            custom.ratio_h = 1 - custom.ratio_y
                        end
                        self:setTapZoneType("custom", custom)
                        UIManager:close(dialog)
                        if on_applied then on_applied() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DictionaryMode:registerTap()
    local zone = self:getTapZone()
    self.ui:registerTouchZones({
        {
            id = "dictionarymode_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = zone.ratio_x,
                ratio_y = zone.ratio_y,
                ratio_w = zone.ratio_w,
                ratio_h = zone.ratio_h,
            },
            overrides = {
                "readerhighlight_tap",
            },
            handler = function(ges) return self:onTap(nil, ges) end,
        },
    })
end

function DictionaryMode:onReaderReady()
    self:registerTap()
end

function DictionaryMode:onSetDimensions()
    if self:getTapZoneType() == "auto" then
        self:registerTap()
    end
end

function DictionaryMode:onDocumentRerendered()
    if self:getTapZoneType() == "auto" then
        self:registerTap()
    end
end

function DictionaryMode:cleanupSelectedText(text)
    text = text:gsub("^[\n%s]*", "")
    text = text:gsub("[\n%s]*$", "")
    text = text:gsub("%s*\n%s*", "\n")
    text = text:gsub("%s%s+", " ")
    return text
end

function DictionaryMode:onTap(_, ges)
    if G_reader_settings:nilOrFalse("enable_dictionary_mode") then
        return false
    end
    if self:getTapZoneType() == "auto" and not self:isInContentArea(ges.pos) then
        return false
    end
    local pos = self.view:screenToPageTransform(ges.pos)
    local selection = self.ui.document:getTextFromPositions(pos, pos)
    if not selection then
        return false
    end
    if string.find(selection.text, " ") then
        return false
    end
    if self.ui.languagesupport and self.ui.languagesupport:hasActiveLanguagePlugins() then
        local new_selection = self.ui.languagesupport:improveWordSelection(selection)
        if new_selection then
            selection = new_selection
        end
    end
    self.ui:handleEvent(Event:new("LookupWord", self:cleanupSelectedText(selection.text)))
    self.ui.document:clearSelection()
    return true
end

return DictionaryMode
