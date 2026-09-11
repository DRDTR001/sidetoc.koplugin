local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local FontList = require("fontlist")
local ffiUtil = require("ffi/util")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputDialog = require("ui/widget/inputdialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local util = require("util")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local _ = require("gettext")

local Screen = Device.screen

local SideToc = WidgetContainer:extend{
    name = "sidetoc",
    is_doc_only = true,
    title = _("侧边目录"),
    menu = nil,
    menu_container = nil,
    panel_width = nil,
    page_label = nil,
    mode = "toc",
    expanded_toc = nil,
    toggle_width = nil,
    position = "left",
    txt_toc = nil,
}

function SideToc:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function SideToc:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_side_toc", {
        category = "none",
        event = "ToggleSideToc",
        title = _("打开/关闭侧边目录"),
        reader = true,
    })
end

function SideToc:addToMainMenu(menu_items)
    menu_items.sidetoc = {
        sorting_hint = "navi",
        text = self.title,
        callback = function() self:toggle() end,
    }
    menu_items.sidetoc_position = {
        sorting_hint = "navi",
        text_func = function()
            return T(_("侧边目录位置：%1"), self:_getPanelPosition() == "right" and _("右侧") or _("左侧"))
        end,
        sub_item_table_func = function()
            return self:_getPositionMenuItems()
        end,
    }
end

function SideToc:_getPanelPosition()
    local position = G_reader_settings:readSetting("sidetoc_position")
    if position ~= "right" then
        return "left"
    end
    return position
end

function SideToc:_setPanelPosition(position)
    if position ~= "right" then
        position = "left"
    end
    G_reader_settings:saveSetting("sidetoc_position", position)
    self.position = position
end

function SideToc:_getPositionMenuItems()
    return {
        {
            text = _("左侧"),
            radio = true,
            checked_func = function()
                return self:_getPanelPosition() == "left"
            end,
            callback = function()
                self:_setPanelPosition("left")
            end,
        },
        {
            text = _("右侧"),
            radio = true,
            checked_func = function()
                return self:_getPanelPosition() == "right"
            end,
            callback = function()
                self:_setPanelPosition("right")
            end,
        },
    }
end

function SideToc:_closeMenu()
    if self.menu_container then
        UIManager:close(self.menu_container)
    end
    self.menu = nil
    self.menu_container = nil
    self.panel_width = nil
    self.page_label = nil
end

function SideToc:_goto(item)
    self:_closeMenu()
    self.ui.link:addCurrentLocationToStack()
    if item.bookmark_page then
        self.ui.bookmark:gotoBookmark(item.bookmark_page, item.bookmark_pos0)
    elseif item.xpointer then
        self.ui:handleEvent(Event:new("GotoXPointer", item.xpointer, item.xpointer))
    elseif item.page then
        self.ui:handleEvent(Event:new("GotoPage", item.page))
    end
end

function SideToc:_selectFont(item)
    if not item.font_face or not self.ui.font then return end
    if item.font_callback then
        item.font_callback()
    else
        self.ui.font:onSetFont(item.font_face)
    end
    if self.menu and self.mode == "fonts" then
        self.menu:switchItemTable(nil, self:_buildFontItems())
        UIManager:setDirty(self.menu_container, "ui")
    end
end

function SideToc:_getCurrentTocIndex(pageno)
    local toc = self.ui.toc
    if self.ui.rolling then
        return toc:getTocIndexByPage(self.ui.document:getXPointer())
    end
    pageno = pageno or (self.ui.view.state and self.ui.view.state.page)
    return pageno and toc:getTocIndexByPage(pageno)
end

function SideToc:_updateCurrentToc(pageno)
    if not self.menu or self.mode ~= "toc" then return end
    local current_raw_index = self:_getCurrentTocIndex(pageno)
    if current_raw_index == self.current_toc_raw_index then return end
    local toc = self:_initNativeToc()
    self:_ensureCurrentTocParents(toc, current_raw_index)
    self.menu:switchItemTable(nil, self:_buildItems(current_raw_index), self.current_toc_index)
    self:_updatePageControls()
    UIManager:setDirty(self.menu_container, "ui")
