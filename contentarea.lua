-- Content-area geometry for Dictionary Mode (margins, 2-column, pad).
-- Used by tap zones and by Rest my finger.

local Screen = require("device").screen

-- Nới thêm khung chạm (Auto/Pixel) ra ngoài margin chữ, trái/phải; trên/dưới (px).
local HORIZONTAL_TAP_PAD = Screen:scaleBySize(20)
local VERTICAL_TAP_PAD = Screen:scaleBySize(0)
-- Kích thước tối thiểu (tỉ lệ màn) để vùng chạm không co về 0.
local MIN_ZONE_RATIO = 0.2

local ContentArea = {}

ContentArea.HORIZONTAL_TAP_PAD = HORIZONTAL_TAP_PAD
ContentArea.VERTICAL_TAP_PAD = VERTICAL_TAP_PAD
ContentArea.MIN_ZONE_RATIO = MIN_ZONE_RATIO

--- Attach geometry methods onto the plugin class.
function ContentArea.install(DictionaryMode)
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
				local ok, x = pcall(function()
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
		if left < 0 then left = 0 end
		if top < 0 then top = 0 end
		if right < 0 then right = 0 end
		if bottom < 0 then bottom = 0 end
		local zone_left = math.max(0, left - HORIZONTAL_TAP_PAD)
		local zone_right = math.max(0, right - HORIZONTAL_TAP_PAD)
		local zone_top = math.max(0, top - VERTICAL_TAP_PAD)
		local zone_bottom = math.max(0, bottom - VERTICAL_TAP_PAD)
		local w = sw - zone_left - zone_right
		local h = sh - zone_top - zone_bottom
		if w < 0 then w = 0 end
		if h < 0 then h = 0 end
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
			page2_x = page2_x,
		}
	end

	-- Default/Custom only when 1 page and L/R margins symmetrical.
	function DictionaryMode:isFixedTapZoneAllowed(r)
		r = r or self:getContentRect()
		if r.vpc and r.vpc > 1 then
			return false
		end
		return math.abs(r.left - r.right) <= 1
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
		if zone.ratio_x < 0 then zone.ratio_x = 0 end
		if zone.ratio_y < 0 then zone.ratio_y = 0 end
		if zone.ratio_w < MIN_ZONE_RATIO then zone.ratio_w = MIN_ZONE_RATIO end
		if zone.ratio_h < MIN_ZONE_RATIO then zone.ratio_h = MIN_ZONE_RATIO end
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
		if not pos then
			return false
		end
		local r = self:getContentRect()
		if r.w <= 0 or r.h <= 0 then
			return false
		end
		if r.body_bottom and pos.y >= r.body_bottom then return false end
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
			local left_x0 = r.x - slop
			local right_x1 = r.x + r.w + slop
			local left_x1 = left_rect_right - r.right + pad + slop
			local right_x0 = page2 + r.left - pad - slop
			if left_x1 > right_x0 then
				local mid = (left_x1 + right_x0) / 2
				left_x1 = mid
				right_x0 = mid
			end
			-- InnerGap supplies the actual displayed edges. Outer padding stays,
			-- but the blank gutter must never become a content/hold zone.
			local in_left = pos.x >= left_x0 and pos.x <= left_x1
				and (not r.inner_left or pos.x < r.inner_left)
			local in_right = pos.x >= right_x0 and pos.x <= right_x1
				and (not r.inner_right or pos.x >= r.inner_right)
			return in_left or in_right
		end
		return pos.x >= (r.x - slop) and pos.x <= (r.x + r.w + slop)
	end
end

return ContentArea
