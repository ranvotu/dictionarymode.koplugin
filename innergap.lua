-- Lua-only inner gap for CREngine's two-column rolling view.
--
-- CREngine needs a narrower layout to reflow each column correctly. We add
-- the same temporary amount to both page margins, then move the rendered
-- left and right text columns back out by that amount. The original margins
-- are kept as the source of truth and restored whenever this mode is inactive.

local Blitbuffer = require("ffi/blitbuffer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local ContentArea = require("contentarea")
local CreDocument = require("document/credocument")

-- Current CreDocument:drawCurrentView() only blits its cached self.buffer to
-- the supplied target. This sink lets us reuse that native buffer without a
-- temporary full-screen copy; guarded by an exact method identity check below.
local DRAW_SINK = {
	blitFrom = function(sink, source, x, y, src_x, src_y, width, height)
		sink.calls = sink.calls + 1
		sink.valid = sink.valid and sink.calls == 1
			and x == sink.x and y == sink.y and src_x == 0 and src_y == 0
			and width == sink.width and height == sink.height
		sink.source = sink.valid and source or nil
	end,
}

-- Shared diagnostic descriptions; built once when this module is loaded.
local DIAGNOSTIC_REASONS = {
	debug_unavailable = _("Draw inspection is unavailable; using the safe drawing path."),
	unrecognized_draw = _("The drawing function is not the stock method or the verified stable cache wrapper. This does not prove an EPUB problem."),
	cache_signature = _("The native cache wrapper differs from the verified signature; using the safe drawing path."),
	sink_contract = _("The fast-path copy did not match the expected single full-buffer copy. Compatibility is remembered for this document and drawing method."),
	sink_error = _("The fast-path drawing attempt failed; drawing on the real target instead."),
	source_is_target = _("The drawing target is also the engine source buffer; direct composition is unsafe."),
	nested_draw = _("Another fast-path draw is in progress; using the safe path for this nested call."),
	geometry_changed = _("The current drawing geometry could not be validated; keeping the native image and coordinates."),
	snapshot_failed = _("The completed native image could not be copied for composition; keeping native coordinates."),
	compose_failed = _("Column composition failed; the native image was restored with native coordinates."),
}

local InnerGap = {}

local GAP_SETTING_KEY = "dictionary_mode_inner_gap_px"
local GAP_GRAY_SETTING_KEY = "dictionary_mode_inner_gap_gray"
local GAP_GRAY_AUTO = "auto"
local FIXED_GRAY_COLORS = {}
local MAX_GAP_PX = 400
local MIN_COLUMN_PX = 64

local function cloneMargins(m)
	if not m then return nil end
	local ok, left, top, right, bottom = pcall(function()
		return m.left, m.top, m.right, m.bottom
	end)
	if not ok or type(left) ~= "number" or type(right) ~= "number" then
		return nil
	end
	return {
		left = left,
		top = type(top) == "number" and top or 0,
		right = right,
		bottom = type(bottom) == "number" and bottom or 0,
	}
end

local function getMargins(doc)
	if not doc or not doc.getPageMargins then return nil end
	local ok, margins = pcall(doc.getPageMargins, doc)
	if not ok then return nil end
	return cloneMargins(margins)
end

local function marginsEqual(a, b)
	-- Margin ownership is state, not approximate geometry: even a 1 px user
	-- change must be kept when deciding whether to restore our temporary values.
	return a and b
		and a.left == b.left
		and a.top == b.top
		and a.right == b.right
		and a.bottom == b.bottom
end

local function setMargins(doc, margins)
	if not (doc and doc.setPageMargins and margins) then return false end
	local ok = pcall(doc.setPageMargins, doc,
		math.floor(margins.left), math.floor(margins.top),
		math.floor(margins.right), math.floor(margins.bottom))
	if not ok then return false end
	local actual = getMargins(doc)
	return marginsEqual(actual, margins)
end

-- Match C++ integer division (truncation toward zero) when deriving the
-- pageRects split from LVDocView::updateLayout().
local function truncHalf(n)
	if n < 0 then
		return math.ceil(n / 2)
	end
	return math.floor(n / 2)
end

local function getFontGap(doc)
	if not doc or not doc.getFontSize then return nil end
	local ok, size = pcall(doc.getFontSize, doc)
	if not ok or type(size) ~= "number" then return nil end
	return math.floor(size * 80 / 100)
end

local function hasBackgroundImage()
	local image = G_reader_settings and G_reader_settings:readSetting("cre_background_image")
	return image ~= nil and image ~= false and image ~= ""
end

local function hasFullWidthViewport(self, width)
	local view = self.view
	if not view then return false end
	local area = view.visible_area
	if area and (area.x ~= 0 or area.w ~= width) then return false end
	local offset = view.state and view.state.offset
	if offset and type(offset.x) == "number" and math.abs(offset.x) > 1 then
		return false
	end
	return true
end

local function getPage2X(doc)
	if not (doc and doc.getPageOffsetX and doc.getCurrentPage) then return nil end
	local ok, page2_x = pcall(function()
		return doc:getPageOffsetX(doc:getCurrentPage(true) + 1)
	end)
	if not ok or type(page2_x) ~= "number" then return nil end
	return page2_x
end

-- Return measured text-column geometry for the current two-page CRE layout.
-- The returned edges are local screen coordinates (the first pixel after the
-- left text column and the first pixel of the right text column).
local function getLiveGeometry(self, margins)
	local doc = self.ui and self.ui.document
	if not doc or not margins or self.ui.paging then return nil end
	if not doc.getVisiblePageCount or doc:getVisiblePageCount() < 2 then return nil end

	local width = Screen:getWidth()
	if not width or width <= 0 then return nil end
	if not hasFullWidthViewport(self, width) then return nil end
	local page2_x = getPage2X(doc)
	local font_gap = getFontGap(doc)
	if not page2_x or not font_gap then return nil end
	local mid = math.floor(width / 2)
	local gap = (2 * page2_x + margins.left + margins.right) - (2 * mid)
	local expected_gap = math.max(font_gap, margins.left, margins.right)
	local expected_page2_x = mid + truncHalf(expected_gap - margins.left - margins.right)
	-- Refuse to mutate margins if this KOReader/CREngine build does not match
	-- the geometry contract used by the compositor.
	if math.abs(page2_x - expected_page2_x) > 1 then return nil end

	local left_edge = 2 * mid - page2_x - margins.right
	local right_start = page2_x + margins.left
	gap = right_start - left_edge
	local left_width = left_edge - margins.left
	local right_width = width - margins.right - right_start
	if gap <= 0 or left_width <= 0 or right_width <= 0 then return nil end
	return {
		width = width,
		mid = mid,
		page2_x = page2_x,
		gap = gap,
		left_edge = left_edge,
		right_start = right_start,
		left_width = left_width,
		right_width = right_width,
	}
end

-- Check required entry points before changing the engine layout. Presence does
-- not prove unchanged semantics; geometry and render contracts still apply.
local function getMissingCapability(self)
	local ui = self.ui or {}
	local required = {
		{ui.document, {"getPageMargins", "setPageMargins", "getVisiblePageCount", "getFontSize", "getPageOffsetX", "drawCurrentView"}},
		{self.view, {"screenToPageTransform", "pageToScreenTransform", "drawHighlightRect", "drawXPointerSavedHighlight"}},
		{ui.highlight, {"onHold", "highlightWordAtCoordinates"}},
		{ui.link, {"getLinkFromGes"}},
	}
	for _, entry in ipairs(required) do
		for _, name in ipairs(entry[2]) do
			if not entry[1] or type(entry[1][name]) ~= "function" then return name end
		end
	end
end

local function getBaselineGeometry(self, margins, current_margins)
	local doc = self.ui and self.ui.document
	if not doc or self.ui.paging then return nil end
	if not doc.getVisiblePageCount or doc:getVisiblePageCount() < 2 then return nil end
	local width = Screen:getWidth()
	local font_gap = getFontGap(doc)
	if not width or width <= 0 or not font_gap then return nil end
	if not hasFullWidthViewport(self, width) then return nil end
	local mid = math.floor(width / 2)
	current_margins = current_margins or margins
	local current_gap = math.max(font_gap, current_margins.left, current_margins.right)
	local predicted_current_page2_x = mid + truncHalf(current_gap - current_margins.left - current_margins.right)
	local measured_page2_x = getPage2X(doc)
	if not measured_page2_x or math.abs(measured_page2_x - predicted_current_page2_x) > 1 then
		return nil
	end
	local sum = margins.left + margins.right
	local expected_gap = math.max(font_gap, margins.left, margins.right)
	local predicted_page2_x = mid + truncHalf(expected_gap - sum)
	-- Use the baseline split for geometry. The measured offset above belongs to
	-- current_margins, which may already contain our temporary inflation.
	local left_edge = 2 * mid - predicted_page2_x - margins.right
	local right_start = predicted_page2_x + margins.left
	local left_width = left_edge - margins.left
	local right_width = width - margins.right - right_start
	if right_start <= left_edge or left_width <= 0 or right_width <= 0 then return nil end
	return {
		width = width,
		mid = mid,
		page2_x = predicted_page2_x,
		gap = 2 * predicted_page2_x + sum - 2 * mid,
		left_edge = left_edge,
		right_start = right_start,
		left_width = left_width,
		right_width = right_width,
	}
end

local function chooseShift(self, margins, baseline, requested_gap, font_gap)
	font_gap = font_gap or getFontGap(self.ui.document)
	if not font_gap then return 0 end
	local max_t = math.floor(math.min(requested_gap, baseline.width / 4))
	local min_column = math.max(MIN_COLUMN_PX, math.floor(baseline.width / 10))
	local widest_loss = 2 * math.min(baseline.left_width - min_column, baseline.right_width - min_column)
	if widest_loss <= 0 then return 0 end

	local base_max_margin = math.max(margins.left, margins.right)
	local best, best_added_gap = 0, 0
	for t = 1, max_t do
		local widened_font_gap = math.max(font_gap, base_max_margin + t)
		local inflated_sum = margins.left + margins.right + 2 * t
		local inflated_page2_x = baseline.mid + truncHalf(widened_font_gap - inflated_sum)
		local inflated_gap = 2 * inflated_page2_x + inflated_sum - 2 * baseline.mid
		local added_gap = 2 * t + inflated_gap - baseline.gap
		if added_gap > requested_gap or added_gap > widest_loss then
			break
		end
		best = t
		best_added_gap = added_gap
	end
	return best, best_added_gap
end

local function copyPoint(p, x)
	local q = Geom:new(p):copy()
	q.x = x
	return q
end

local function copyRect(r, x)
	local q = Geom:new(r):copy()
	q.x = x
	return q
end

-- A single rectangle may be a bounding box around multiple word fragments.
-- Map its visual bounds conservatively; segmented drawing is handled below.
local function mapLayoutRectToVisualRect(rect, live, shift)
	local right = rect.x + (rect.w or 0)
	local in_left = rect.x < live.left_edge
	local in_right = right > live.right_start
	if in_left and not in_right then
		-- Padding extending into the old gutter belongs to this same column.
		return copyRect(rect, rect.x - shift)
	elseif in_right and not in_left then
		return copyRect(rect, rect.x + shift)
	elseif in_left and in_right then
		local mapped = copyRect(rect, rect.x - shift)
		mapped.w = (rect.w or 0) + 2 * shift
		return mapped
	end
	return rect
end

local function mapVisualXToLayoutX(x, live, shift)
	local left_visual_edge = live.left_edge - shift
	local right_visual_start = live.right_start + shift
	if x < left_visual_edge then
		return x + shift
	elseif x < live.left_edge then
		return live.left_edge
	elseif x < live.right_start then
		return x
	elseif x < right_visual_start then
		return live.right_start
	end
	return x - shift
end

local function isVisualGapActive(state)
	return state and state.active and not state.draw_unshifted and not Device.screen_saver_mode
end

local function restoreViewHooks(state)
	local view = state.hooked_view
	if not view then return end
	if state.screen_to_page_hook
			and view.screenToPageTransform == state.screen_to_page_hook then
		view.screenToPageTransform = state.original_screen_to_page
		state.screen_to_page_hook = nil
		state.original_screen_to_page = nil
	end
	if state.page_to_screen_hook
			and view.pageToScreenTransform == state.page_to_screen_hook then
		view.pageToScreenTransform = state.original_page_to_screen
		state.page_to_screen_hook = nil
		state.original_page_to_screen = nil
	end
	if not state.screen_to_page_hook and not state.page_to_screen_hook then
		state.hooked_view = nil
	end
end

local function installViewHooks(self, state)
	local view = self.view
	if not view then return end
	if state.hooked_view ~= view then
		restoreViewHooks(state)
		state.view_hook_generation = (state.view_hook_generation or 0) + 1
		state.hooked_view = view
		-- A wrapper left inside another plugin's wrapper is kept inert by its
		-- generation check; never stack a second copy on top of it.
		state.screen_to_page_hook = nil
		state.original_screen_to_page = nil
		state.page_to_screen_hook = nil
		state.original_page_to_screen = nil
	end
	local generation = state.view_hook_generation
	if not state.screen_to_page_hook and view.screenToPageTransform then
		local original = view.screenToPageTransform
		local hook = function(v, pos, ...)
			if generation ~= state.view_hook_generation or state.hooked_view ~= v
					or not isVisualGapActive(state) or not pos or type(pos.x) ~= "number" then
				return original(v, pos, ...)
			end
			local live = getLiveGeometry(self, getMargins(self.ui.document))
			if not live then
				return original(v, pos, ...)
			end
			local mapped_x = mapVisualXToLayoutX(pos.x, live, state.shift)
			-- Clamp points in the expanded blank gutter to its native edges. This
			-- keeps ReaderHighlight hold-pan state non-nil while the finger crosses it.
			return original(v, copyPoint(pos, mapped_x), ...)
		end
		state.original_screen_to_page = original
		state.screen_to_page_hook = hook
		view.screenToPageTransform = hook
	end
	if not state.page_to_screen_hook and view.pageToScreenTransform then
		local original = view.pageToScreenTransform
		local hook = function(v, page, rect, ...)
			local screen_rect = original(v, page, rect, ...)
			if generation ~= state.view_hook_generation or state.hooked_view ~= v
					or not isVisualGapActive(state) or not screen_rect
					or type(screen_rect.x) ~= "number" then
				return screen_rect
			end
			local live = getLiveGeometry(self, getMargins(self.ui.document))
			if not live then return screen_rect end
			return mapLayoutRectToVisualRect(screen_rect, live, state.shift)
		end
		state.original_page_to_screen = original
		state.page_to_screen_hook = hook
		view.pageToScreenTransform = hook
	end
end

local function restoreLinkHook(state)
	local link = state.hooked_link
	if link and state.get_link_from_ges_hook
			and link.getLinkFromGes == state.get_link_from_ges_hook then
		link.getLinkFromGes = state.original_get_link_from_ges
		state.get_link_from_ges_hook = nil
		state.original_get_link_from_ges = nil
	end
	if not state.get_link_from_ges_hook then
		state.hooked_link = nil
	end
end

local function installLinkHooks(self, state)
	local link = self.ui and self.ui.link
	if not link or not link.getLinkFromGes then return end
	if state.hooked_link ~= link then
		restoreLinkHook(state)
		state.link_hook_generation = (state.link_hook_generation or 0) + 1
		state.hooked_link = link
		state.get_link_from_ges_hook = nil
		state.original_get_link_from_ges = nil
	end
	if state.get_link_from_ges_hook then return end
	local original = link.getLinkFromGes
	local generation = state.link_hook_generation
	local hook = function(l, ges, ...)
		if generation ~= state.link_hook_generation or state.hooked_link ~= l
				or not isVisualGapActive(state) or self.ui.paging or not (ges and ges.pos)
				or type(ges.pos.x) ~= "number" then
			return original(l, ges, ...)
		end
		local live = getLiveGeometry(self, getMargins(self.ui.document))
		if not live then
			return original(l, ges, ...)
		end
		local mapped_x = mapVisualXToLayoutX(ges.pos.x, live, state.shift)
		if mapped_x == ges.pos.x then
			return original(l, ges, ...)
		end
		-- ReaderLink's CRE rolling path calls getLinkFromPosition(ges.pos)
		-- directly, bypassing ReaderView:screenToPageTransform(). Pass a copied
		-- gesture so its hit-test sees the original-layout coordinate without
		-- changing the event shared with other gesture handlers.
		local mapped_ges = {}
		for key, value in pairs(ges) do
			mapped_ges[key] = value
		end
		mapped_ges.pos = copyPoint(ges.pos, mapped_x)
		return original(l, mapped_ges, ...)
	end
	state.original_get_link_from_ges = original
	state.get_link_from_ges_hook = hook
	link.getLinkFromGes = hook
end

local function restoreDrawHook(state)
	local doc = state.hooked_doc
	if doc and state.draw_current_view_hook
			and doc.drawCurrentView == state.draw_current_view_hook then
		doc.drawCurrentView = state.original_draw_current_view
		state.draw_current_view_hook = nil
		state.original_draw_current_view = nil
	end
	if not state.draw_current_view_hook then
		state.hooked_doc = nil
	end
end

local function restoreHighlightHooks(state)
	local view = state.hooked_highlight_view
	if not view then return end
	if state.saved_highlight_draw_hook
			and view.drawXPointerSavedHighlight == state.saved_highlight_draw_hook then
		view.drawXPointerSavedHighlight = state.original_saved_highlight_draw
		state.saved_highlight_draw_hook = nil
		state.original_saved_highlight_draw = nil
	end
	if state.highlight_rect_draw_hook
			and view.drawHighlightRect == state.highlight_rect_draw_hook then
		view.drawHighlightRect = state.original_highlight_rect_draw
		state.highlight_rect_draw_hook = nil
		state.original_highlight_rect_draw = nil
	end
	if not state.saved_highlight_draw_hook and not state.highlight_rect_draw_hook then
		state.hooked_highlight_view = nil
	end
end

local function installHighlightHooks(self, state)
	local view = self.view
	if not view then return end
	if state.hooked_highlight_view ~= view then
		restoreHighlightHooks(state)
		state.highlight_hook_generation = (state.highlight_hook_generation or 0) + 1
		state.hooked_highlight_view = view
		state.saved_highlight_draw_hook = nil
		state.original_saved_highlight_draw = nil
		state.highlight_rect_draw_hook = nil
		state.original_highlight_rect_draw = nil
	end
	local generation = state.highlight_hook_generation
	if not state.saved_highlight_draw_hook and view.drawXPointerSavedHighlight then
		local original = view.drawXPointerSavedHighlight
		local hook = function(v, ...)
			if generation ~= state.highlight_hook_generation
					or state.hooked_highlight_view ~= v or not isVisualGapActive(state) then
				return original(v, ...)
			end
			local was_drawing_saved = state.drawing_saved_highlight
			local previous_geometry = state.saved_highlight_geometry
			-- A scope lasts only for this synchronous draw. Nested draws get their
			-- own scope and invalidate the outer snapshot before it resumes.
			state.saved_highlight_geometry = {}
			state.drawing_saved_highlight = true
			local ok, result = pcall(original, v, ...)
			state.drawing_saved_highlight = was_drawing_saved
			state.saved_highlight_geometry = previous_geometry
			if previous_geometry then previous_geometry.ready = false end
			if not ok then
				-- Preserve KOReader's original draw error after clearing our flag.
				error(result, 0)
			end
			return result
		end
		state.original_saved_highlight_draw = original
		state.saved_highlight_draw_hook = hook
		view.drawXPointerSavedHighlight = hook
	end
	if not state.highlight_rect_draw_hook and view.drawHighlightRect then
		local original = view.drawHighlightRect
		local hook = function(v, bb, x, y, rect, drawer, color, draw_note_mark, ...)
			if generation ~= state.highlight_hook_generation
					or state.hooked_highlight_view ~= v
					or not isVisualGapActive(state) or not state.drawing_saved_highlight
					or not rect or type(rect.x) ~= "number" then
				return original(v, bb, x, y, rect, drawer, color, draw_note_mark, ...)
			end
			-- Move only the drawing copy. visible_boxes remains in engine
			-- coordinates because ReaderHighlight transforms taps back to that space.
			local scope = state.saved_highlight_geometry
			local doc = self.ui.document
			local epoch = state.geometry_epoch
			local width = Screen:getWidth()
			local live
			if scope and scope.ready and scope.doc == doc and scope.epoch == epoch
					and scope.width == width and scope.shift == state.shift then
				live = scope.live
			else
				live = getLiveGeometry(self, getMargins(doc))
				if scope then
					scope.ready, scope.doc, scope.epoch = true, doc, epoch
					scope.width, scope.shift, scope.live = width, state.shift, live
				end
			end
			if live then
				local right = rect.x + (rect.w or 0)
				if right > live.left_edge and rect.x < live.right_start then
					-- A box spanning the gutter needs two drawing pieces, not one
					-- widened highlight that would paint over the blank gap.
					local left_w = math.min(right, live.left_edge) - rect.x
					if left_w > 0 then
						local piece = copyRect(rect, rect.x - state.shift)
						piece.w = left_w
						original(v, bb, x, y, piece, drawer, color, draw_note_mark, ...)
					end
					local right_x = math.max(rect.x, live.right_start)
					if right > right_x then
						local piece = copyRect(rect, right_x + state.shift)
						piece.w = right - right_x
						local right_mark = draw_note_mark
						if left_w > 0 and v.highlight.note_mark == "sidemark" then
							-- One original box has only one side-sign, even when split.
							right_mark = false
						end
						original(v, bb, x, y, piece, drawer, color, right_mark, ...)
					end
					return
				end
				rect = mapLayoutRectToVisualRect(rect, live, state.shift)
			end
			return original(v, bb, x, y, rect, drawer, color, draw_note_mark, ...)
		end
		state.original_highlight_rect_draw = original
		state.highlight_rect_draw_hook = hook
		view.drawHighlightRect = hook
	end
end

local function restoreSelectionHooks(state)
	local highlight = state.hooked_selection
	if not highlight then return end
	for name, entry in pairs(state.selection_hooks) do
		if highlight[name] == entry.hook then
			highlight[name] = entry.original
			state.selection_hooks[name] = nil
		end
	end
	if not next(state.selection_hooks) then
		state.hooked_selection = nil
	end
end

local function installSelectionHooks(self, state)
	local highlight = self.ui and self.ui.highlight
	if not highlight then return end
	if state.hooked_selection ~= highlight then
		restoreSelectionHooks(state)
		state.selection_hook_generation = (state.selection_hook_generation or 0) + 1
		state.hooked_selection = highlight
		state.selection_hooks = {}
	end
	local generation = state.selection_hook_generation
	for _, name in ipairs({ "onHold", "highlightWordAtCoordinates" }) do
		if not state.selection_hooks[name] and highlight[name] then
			local original = highlight[name]
			local hook = function(h, ...)
				local previous_selection = h.selected_text
				local result = original(h, ...)
				if generation == state.selection_hook_generation
						and state.hooked_selection == h and isVisualGapActive(state) and result ~= false
						and (result or h.selected_text ~= previous_selection)
						and h.is_word_selection and h.selected_text and h.selected_text.sboxes then
					local live = getLiveGeometry(self, getMargins(self.ui.document))
					if live then
						local boxes = {}
						for i, rect in ipairs(h.selected_text.sboxes) do
							boxes[i] = mapLayoutRectToVisualRect(rect, live, state.shift)
						end
						-- CRE selects the whole word, but ReaderHighlight requests a
						-- refresh at its engine box. Refresh its displayed box too;
						-- otherwise e-ink shows only the overlap until hold-release.
						if #boxes > 0 then
							UIManager:setDirty(h.dialog, "ui", Geom.boundingBox(boxes))
						end
					end
				end
				return result
			end
			state.selection_hooks[name] = { original = original, hook = hook }
			highlight[name] = hook
		end
	end
end

local function restoreHooks(state)
	restoreViewHooks(state)
	restoreDrawHook(state)
	restoreLinkHook(state)
	restoreHighlightHooks(state)
	restoreSelectionHooks(state)
	state.drawing_saved_highlight = false
end

local function freeFrame(state)
	if state.render_frame then
		state.render_frame:free()
		state.render_frame = nil
		state.render_frame_type = nil
	end
end

local function getColorKey(source_type, color)
	if source_type == Blitbuffer.TYPE_BB4 or source_type == Blitbuffer.TYPE_BB8 then
		return color.a
	elseif source_type == Blitbuffer.TYPE_BB8A then
		return color.a * 256 + color.alpha
	elseif source_type == Blitbuffer.TYPE_BBRGB16 then
		return color.v
	elseif source_type == Blitbuffer.TYPE_BBRGB24 then
		return color.r * 65536 + color.g * 256 + color.b
	elseif source_type == Blitbuffer.TYPE_BBRGB32 then
		return ((color.r * 256 + color.g) * 256 + color.b) * 256 + color.alpha
	end
	-- Unknown future formats keep the exact per-row behavior.
	return nil
end

local function getHeaderHeight(doc, view_height)
	if not (doc and doc.getHeaderHeight) then return 0 end
	local ok, height = pcall(doc.getHeaderHeight, doc)
	if not ok or type(height) ~= "number" or height ~= height then return 0 end
	return math.max(0, math.min(view_height, math.floor(height)))
end

local function getFooterHeight(self, view_height)
	local view = self and self.view
	if not (view and view.footer_visible and view.footer and view.footer.getHeight) then return 0 end
	local ok, height = pcall(view.footer.getHeight, view.footer)
	if not ok or type(height) ~= "number" or height ~= height then return 0 end
	return math.max(0, math.min(view_height, math.floor(height)))
end

local function composeShiftedView(source, target, x, y, rect, margins, live, t, header_height, footer_height, fixed_gray_level)
	if not source or source == target or source.w ~= rect.w or source.h ~= rect.h then
		return false
	end
	local left_width = live.left_edge - margins.left
	local right_width = rect.w - margins.right - live.right_start
	local old_gap_width = live.right_start - live.left_edge
	local left_outer_width = margins.left - t
	local right_outer_width = margins.right - t
	local gap_left = live.left_edge - t
	local gap_right = live.right_start + t
	if left_width <= 0 or right_width <= 0 or old_gap_width <= 0
			or left_outer_width < 0 or right_outer_width < 0
			or gap_left < left_outer_width or gap_right > rect.w - right_outer_width then
		return false
	end

	header_height = math.max(0, math.min(rect.h, math.floor(tonumber(header_height) or 0)))
	footer_height = math.max(0, math.min(rect.h - header_height, math.floor(tonumber(footer_height) or 0)))
	local footer_y = rect.h - footer_height
	if header_height > 0 then
		-- CREngine draws its page header into this same buffer. Keep it at its
		-- original screen coordinates.
		target:blitFrom(source, x, y, 0, 0, rect.w, header_height)
	end
	local body_y = header_height
	local body_h = footer_y - body_y
	if body_h <= 0 then
		if footer_height > 0 then
			target:blitFrom(source, x, y + footer_y, 0, footer_y, rect.w, footer_height)
		end
		return true
	end

	-- These disjoint body rectangles cover the output width exactly once. The
	-- source is always a CREngine buffer, never the target itself.
	if left_outer_width > 0 then
		target:blitFrom(source, x, y + body_y, 0, body_y, left_outer_width, body_h)
	end
	target:blitFrom(source, x + left_outer_width, y + body_y,
		margins.left, body_y, left_width, body_h)
	target:blitFrom(source, x + live.left_edge, y + body_y,
		live.left_edge, body_y, old_gap_width, body_h)
	if right_width > 0 then
		target:blitFrom(source, x + gap_right, y + body_y,
			live.right_start, body_y, right_width, body_h)
	end
	if right_outer_width > 0 then
		local right_outer_x = rect.w - right_outer_width
		target:blitFrom(source, x + right_outer_x, y + body_y,
			right_outer_x, body_y, right_outer_width, body_h)
	end

	-- A chosen gray bypasses all gutter reads and paints only the page body.
	if fixed_gray_level ~= nil then
		local fixed_color = FIXED_GRAY_COLORS[fixed_gray_level]
		if not fixed_color then
			fixed_color = Blitbuffer.gray(fixed_gray_level * (1/15))
			FIXED_GRAY_COLORS[fixed_gray_level] = fixed_color
		end
		target:paintRect(x + gap_left, y + body_y, t, body_h, fixed_color)
		target:paintRect(x + live.right_start, y + body_y, t, body_h, fixed_color)
	else
		-- Preserve row-wise background variation in the original gutter.
		local gutter_sample_x = live.left_edge + math.floor(old_gap_width / 2)
		local source_type = source:getType()
		local run_y = body_y
		local run_color = source:getPixel(gutter_sample_x, body_y)
		local run_key = getColorKey(source_type, run_color)
		for row = body_y + 1, footer_y - 1 do
			local color = source:getPixel(gutter_sample_x, row)
			local key = getColorKey(source_type, color)
			if run_key == nil or key == nil or key ~= run_key then
				local run_h = row - run_y
				target:paintRect(x + gap_left, y + run_y, t, run_h, run_color)
				target:paintRect(x + live.right_start, y + run_y, t, run_h, run_color)
				run_y = row
				run_color = color
				run_key = key
			end
		end
		local run_h = footer_y - run_y
		target:paintRect(x + gap_left, y + run_y, t, run_h, run_color)
		target:paintRect(x + live.right_start, y + run_y, t, run_h, run_color)
	end

	-- ReaderFooter is a separate overlay. Preserve the buffer rows under it too,
	-- so the gap compositor never modifies the footer area.
	if footer_height > 0 then
		target:blitFrom(source, x, y + footer_y, 0, footer_y, rect.w, footer_height)
	end
	return true
end
-- Recognize the verified native cache closure by source content. Never unwrap
-- it: calling the closure preserves buffer tags, invalidation and statistics.
-- Unknown builds/wrappers retain the compatibility path.
-- Compare lexical tokens, preserving string literals and token boundaries.
-- Unsupported long-bracket literals/comments safely retain compatibility.
local function sourceTokens(source)
	local tokens, i = {}, 1
	while i <= #source do
		local c = source:sub(i, i)
		if c:match("%s") then
			i = i + 1
		elseif source:sub(i, i + 1) == "--" then
			if source:sub(i + 2):match("^%[=*%[") then return nil end
			i = (source:find("\n", i + 2, true) or #source) + 1
		elseif c == '"' or c == "'" then
			local first, quote = i, c
			i = i + 1
			while i <= #source and source:sub(i, i) ~= quote do
				i = i + (source:sub(i, i) == "\\" and 2 or 1)
			end
			if i > #source then return nil end
			tokens[#tokens + 1] = source:sub(first, i)
			i = i + 1
		elseif source:sub(i):match("^%[=*%[") then
			return nil
		else
			local tail = source:sub(i)
			local token = tail:match("^[%a_][%w_]*") or tail:match("^%d[%w%.]*")
				or tail:match("^%.%.%.") or tail:match("^%.%.")
				or tail:match("^[=~<>]=") or c
			tokens[#tokens + 1] = token
			i = i + #token
		end
	end
	return table.concat(tokens, "\0")
end

local VERIFIED_CACHE_SOURCE = [=[
    function(this, target, x, y, rect, pos)
        local do_draw = false
        local current_tag = this._callCacheGetCurrentTag()
        local current_buffer_tag = this._callCacheGet("current_buffer_tag")
        if this.buffer and (this.buffer.w ~= rect.w or this.buffer.h ~= rect.h) then
            do_draw = true
        elseif not this.buffer then
            do_draw = true
        elseif not current_buffer_tag then
            do_draw = true
        elseif current_buffer_tag ~= current_tag then
            do_draw = true
        end
        local starttime = now()
        if do_draw then
            if do_log then logger.dbg("callCache: ########## drawCurrentView: full draw") end
            CreDocument.drawCurrentView(this, target, x, y, rect, pos)
            addStatMiss("drawCurrentView", starttime)
            this._callCacheSet("current_buffer_tag", current_tag)
        else
            if do_log then logger.dbg("callCache: ---------- drawCurrentView: light draw") end
            target:blitFrom(this.buffer, x, y, 0, 0, rect.w, rect.h)
            addStatHit("drawCurrentView", starttime)
        end
    end
]=]
local VERIFIED_CACHE_TOKENS = sourceTokens(VERIFIED_CACHE_SOURCE)

local function matchesCacheSource(info)
	if type(info.linedefined) ~= "number" or type(info.lastlinedefined) ~= "number"
			or info.linedefined < 1 or info.lastlinedefined < info.linedefined
			or info.lastlinedefined - info.linedefined > 256 or info.lastlinedefined > 100000 then
		return false, "source line range unavailable or too large"
	end
	local opened, file = pcall(io.open, info.source:sub(2), "r")
	if not opened or not file then return false, "source file could not be opened" end
	local ok, source = pcall(function()
		local lines = {}
		local n = 0
		for line in file:lines() do
			n = n + 1
			if n >= info.linedefined then lines[#lines + 1] = line end
			if n >= info.lastlinedefined then break end
		end
		if n < info.lastlinedefined then return nil end
		return table.concat(lines, "\n")
	end)
	pcall(file.close, file)
	if not ok or not source then return false, "source range could not be read" end
	-- The closure starts after this assignment; the assignment itself is not
	-- part of the function. Everything else must match the verified tokens.
	source = source:gsub("^%s*self%s*%.%s*drawCurrentView%s*=%s*", "", 1)
	local tokens = sourceTokens(source)
	if not tokens or tokens ~= VERIFIED_CACHE_TOKENS then
		return false, "cache function content differs from verified native source"
	end
	return true
end

local function canUseDrawSink(draw)
	if draw == CreDocument.drawCurrentView then return true end
	if not (debug and debug.getinfo and debug.getupvalue) then
		return false, "debug_unavailable", "Check: debug inspection API unavailable"
	end
	local ok, info = pcall(debug.getinfo, draw, "S")
	if not ok or not info then
		return false, "unrecognized_draw", "Check: function metadata unavailable"
	end
	-- Capture metadata once at recognition time; never inspect every frame or
	-- expose captured upvalue contents in diagnostics.
	local details = "File: " .. tostring(info.source) .. "\nLines: "
		.. tostring(info.linedefined) .. "-" .. tostring(info.lastlinedefined)
	local function reject(reason, check)
		return false, reason, details .. "\nCheck: " .. check
	end
	if info.what ~= "Lua" then
		return reject("unrecognized_draw", "expected Lua function; found " .. tostring(info.what))
	end
	if type(info.source) ~= "string" or not info.source:match("^@.*frontend/document/credocument%.lua$") then
		return reject("unrecognized_draw", "source does not match frontend/document/credocument.lua")
	end
	local matches, source_reason = matchesCacheSource(info)
	if not matches then return reject("unrecognized_draw", source_reason) end
	local allowed = { CreDocument = true, do_log = true, logger = true,
		addStatMiss = true, addStatHit = true, now = true }
	local found = {}
	for i = 1, 32 do
		local name, value = debug.getupvalue(draw, i)
		if not name then break end
		if not allowed[name] then return reject("cache_signature", "unexpected captured variable: " .. name) end
		if name == "CreDocument" and value ~= CreDocument then
			return reject("cache_signature", "captured CreDocument is not the current class")
		end
		if (name == "now" or name == "addStatMiss" or name == "addStatHit")
				and type(value) ~= "function" then
			return reject("cache_signature", "captured " .. name .. " must be a function")
		end
		found[name] = true
	end
	for _, name in ipairs({ "CreDocument", "now", "addStatMiss", "addStatHit" }) do
		if not found[name] then return reject("cache_signature", "missing captured variable: " .. name) end
	end
	return true
end

local function installDrawHook(self, state)
	local doc = self.ui and self.ui.document
	if not doc then return end
	if state.hooked_doc ~= doc then
		restoreDrawHook(state)
		freeFrame(state)
		state.draw_hook_generation = (state.draw_hook_generation or 0) + 1
		state.hooked_doc = doc
		state.fast_path_rejected = nil
		state.fast_path_method = nil
		-- If another plugin wrapped our old hook, its generation check makes the
		-- stale closure a pass-through without overwriting that plugin's method.
		state.draw_current_view_hook = nil
		state.original_draw_current_view = nil
		state.render_path = nil
		state.render_confirmed = false
	end
	if state.draw_current_view_hook then return end
	local original_draw = doc.drawCurrentView
	if not original_draw then return end
	local sink_eligible, eligibility_reason, eligibility_detail = canUseDrawSink(original_draw)
	state.draw_inspection_detail = eligibility_detail
	state.fast_path_method = CreDocument.drawCurrentView
	local generation = state.draw_hook_generation
	local hook = function(d, target, x, y, rect, ...)
		if generation == state.draw_hook_generation and state.hooked_doc == d then
			-- The sleep screen may temporarily rotate the framebuffer. Do not
			-- compose reader columns or relayout the document in that coordinate space.
			if Device.screen_saver_mode then
				state.draw_unshifted = true
				state.sleep_layout_deferred = true
				return original_draw(d, target, x, y, rect, ...)
			end
			if state.sleep_layout_deferred then self:updateInnerGap(false) end
		end
		if generation ~= state.draw_hook_generation or state.hooked_doc ~= d
				or not state.active or not rect or rect.x ~= 0
				or rect.w ~= Screen:getWidth() then
			return original_draw(d, target, x, y, rect, ...)
		end
		-- Until composition succeeds, native drawing and hit-testing use the same space.
		state.draw_unshifted = true
		state.render_confirmed = false
		state.native_draw_reason = nil
		state.compatibility_reason = nil
		local margins = getMargins(d)
		local live = margins and getLiveGeometry(self, margins)
		local t = state.shift
		if not live or t <= 0 or rect.h <= 0 then
			state.native_draw_reason = "geometry_changed"
			return original_draw(d, target, x, y, rect, ...)
		end
		local left_width = live.left_edge - margins.left
		local right_width = rect.w - margins.right - live.right_start
		local gap_left = live.left_edge - t
		local gap_right = live.right_start + t
		if left_width <= 0 or right_width <= 0 or gap_right <= gap_left
				or gap_left < 0 or gap_right > rect.w then
			state.native_draw_reason = "geometry_changed"
			return original_draw(d, target, x, y, rect, ...)
		end

		local header_height = getHeaderHeight(d, rect.h)
		local footer_height = getFooterHeight(self, rect.h)
		local fixed_gray_level = state.fixed_gray_level

		-- Fast path for the stock CREngine draw method: render normally into
		-- CreDocument's own cached buffer, suppress its redundant full-screen
		-- blit, then compose the shifted columns directly from that immutable
		-- source. Also supports the verified native stable cache closure. Other
		-- wrappers use the
		-- compatibility path below instead.
		if state.fast_path_method ~= CreDocument.drawCurrentView then
			state.fast_path_method = CreDocument.drawCurrentView
			state.fast_path_rejected = nil
			sink_eligible, eligibility_reason, eligibility_detail = canUseDrawSink(original_draw)
			state.draw_inspection_detail = eligibility_detail
		end
		state.compatibility_reason = state.fast_path_rejected and "sink_contract"
			or not sink_eligible and eligibility_reason
			or target == d.buffer and "source_is_target"
			or state.draw_sink_busy and "nested_draw" or nil
		if not state.fast_path_rejected and sink_eligible and target ~= d.buffer
				and not state.draw_sink_busy then
			local sink = state.draw_sink
			if not sink then
				sink = { blitFrom = DRAW_SINK.blitFrom }
				state.draw_sink = sink
			end
			sink.calls, sink.valid, sink.source = 0, true, nil
			sink.x, sink.y, sink.width, sink.height = x, y, rect.w, rect.h
			state.draw_sink_busy = true
			local rendered = pcall(original_draw, d, sink, x, y, rect, ...)
			state.draw_sink_busy = false
			-- Method identity alone cannot prove an unchanged buffer contract.
			-- Require exactly the expected full-buffer blit before reusing it.
			local source = rendered and sink.valid and sink.calls == 1
				and sink.source == d.buffer and sink.source or nil
			sink.source = nil
			if not source then
				state.compatibility_reason = rendered and "sink_contract" or "sink_error"
			end
			if rendered and not source then
				-- A completed draw violated the sink contract. Do not probe it again
				-- for this document/method; transient render errors are not cached.
				state.fast_path_rejected = true
			end
			if source then
				state.render_path = "fast"
				local composed_ok, composed = pcall(composeShiftedView,
					source, target, x, y, rect, margins, live, t, header_height, footer_height, fixed_gray_level)
				freeFrame(state)
				if not composed_ok or not composed then
					-- Render already succeeded. Restore its immutable source without
					-- invoking the draw method again after a compositor failure.
					state.native_draw_reason = "compose_failed"
					target:blitFrom(source, x, y, 0, 0, rect.w, rect.h)
				else
					state.draw_unshifted = false
					state.render_confirmed = true
				end
				return
			end
		end

		-- Wrappers may require the real target or perform side effects. Call them
		-- there once, then snapshot their completed output for composition.
		state.render_path = "compatibility"
		original_draw(d, target, x, y, rect, ...)
		local prepared, frame = pcall(function()
			local bb_type = target:getType()
			local cached = state.render_frame
			if cached and (cached.w ~= rect.w or cached.h ~= rect.h or state.render_frame_type ~= bb_type) then
				freeFrame(state)
				cached = nil
			end
			if not cached then
				cached = Blitbuffer.new(rect.w, rect.h, bb_type)
				state.render_frame = cached
				state.render_frame_type = bb_type
			end
			cached:blitFrom(target, 0, 0, x, y, rect.w, rect.h)
			return cached
		end)
		if not prepared then
			state.native_draw_reason = "snapshot_failed"
			freeFrame(state)
			return
		end
		local composed_ok, composed = pcall(composeShiftedView,
			frame, target, x, y, rect, margins, live, t, header_height, footer_height, fixed_gray_level)
		if not composed_ok or not composed then
			-- Undo any partial composition from the snapshot, without rerendering.
			state.native_draw_reason = "compose_failed"
			target:blitFrom(frame, x, y, 0, 0, rect.w, rect.h)
			freeFrame(state)
		else
			state.draw_unshifted = false
			state.render_confirmed = true
		end
	end
	state.original_draw_current_view = original_draw
	state.draw_current_view_hook = hook
	doc.drawCurrentView = hook
end

local function requestLayoutUpdate(self, state)
	if state.syncing or not (self.ui and self.ui.document) then return end
	state.syncing = true
	local ok = pcall(function()
		self.ui:handleEvent(Event:new("UpdatePos", true))
	end)
	state.syncing = false
	if not ok and UIManager then
		UIManager:setDirty(self.ui.dialog, "full")
	end
end

local function getState(self)
	if not self._inner_gap_state then
		self._inner_gap_state = {
			active = false,
			shift = 0,
			base_margins = nil,
			applied_margins = nil,
			fixed_gray_level = nil,
		}
	end
	return self._inner_gap_state
end

local function cleanup(self, restore_margins, do_update)
	local state = getState(self)
	state.shift_cache = nil
	local doc = self.ui and self.ui.document
	local changed = false
	if restore_margins and doc and state.base_margins and state.applied_margins then
		local current = getMargins(doc)
		-- Restore only while the engine still has the exact margins this feature
		-- applied. If the user changed margins since the last lifecycle update,
		-- preserve those newer values instead of overwriting them.
		if current and marginsEqual(current, state.applied_margins)
				and not marginsEqual(current, state.base_margins) then
			if not setMargins(doc, state.base_margins) then
				return false
			end
			changed = true
		end
	end
	state.active = false
	state.draw_unshifted = nil
	state.render_path = nil
	state.render_confirmed = false
	state.shift = 0
	state.added_gap = nil
	state.applied_margins = nil
	freeFrame(state)
	if do_update and changed then
		requestLayoutUpdate(self, state)
	end
	return changed
end

function InnerGap.install(DictionaryMode)
	local original_get_content_rect = DictionaryMode.getContentRect
	if original_get_content_rect then
		DictionaryMode.getContentRect = function(self, ...)
			local r = original_get_content_rect(self, ...)
			local state = self._inner_gap_state
			if not r or not isVisualGapActive(state) or not state.base_margins then
				return r
			end
			local hpad = ContentArea.HORIZONTAL_TAP_PAD or 0
			r.left = state.base_margins.left
			r.right = state.base_margins.right
			r.x = math.max(0, r.left - hpad)
			local zone_right = math.max(0, r.right - hpad)
			r.w = math.max(0, r.sw - r.x - zone_right)
			-- ContentArea combines page2_x with the margins above. After restoring
			-- the displayed outer margins, add 2t to match the visually shifted
			-- split: the left inner edge moved left by t and the right by t.
			r.page2_x = (r.page2_x or 0) + 2 * state.shift
			-- Explicit visual edges keep tap padding from swallowing a small gutter,
			-- and use CREngine's integer midpoint on odd-width screens too.
			r.inner_left = 2 * math.floor(r.sw / 2) - r.page2_x - r.right
			r.inner_right = r.page2_x + r.left
			-- The footer is an overlay outside the selectable page body.
			local footer_height = getFooterHeight(self, r.sh)
			r.h = math.max(0, math.min(r.h, r.sh - footer_height - r.y))
			if footer_height > 0 then r.body_bottom = r.sh - footer_height end
			return r
		end
	end

	function DictionaryMode:getInnerGapPixels()
		local value = self:readBookSetting(GAP_SETTING_KEY)
		if value == nil then
			value = G_reader_settings:readSetting(GAP_SETTING_KEY, 0)
		end
		value = tonumber(value) or 0
		return math.max(0, math.min(MAX_GAP_PX, math.floor(value + 0.5)))
	end

	function DictionaryMode:getInnerGapGrayLevel()
		local value = self:readBookSetting(GAP_GRAY_SETTING_KEY)
		if value == nil then
			value = G_reader_settings:readSetting(GAP_GRAY_SETTING_KEY)
		end
		if value == nil or value == GAP_GRAY_AUTO then
			return nil
		end
		value = tonumber(value)
		if not value or value ~= value then
			return nil
		end
		return math.max(0, math.min(15, math.floor(value + 0.5)))
	end

	function DictionaryMode:setInnerGapGrayLevel(value)
		if value == nil then
			-- Explicit per-book auto overrides a global fixed gray setting.
			self:saveBookSetting(GAP_GRAY_SETTING_KEY, GAP_GRAY_AUTO)
		else
			value = tonumber(value)
			if not value or value ~= value or value < 0 or value > 15 or value ~= math.floor(value) then
				return false
			end
			self:saveBookSetting(GAP_GRAY_SETTING_KEY, value)
		end
		local state = self._inner_gap_state
		if state then
			state.fixed_gray_level = self:getInnerGapGrayLevel()
		end
		if self.ui and self.ui.dialog then
			UIManager:setDirty(self.ui.dialog, "full")
		end
		return true
	end
	function DictionaryMode:transformInnerGapRect(rect)
		local state = self._inner_gap_state
		if not (isVisualGapActive(state) and rect and type(rect.x) == "number") then
			return rect
		end
		local live = getLiveGeometry(self, getMargins(self.ui.document))
		if not live then return rect end
		if rect.x >= live.left_edge and rect.x + (rect.w or 0) <= live.right_start then
			return nil
		end
		return mapLayoutRectToVisualRect(rect, live, state.shift)
	end

	function DictionaryMode:updateInnerGap(do_update)
		local state = getState(self)
		-- Invalidate an in-progress highlight snapshot on any layout update.
		state.geometry_epoch = (state.geometry_epoch or 0) + 1
		if Device.screen_saver_mode then
			-- Keep the last reader margins/hooks intact until its viewport is back.
			state.sleep_layout_deferred = true
			state.shift_cache = nil
			return false
		end
		state.sleep_layout_deferred = nil
		-- Cache color mode during lifecycle/layout updates, not every draw.
		state.fixed_gray_level = self:getInnerGapGrayLevel()
		if state.syncing then return false end

		local doc = self.ui and self.ui.document
		local current = getMargins(doc)
		if not doc or not current then
			state.last_status = "inactive"
			cleanup(self, false, false)
			if not state.active then restoreHooks(state) end
			return false
		end

		if state.applied_margins and not marginsEqual(current, state.applied_margins) then
			-- A native margin change arrived while the feature was active. Treat
			-- those values as the new user baseline before adding our temporary t.
			state.base_margins = current
			state.applied_margins = nil
			state.active = false
			state.shift = 0
		elseif state.base_margins and not state.applied_margins
				and not marginsEqual(current, state.base_margins) then
			-- Also catch margin settings that changed while the inner gap was off
			-- (including ReaderTypeset's initial application during document load).
			state.base_margins = current
		elseif not state.base_margins then
			state.base_margins = current
		end

		local requested = self:getInnerGapPixels()
		local missing = self:isEnabled() and requested > 0 and getMissingCapability(self) or nil
		if missing then
			cleanup(self, true, true)
			if not state.active then restoreHooks(state) end
			state.last_status = "missing_capability"
			state.missing_capability = missing
			return false
		end
		state.missing_capability = nil
		local usable = self:isEnabled()
			and requested > 0
			and not self.ui.paging
			and doc.getVisiblePageCount and doc:getVisiblePageCount() > 1
			and not hasBackgroundImage()
		local baseline = usable and getBaselineGeometry(self, state.base_margins, current) or nil
		if not baseline then
			state.last_status = usable and "unsupported_geometry" or "inactive"
			local changed = cleanup(self, true, true)
			if not state.active then restoreHooks(state) end
			return changed
		end

		-- Cache only the arithmetic search, after checking live geometry and margin
		-- ownership above. Store scalar snapshots, never mutable margin tables.
		local margins = state.base_margins
		local font_size = doc:getFontSize()
		local font_gap = getFontGap(doc)
		local height = Screen:getHeight()
		local pages = doc:getVisiblePageCount()
		local cached = state.shift_cache
		local shift, added_gap
		if cached and cached.doc == doc and cached.requested == requested
				and cached.font_size == font_size and cached.font_gap == font_gap
				and cached.height == height and cached.pages == pages
				and cached.left == margins.left and cached.right == margins.right
				and cached.top == margins.top and cached.bottom == margins.bottom
				and cached.width == baseline.width and cached.mid == baseline.mid
				and cached.page2_x == baseline.page2_x and cached.gap == baseline.gap
				and cached.left_width == baseline.left_width
				and cached.right_width == baseline.right_width then
			shift, added_gap = cached.shift, cached.added_gap
		else
			shift, added_gap = chooseShift(self, margins, baseline, requested, font_gap)
			state.shift_cache = {
				doc = doc, requested = requested, font_size = font_size, font_gap = font_gap,
				height = height, pages = pages,
				left = margins.left, right = margins.right, top = margins.top, bottom = margins.bottom,
				width = baseline.width, mid = baseline.mid, page2_x = baseline.page2_x,
				gap = baseline.gap, left_width = baseline.left_width, right_width = baseline.right_width,
				shift = shift, added_gap = added_gap,
			}
		end
		if shift <= 0 then
			state.last_status = "gap_too_small_for_columns"
			local changed = cleanup(self, true, true)
			if not state.active then restoreHooks(state) end
			return changed
		end

		-- Install only after confirming the feature can actually run. This keeps
		-- disabled, unsupported, and zero-gap cases free of permanent Lua hooks.
		installViewHooks(self, state)
		installHighlightHooks(self, state)
		installSelectionHooks(self, state)
		installDrawHook(self, state)
		installLinkHooks(self, state)

		local target = {
			left = state.base_margins.left + shift,
			top = state.base_margins.top,
			right = state.base_margins.right + shift,
			bottom = state.base_margins.bottom,
		}
		local changed = not marginsEqual(current, target)
		if changed then
			state.render_path = nil
			state.render_confirmed = false
		end
		state.shift = shift
		state.added_gap = added_gap
		state.active = true
		state.applied_margins = target
		state.last_status = "active"
		if changed then
			if not setMargins(doc, target) then
				-- Do not overwrite a value that did not become our target; it may
				-- have been changed by another setting while the setter was failing.
				local after = getMargins(doc)
				if after and marginsEqual(after, target) then
					local restored = setMargins(doc, state.base_margins)
					local after_restore = getMargins(doc)
					if not restored and after_restore
							and marginsEqual(after_restore, target) then
						-- The engine is still using our temporary margins. Keep the
						-- matching draw/touch transforms installed and retry on update.
						state.last_status = "margin_restore_failed"
						requestLayoutUpdate(self, state)
						return false
					end
				end
				state.active = false
				state.shift = 0
				state.applied_margins = nil
				state.last_status = "margin_set_failed"
				requestLayoutUpdate(self, state)
				restoreHooks(state)
				return false
			end
			requestLayoutUpdate(self, state)
		end
		return true
	end

	function DictionaryMode:setInnerGapPixels(value)
		value = tonumber(value)
		if not value then value = 0 end
		value = math.max(0, math.min(MAX_GAP_PX, math.floor(value + 0.5)))
		self:saveBookSetting(GAP_SETTING_KEY, value)
		local active = self:updateInnerGap(true)
		if not active and value > 0 then
			UIManager:show(InfoMessage:new{
				text = _("Inner gap is available only in a supported two-column CRE layout without a background image."),
				timeout = 3,
			})
		end
		return active
	end

	function DictionaryMode:showInnerGapDialog(touchmenu_instance)
		local dialog
		dialog = MultiInputDialog:new{
			title = _("Two-column inner gap"),
			fields = {
				{
					description = T(_("Additional inner gap in pixels (0–%1)"), MAX_GAP_PX)
						.. "\n\n" .. self:getInnerGapDiagnosticText(),
					input_type = "number",
					text = tostring(self:getInnerGapPixels()),
					hint = "0",
				},
			},
			buttons = {
				{
					{
						text = _("Cancel"),
						id = "close",
						callback = function()
							UIManager:close(dialog)
							if touchmenu_instance then
								touchmenu_instance:updateItems()
							end
						end,
					},
					{
						text = _("Apply"),
						is_enter_default = true,
						callback = function()
							local fields = dialog:getFields()
							self:setInnerGapPixels(fields[1])
							UIManager:close(dialog)
							if touchmenu_instance then
								touchmenu_instance:updateItems()
							end
						end,
					},
				},
			},
		}
		UIManager:show(dialog)
	end

	function DictionaryMode:showInnerGapGrayDialog(touchmenu_instance)
		local current = self:getInnerGapGrayLevel()
		local dialog
		dialog = MultiInputDialog:new{
			title = _("Inner gap background"),
			fields = {
				{
					description = _("KOReader gray code 0-15 (0 white, 15 black); empty uses auto sampling"),
					input_type = "number",
					text = current ~= nil and tostring(current) or "",
					hint = _("Auto"),
				},
			},
			buttons = {
				{
					{
						text = _("Cancel"),
						id = "close",
						callback = function()
							UIManager:close(dialog)
							if touchmenu_instance then
								touchmenu_instance:updateItems()
							end
						end,
					},
					{
						text = _("Auto"),
						callback = function()
							self:setInnerGapGrayLevel(nil)
							UIManager:close(dialog)
							if touchmenu_instance then
								touchmenu_instance:updateItems()
							end
						end,
					},
					{
						text = _("Apply"),
						is_enter_default = true,
						callback = function()
							local fields = dialog:getFields()
							local input = fields[1]
							if input == nil or tostring(input):match("^%s*$") then
								self:setInnerGapGrayLevel(nil)
								UIManager:close(dialog)
								if touchmenu_instance then
									touchmenu_instance:updateItems()
								end
								return
							end
							local level = tonumber(input)
							if not level or level ~= level or level < 0 or level > 15 or level ~= math.floor(level) then
								UIManager:show(InfoMessage:new{
									text = _("Enter a whole-number gray code from 0 to 15 (0 white, 15 black), or choose Auto."),
									timeout = 2,
								})
								return
							end
							self:setInnerGapGrayLevel(level)
							UIManager:close(dialog)
							if touchmenu_instance then
								touchmenu_instance:updateItems()
							end
						end,
					},
				},
			},
		}
		UIManager:show(dialog)
	end

	function DictionaryMode:getInnerGapBackgroundMenuItem()
		return {
			text_func = function()
				local level = self:getInnerGapGrayLevel()
				if level == nil then
					return _("Inner gap background (auto sample)")
				end
				return T(_("Inner gap background (gray %1/15)"), level)
			end,
			enabled_func = function()
				return self:isEnabled()
			end,
			help_text = _("Auto samples the existing gutter by row. A fixed KOReader gray code (0 white to 15 black) skips sampling."),
			keep_menu_open = true,
			callback = function(touchmenu_instance)
				self:showInnerGapGrayDialog(touchmenu_instance)
			end,
		}
	end
	function DictionaryMode:getInnerGapStatusText()
		local state = self._inner_gap_state
		if not self:isEnabled() or self:getInnerGapPixels() == 0 then return _("off") end
		if not state then return _("waiting for layout") end
		if state.last_status == "missing_capability" then
			return _("missing function") .. ": " .. tostring(state.missing_capability)
		end
		if state.last_status == "unsupported_geometry" then return _("unsupported layout") end
		if state.last_status == "gap_too_small_for_columns" then return _("columns too narrow") end
		if state.last_status == "margin_restore_failed" then return _("margin restore failed") end
		if state.last_status == "margin_set_failed" then return _("margin change failed") end
		if state.active then
			if Device.screen_saver_mode then return _("paused for sleep screen") end
			if not state.render_path then return _("layout ready; waiting for draw") end
			if not state.render_confirmed or state.draw_unshifted then return _("native image fallback") end
			if state.render_path == "compatibility" then return _("active; compatible drawing") end
			return _("active; fast path")
		end
		return _("inactive in this reading mode")
	end

	function DictionaryMode:getInnerGapDiagnosticText()
		local text = self:getInnerGapStatusText()
		local state = self._inner_gap_state
		if not state or not state.active or Device.screen_saver_mode or not state.render_path then return text end

		local reason = state.native_draw_reason or state.compatibility_reason
		if reason and DIAGNOSTIC_REASONS[reason] then
			text = text .. "\n\n" .. DIAGNOSTIC_REASONS[reason]
			if (reason == "unrecognized_draw" or reason == "cache_signature" or reason == "debug_unavailable")
					and state.draw_inspection_detail then
				text = text .. "\n\n" .. state.draw_inspection_detail
			end
		end
		return text
	end

	function DictionaryMode:getInnerGapStatusMenuItem()
		return {
			text_func = function() return self:getInnerGapStatusText() end,
			help_text_func = function() return self:getInnerGapDiagnosticText() end,
			keep_menu_open = true,
			callback = function()
				UIManager:show(InfoMessage:new{ text = self:getInnerGapDiagnosticText() })
			end,
			separator = true,
		}
	end

	function DictionaryMode:getInnerGapMenuItem()
		return {
			text_func = function()
				local requested = self:getInnerGapPixels()
				local state = self._inner_gap_state
				if state and state.active and state.added_gap and state.added_gap < requested then
					return T(_("Two-column inner gap (requested %1 px; added %2 px)"), requested, state.added_gap)
				end
				return T(_("Two-column inner gap (%1 px)"), requested)
			end,
			enabled_func = function()
				return self:isEnabled()
			end,
			help_text = _("Adds space between two columns while preserving the outer text margins. Uses the existing Dictionary Mode touch and hold handling. Added pixels are extra gutter, not total gutter width. A smaller addition preserves the minimum column width or fits whole-pixel layout steps. Drawing status describes the last completed reader draw."),
			keep_menu_open = true,
			callback = function(touchmenu_instance)
				self:showInnerGapDialog(touchmenu_instance)
			end,
		}
	end

	function DictionaryMode:onResume()
		local state = self._inner_gap_state
		-- Resume may precede dismissal of a gesture-locked sleep screen. The
		-- reader's first draw/layout update will finish the deferred sync then.
		if state and state.sleep_layout_deferred then self:updateInnerGap(false) end
	end

	function DictionaryMode:teardownInnerGap()
		local state = getState(self)
		state.geometry_epoch = (state.geometry_epoch or 0) + 1
		cleanup(self, true, false)
		-- CloseDocument is the final render boundary for this document. If the
		-- engine refused to restore its temporary margins, release this document's
		-- hooks and frame anyway; the next document will apply its own settings.
		local restore_failed = state.active
		if restore_failed then
			state.active = false
			state.shift = 0
			state.applied_margins = nil
		end
		restoreHooks(state)
		freeFrame(state)
		state.base_margins = nil
		state.applied_margins = nil
		state.fast_path_rejected = nil
		state.fast_path_method = nil
		state.render_path = nil
		state.sleep_layout_deferred = nil
		return not restore_failed
	end
end

return InnerGap