end

function SideToc:_buildBookmarkItems()
    local items = {}
    local bookmark = self.ui.bookmark
    local annotations = self.ui.annotation and self.ui.annotation.annotations or {}
    for index, annotation in ipairs(annotations) do
        local item = util.tableDeepCopy(annotation)
        item.text_orig = item.text or ""
        item.type = bookmark.getBookmarkType(item)
        item.text = bookmark:getBookmarkItemText(item)
        item.mandatory = bookmark:getBookmarkPageString(item.page)
        item.bookmark_page = annotation.page
        item.bookmark_pos0 = annotation.pos0
        item.bookmark_index = index
        table.insert(items, item)
    end
    return items
end

function SideToc:_buildModeItems()
    if self.mode == "bookmarks" then
        return self:_buildBookmarkItems()
    elseif self.mode == "fonts" then
        return self:_buildFontItems()
    end
    return self:_buildItems()
end

function SideToc:_switchMode(mode)
    if mode == "fonts" and not self:_isEpub() then
        return
    end
    self.mode = mode
    if not self.menu then return end
    if mode == "toc" then
        local toc = self:_initNativeToc()
        self:_ensureCurrentTocParents(toc, self:_getCurrentTocIndex())
    end
    self.menu:switchItemTable(nil, self:_buildModeItems())
    self:_updatePageControls()
    UIManager:setDirty(self.menu_container, "ui")
end

function SideToc:_isEpub()
    local path = self.ui.document and self.ui.document.file
    return path and path:lower():match("%.epub$") ~= nil
end

function SideToc:_fontPathKey(path)
    path = ffiUtil.realpath(path) or path
    path = path:gsub("\\\\", "/"):gsub("/$", "")
    return path:lower()
end

function SideToc:_getAllowedFontPaths()
    FontList:getFontList()
    local builtin_dir = self:_fontPathKey(FontList.fontdir)
    local allowed_paths = {}
    for _, path in ipairs(FontList.fontlist) do
        local normalized_path = self:_fontPathKey(path)
        local parent = normalized_path:match("^(.*)/[^/]+$")
        if parent == builtin_dir then
            allowed_paths[normalized_path] = true
        end
    end
    return allowed_paths
end

function SideToc:_buildFontItems()
    local items = {}
    if not self.ui.font then return items end

    self.ui.font:setupFaceMenuTable()
    local allowed_font_paths = self:_getAllowedFontPaths()
    local cre = require("document/credocument"):engineInit()
    for _, native_item in ipairs(self.ui.font.face_table or {}) do
        if native_item.menu_item_id then
            local font_path = cre.getFontFaceFilenameAndFaceIndex(native_item.menu_item_id)
            if font_path and allowed_font_paths[self:_fontPathKey(font_path)] then
                table.insert(items, {
                    text_func = native_item.text_func,
                    bold = native_item.menu_item_id == self.ui.font.font_face,
                    font_face = native_item.menu_item_id,
                    font_callback = native_item.callback,
                })
            end
        end
    end
    return items
end

function SideToc:_tocKey(toc_item, index)
    return toc_item.xpointer or ("index:" .. index)
end

function SideToc:_loadExpandedToc()
    if self.expanded_toc == nil then
        self.expanded_toc = self.ui.doc_settings:readSetting("sidetoc_expanded_toc") or {}
    end
end

function SideToc:_saveExpandedToc()
    self.ui.doc_settings:saveSetting("sidetoc_expanded_toc", self.expanded_toc)
end

