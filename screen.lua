local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase        = require("screen_base")
local MenuHelper        = require("menu_helper")
local HidatoBoard       = lrequire("board")
local HidatoBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES = { 5, 6 }

-- ---------------------------------------------------------------------------
-- HidatoScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Hidato — Rules

Fill every empty cell of the grid with a number so that the sequence 1 to N is connected.

Rules:
• Numbers 1 to N fill the grid (some are given as clues).
• Each pair of consecutive numbers (k and k+1) must occupy cells that are orthogonally or diagonally adjacent.

Starting from 1, you should be able to trace a connected path through every number in order up to N.
Given numbers are fixed; deduce where all others go.
]])

local GAME_RULES_FR = [[
Hidato — Règles

Remplissez chaque case vide de la grille avec un numéro de sorte que la séquence 1 à N soit connectée.

Règles :
• Les numéros 1 à N remplissent la grille (certains sont donnés comme indices).
• Chaque paire de numéros consécutifs (k et k+1) doit occuper des cases orthogonalement ou diagonalement adjacentes.

En partant de 1, vous devez pouvoir tracer un chemin connecté à travers tous les numéros dans l'ordre jusqu'à N.
Les numéros donnés sont fixes ; déduisez où vont tous les autres.
]]

local HidatoScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function HidatoScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 5)
    self.board  = HidatoBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.selected      = nil
    self.pending_digit = nil   -- accumulates a two-digit number
    ScreenBase.init(self)
end

function HidatoScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function HidatoScreen:buildLayout()
    local n  = self.board.n
    local sw = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = HidatoBoardWidget:new{
        board          = self.board,
        onCellSelected = function(r, c) self:onCellSelected(r, c) end,
    }
    if self.selected then
        self.board_widget:setSelected(self.selected.r, self.selected.c)
    end

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    -- Top action bar
    local title_bar = self:buildTitleBar(_("Hidato"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getSizeButtonText(), callback = function() self:openSizeMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit keypad: digits 0-9 in two rows of 5, plus Erase
    -- Player types 1-2 digits to enter a number (e.g. "2" for 2, "25" for 25)
    local digit_row1 = {}
    for d = 1, 5 do
        local dv = d
        digit_row1[#digit_row1 + 1] = {
            text = tostring(dv),
            callback = function() self:onDigitKey(dv) end,
        }
    end
    local digit_row2 = {}
    for d = 6, 9 do
        local dv = d
        digit_row2[#digit_row2 + 1] = {
            text = tostring(dv),
            callback = function() self:onDigitKey(dv) end,
        }
    end
    digit_row2[#digit_row2 + 1] = {
        text = "0",
        callback = function() self:onDigitKey(0) end,
    }
    local digit_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = { digit_row1, digit_row2 },
    }

    -- Bottom action bar
    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("Erase"),  callback = function() self:onErase() end },
            { text = _("Check"),  callback = function() self:onCheck() end },
        }},
    }

    local footer = VerticalGroup:new{
        align = "center",
        digit_buttons,
        VerticalSpan:new{ width = Size.span.vertical_large },
        bottom_buttons,
    }

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            footer,
        }
        local content = HorizontalGroup:new{
            align  = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self:buildPortraitLayout(title_bar, content, footer)
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function HidatoScreen:onCellSelected(r, c)
    self.selected      = { r = r, c = c }
    self.pending_digit = nil
    self.board_widget:setSelected(r, c)
    self.board_widget:refresh()
    self:updateStatus()
end

-- Two-digit number entry: first key sets tens, second commits
function HidatoScreen:onDigitKey(d)
    if not self.selected then
        self:updateStatus(_("Tap a cell first."))
        return
    end
    local r, c = self.selected.r, self.selected.c
    local total = self.board.n * self.board.n

    if self.pending_digit == nil then
        -- Single-digit entry: commit immediately if <=9 and total<=9
        -- or start accumulation for larger grids
        if total <= 9 then
            self:_commitValue(r, c, d)
        else
            -- Start two-digit accumulation
            if d == 0 then
                -- Leading zero: ignore
                return
            end
            -- If d alone is a valid number (and grid is 5x5 max 25, so d<=9 is valid)
            -- Accumulate: wait for a second digit
            self.pending_digit = d
            self:updateStatus(T(_("Entering: %1 (tap another digit or Erase)"), d))
        end
    else
        -- Second digit: combine
        local v = self.pending_digit * 10 + d
        self.pending_digit = nil
        if v < 1 or v > total then
            self:updateStatus(T(_("Value %1 out of range (1-%2)."), v, total))
            return
        end
        self:_commitValue(r, c, v)
    end
end

function HidatoScreen:_commitValue(r, c, v)
    local total = self.board.n * self.board.n
    if v < 1 or v > total then
        self:updateStatus(T(_("Value %1 out of range (1-%2)."), v, total))
        return
    end
    local ok, err = self.board:setCell(r, c, v)
    if ok then
        self.plugin:saveState(self.board:serialize())
        if self.board:isSolved() then
            self:updateStatus(_("Congratulations! Puzzle solved!"))
        else
            self:updateStatus()
        end
    else
        self:updateStatus(err == "given" and _("Cannot edit a given cell.") or nil)
    end
    self.board_widget:refresh()
end

function HidatoScreen:onErase()
    self.pending_digit = nil
    if not self.selected then return end
    local r, c = self.selected.r, self.selected.c
    local ok, err = self.board:clearCell(r, c)
    if ok then
        self.plugin:saveState(self.board:serialize())
    elseif err == "given" then
        self:updateStatus(_("Cannot edit a given cell."))
        return
    end
    self.board_widget:refresh()
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function HidatoScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", 5)
    self.board = HidatoBoard:new{ n = n }
    self.board:generate(diff)
    self.selected      = nil
    self.pending_digit = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function HidatoScreen:onCheck()
    self.board:checkConflicts()
    self.board_widget:refresh()
    local remaining = self.board:getRemainingCells()
    if remaining > 0 then
        self:updateStatus(T(_("Check done. %1 cell(s) remaining."), remaining))
    elseif self.board:isSolved() then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    else
        self:updateStatus(_("Some cells are incorrect."))
    end
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function HidatoScreen:openSizeMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = {
            id   = sz,
            text = sz .. "\xC3\x97" .. sz,
        }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 5),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function HidatoScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function HidatoScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isSolved() then
        status = _("Congratulations! Puzzle solved!")
    else
        local remaining = self.board:getRemainingCells()
        local n         = self.board.n
        local diff      = self.plugin:getSetting("difficulty", "easy")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = T(_("%1\xC3\x97%2 (1\xE2\x80\x93%3) \xC2\xB7 %4 \xC2\xB7 Empty: %5"),
            n, n, n * n, label, remaining)
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function HidatoScreen:getSizeButtonText()
    local n = self.board.n
    return T(_("Size: %1"), n .. "\xC3\x97" .. n)
end

function HidatoScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

return HidatoScreen