function SideToc:_buildTxtToc()
    local document = self.ui.document
    local virtual_toc = {}
    local page_count = document:getPageCount()
    for page = 1, page_count do
        local page_text = document:getPageText(page)
        if page_text then
            for line in page_text:gmatch("[^\r\n]+") do
                local title = line:match("^%s*(.-)%s*$")
                if title and title ~= "" and (
                    title:match("^第[一二三四五六七八九十百千万零〇两0-9]+章([ \t]+.*)?$") or
                    title:match("^第[一二三四五六七八九十百千万零〇两0-9]+节([ \t]+.*)?$") or
                    title:match("^(序章|楔子|终章)([ \t]+.*)?$")
                ) then
                    table.insert(virtual_toc, {
                        title = title,
                        text = title,
                        page = page,
                        xpointer = document:getPageXPointer(page),
                        depth = 1,
                    })
                end
            end
        end
    end
    return virtual_toc
end

function SideToc:_ensureTxtToc(toc)
    if not self.ui.document.is_txt or toc.toc and #toc.toc > 0 then
        return
    end
    if self.txt_toc == nil then
        self.txt_toc = self:_buildTxtToc()
    end
    toc.toc = self.txt_toc
end

function SideToc:_initNativeToc()
    local toc = self.ui.toc
    toc:fillToc()
    self:_ensureTxtToc(toc)
    self:_loadExpandedToc()
    if toc.sidetoc_initialized then
        toc.toc_menu = {
            switchItemTable = function()
                self:_refreshTocMenu()
            end,
        }
        return toc
    end
    toc.expanded_nodes = toc.expanded_nodes or {}
    toc.filtered_toc = toc.toc
    toc.collapse_depth = toc.collapse_depth or 2
    for index, item in ipairs(toc.toc) do
        item.index = index
    end

    if not toc.expand_button then
        toc.expand_button = Button:new{
            text = "\u{25B6}", width = self.toggle_width,
            height = Screen:scaleBySize(28), padding = 0, bordersize = 0,
            onTapSelectButton = function() end,
        }
        toc.collapse_button = Button:new{
            text = "\u{25BC}", width = self.toggle_width,
            height = Screen:scaleBySize(28), padding = 0, bordersize = 0,
            onTapSelectButton = function() end,
        }
    end

    if not toc.collapsed_toc or #toc.collapsed_toc == 0 then
        toc.collapsed_toc = {}
        local depth = 0
        for index = #toc.toc, 1, -1 do
            local item = toc.toc[index]
            if item.depth < depth then
                item.state = toc.expand_button:new{}
            end
            if item.depth < toc.collapse_depth then
                table.insert(toc.collapsed_toc, 1, item)
            end
            depth = item.depth
        end
    end

    local saved_expanded = {}
    for index, item in ipairs(toc.toc) do
        local key = self:_tocKey(item, index)
        saved_expanded[index] = self.expanded_toc[key] == true
    end

    toc.expanded_nodes = {}
    toc.toc_menu = {
        switchItemTable = function()
            self:_refreshTocMenu()
        end,
    }
    for index, is_expanded in ipairs(saved_expanded) do
        if is_expanded then toc:expandToc(index) end
    end
    toc.sidetoc_initialized = true
    return toc
end

function SideToc:_saveNativeExpandedToc(toc)
    for index, item in ipairs(toc.toc or {}) do
        if item.state then
            self.expanded_toc[self:_tocKey(item, index)] = toc.expanded_nodes[index] == true
        end
    end
    self:_saveExpandedToc()
end

function SideToc:_ensureCurrentTocParents(toc, current_raw_index)
    if current_raw_index then
        toc:expandParentNode(current_raw_index)
        self:_saveNativeExpandedToc(toc)
    end
end

function SideToc:_toggleTocNode(index)
    local toc = self:_initNativeToc()
    if toc.expanded_nodes[index] then
        toc:collapseToc(index)
    else
        toc:expandToc(index)
    end
    self:_saveNativeExpandedToc(toc)
    self:_refreshTocMenu()
end

function SideToc:_buildItemsLegacy(current_raw_index)
    local toc = self.ui.toc
    toc:fillToc()
    self:_loadExpandedToc()
    current_raw_index = current_raw_index or self:_getCurrentTocIndex()
    self.current_toc_raw_index = current_raw_index
    if self:_expandParentsForIndex(toc.toc or {}, current_raw_index) then
        self:_saveExpandedToc()
    end
    local items = {}
    local hidden_depth
    local visible_index = 0
    for index, toc_item in ipairs(toc.toc or {}) do
        local depth = tonumber(toc_item.depth) or 0
        if not (hidden_depth and depth > hidden_depth) then
            hidden_depth = nil
            visible_index = visible_index + 1
            local is_current = index == current_raw_index
            local title = toc_item.title or ""
            local key = self:_tocKey(toc_item, index)
            local has_children = toc[index + 1] and toc[index + 1].depth > depth
            local is_expanded = self.expanded_toc[key] ~= false
            if has_children and not is_expanded then
                hidden_depth = depth
            end
            table.insert(items, {
            text = string.rep("  ", math.max(0, depth)) .. (toc_item.title or _("(无标题)")),
            xpointer = toc_item.xpointer,
            page = toc_item.page,
            bold = is_current,
            toc_title = toc_item.title or "",
            toc_depth = depth,
            has_children = has_children,
            toc_index = index,
            visible_index = visible_index,
            text_func = function()
                return (has_children and (is_expanded and "\u{25BC} " or "\u{25B6} ") or "")
                    .. string.rep("  ", math.max(0, depth))
                    .. title
            end,
            })
        end
    end
    for _, item in ipairs(items) do
        if item.toc_index == current_raw_index then
            self.current_toc_index = item.visible_index
            break
        end
    end
    return items
end

function SideToc:_buildItems(current_raw_index)
    local toc = self:_initNativeToc()
    current_raw_index = current_raw_index or self:_getCurrentTocIndex()
    self.current_toc_raw_index = current_raw_index
    local items = {}
    self.current_toc_index = nil
    for visible_index, toc_item in ipairs(toc.collapsed_toc or {}) do
        local raw_index = toc_item.index or 0
        local has_children = toc_item.state ~= nil
        local is_expanded = toc.expanded_nodes[raw_index] == true
        local title = toc_item.title or ""
        table.insert(items, {
            xpointer = toc_item.xpointer,
            page = toc_item.page,
            mandatory = toc_item.page and tostring(toc_item.page) or nil,
            bold = raw_index == current_raw_index,
            has_children = has_children,
            toc_index = raw_index,
            visible_index = visible_index,
            text_func = function()
                return (has_children and (is_expanded and "\u{25BC} " or "\u{25B6} ") or "")
                    .. string.rep("  ", math.max(0, (tonumber(toc_item.depth) or 1) - 1))
                    .. title
            end,
        })
        if raw_index == current_raw_index then
            self.current_toc_index = visible_index
        end
    end
    return items
end

function SideToc:_refreshTocMenu()
    if not self.menu or self.mode ~= "toc" then return end
    self.menu:switchItemTable(nil, self:_buildItems(), -1)
    self:_updatePageControls()
    UIManager:setDirty(self.menu_container, "ui")
end

function SideToc:_refreshBookmarks()
    if not self.menu or self.mode ~= "bookmarks" then return end
    self.menu:switchItemTable(nil, self:_buildBookmarkItems(), -1)
    self:_updatePageControls()
    UIManager:setDirty(self.menu_container, "ui")
end

function SideToc:_showBookmarkActions(item)
    local bookmark = self.ui.bookmark
    local actions
    actions = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("删除书签"),
                    callback = function()
                        UIManager:close(actions)
                        UIManager:show(ConfirmBox:new{
                            text = _("删除此书签？"),
                            ok_text = _("删除"),
                            ok_callback = function()
                                bookmark:removeItem(item, item.bookmark_index)
                                self:_refreshBookmarks()
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(actions) end,
                },
            },
        },
    }
    UIManager:show(actions)
    return true
end

function SideToc:_updatePageControls()
    if not self.menu or not self.page_label then return end
    self.page_label:setText(T(_("%1 / %2"), self.menu.page, self.menu.page_num), self.page_label.width)
    self.page_label:enable()
    self.menu._side_previous:enableDisable(self.menu.page > 1)
    self.menu._side_next:enableDisable(self.menu.page < self.menu.page_num)
end

function SideToc:_showPageJump()
    if not self.menu then return end
    local page_dialog
    page_dialog = InputDialog:new{
        title = _("跳转到目录页"),
        input = tostring(self.menu.page),
        input_hint = T(_("1 至 %1"), self.menu.page_num),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function()
                    UIManager:close(page_dialog)
                end,
            },
            {
                text = _("跳转"),
                callback = function()
                    local page = tonumber(page_dialog:getInputText())
                    if not page then return end
                    page = math.max(1, math.min(self.menu.page_num, math.floor(page)))
                    UIManager:close(page_dialog)
                    self.menu:onGotoPage(page)
                end,
            },
        }},
    }
    UIManager:show(page_dialog)
    page_dialog:onShowKeyboard()
end

function SideToc:_makePageControls(width)
    local button_width = Screen:scaleBySize(36)
    local gap = Screen:scaleBySize(4)
    local label_width = math.max(button_width, width - 2 * button_width - 2 * gap)
    local button_height = Screen:scaleBySize(36)
    local previous = Button:new{
        text = "‹",
        width = button_width,
        height = button_height,
        padding = 0,
        bordersize = 0,
        text_font_bold = true,
        callback = function()
            if self.menu.page > 1 then
                self.menu:onGotoPage(self.menu.page - 1)
            end
        end,
        hold_callback = function()
            self.menu:onGotoPage(math.max(1, self.menu.page - 10))
        end,
    }
    local label = Button:new{
        text = "",
        width = label_width,
        height = button_height,
        padding = 0,
        bordersize = 0,
        text_font_bold = false,
        callback = function() self:_showPageJump() end,
    }
    local next_page = Button:new{
        text = "›",
        width = button_width,
        height = button_height,
        padding = 0,
        bordersize = 0,
        text_font_bold = true,
        callback = function()
            if self.menu.page < self.menu.page_num then
                self.menu:onGotoPage(self.menu.page + 1)
            end
        end,
        hold_callback = function()
            self.menu:onGotoPage(math.min(self.menu.page_num, self.menu.page + 10))
        end,
    }
    local controls = HorizontalGroup:new{
        previous,
        HorizontalSpan:new{ width = gap },
        label,
        HorizontalSpan:new{ width = gap },
        next_page,
    }
    self.menu._side_previous = previous
    self.menu._side_next = next_page
    self.page_label = label
    return controls
end

function SideToc:_makeHeader(width, height)
    local close_width = Screen:scaleBySize(36)
    local tab_count = self:_isEpub() and 3 or 2
    local tab_width = math.max(Screen:scaleBySize(36), math.floor((width - close_width) / tab_count))
    local header = {
        Button:new{
            text = _("目录"),
            width = tab_width,
            height = height,
            padding = 0,
            bordersize = 0,
            text_font_bold = self.mode == "toc",
            callback = function() self:_switchMode("toc") end,
        },
        Button:new{
            text = _("书签"),
            width = tab_width,
            height = height,
            padding = 0,
            bordersize = 0,
            text_font_bold = self.mode == "bookmarks",
            callback = function() self:_switchMode("bookmarks") end,
        },
    }
    if tab_count == 3 then
        table.insert(header, Button:new{
            text = _("字体"),
            width = tab_width,
            height = height,
            padding = 0,
            bordersize = 0,
            text_font_bold = self.mode == "fonts",
            callback = function() self:_switchMode("fonts") end,
        })
    end
    table.insert(header, Button:new{
        text = "×",
        width = close_width,
        height = height,
        padding = 0,
        bordersize = 0,
        text_font_bold = true,
        callback = function() self:_closeMenu() end,
    })
    return HorizontalGroup:new(header)
end

function SideToc:_installPageControls()
    local controls = self:_makePageControls(self.panel_width)
    self.menu.page_info = controls
    self.menu[1][1][3][1] = controls
    self:_updatePageControls()
end

function SideToc:_showMenu()
    self.mode = "toc"
    self.position = self:_getPanelPosition()
    self.panel_width = math.floor(Screen:getWidth() * 0.47)
    self.toggle_width = Screen:scaleBySize(24)
    local toc = self:_initNativeToc()
    self:_ensureCurrentTocParents(toc, self:_getCurrentTocIndex())
    local items = self:_buildModeItems()

    local screen_size = Screen:getSize()
    local header_height = Screen:scaleBySize(40)
    self.menu = Menu:new{
        item_table = items,
        width = self.panel_width,
        height = screen_size.h - header_height,
        no_title = true,
        is_borderless = true,
        is_popout = false,
        single_line = true,
        close_callback = function() self:_closeMenu() end,
    }
    self.menu.owner = self
    function self.menu:onGotoPage(page)
        Menu.onGotoPage(self, page)
        self.owner:_updatePageControls()
        UIManager:setDirty(self.owner.menu_container, "ui")
        return true
    end
    function self.menu:onPrevPage()
        if self.page > 1 then
            return self:onGotoPage(self.page - 1)
        end
        return true
    end
    function self.menu:onNextPage()
        if self.page < self.page_num then
            return self:onGotoPage(self.page + 1)
        end
        return true
    end
    function self.menu:onMenuSelect(item, pos)
        if self.owner.mode == "toc" and item.has_children and pos and pos.x
                and pos.x < self.owner.toggle_width / self.owner.panel_width then
            self.owner:_toggleTocNode(item.toc_index)
            return true
        end
        if self.owner.mode == "fonts" then
            self.owner:_selectFont(item)
            return true
        end
        self.owner:_goto(item)
        return true
    end
    function self.menu:onMenuHold(item)
        if self.owner.mode == "bookmarks" then
            return self.owner:_showBookmarkActions(item)
        end
        return true
    end

    self:_installPageControls()
    if self.current_toc_index then
        Menu.onGotoPage(self.menu, self.menu:getPageNumber(self.current_toc_index))
        self:_updatePageControls()
    end
    local panel = VerticalGroup:new{
        self:_makeHeader(self.panel_width, header_height),
        self.menu,
    }
    local PanelContainer = self.position == "right" and RightContainer or LeftContainer
    local right_border = LineWidget:new{
        dimen = Geom:new{ x = 0, y = 0, w = 1, h = screen_size.h },
        background = Blitbuffer.COLOR_BLACK,
    }
    if self.position == "right" then
        right_border.overlap_align = "right"
    else
        right_border.overlap_offset = { self.panel_width - 1, 0 }
    end
    local content = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_size.w, h = screen_size.h },
        allow_mirroring = false,
        PanelContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = screen_size.w, h = screen_size.h },
            allow_mirroring = false,
            panel,
        },
        right_border,
    }
    self.menu_container = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = screen_size.w, h = screen_size.h },
        PanelContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = screen_size.w, h = screen_size.h },
            allow_mirroring = false,
            content,
        },
    }
    self.menu_container:registerTouchZones({
        {
            id = "sidetoc_outside_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = self.position == "right" and 0 or self.panel_width / screen_size.w,
                ratio_y = 0,
                ratio_w = 1 - self.panel_width / screen_size.w,
                ratio_h = 1,
            },
            handler = function()
                self:_closeMenu()
                return true
            end,
        },
    })
    UIManager:show(self.menu_container)
    return true
end

function SideToc:toggle()
    if not self.ui.document or not self.ui.view or not self.ui.toc then
        return false
    end
    if self.menu_container then
        self:_closeMenu()
    else
        self:_showMenu()
    end
end

function SideToc:onToggleSideToc()
    self:toggle()
end

function SideToc:onPageUpdate(pageno)
    self:_updateCurrentToc(pageno)
end

function SideToc:onPosUpdate(pos, pageno)
    self:_updateCurrentToc(pageno)
end

function SideToc:onCloseDocument()
    self:_closeMenu()
    self.txt_toc = nil
end

function SideToc:onCloseWidget()
    self:_closeMenu()
end

return SideToc
