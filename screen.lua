local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

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

Tap a cell to select it, then type its number as two digits on the keypad: 0 then 7 for 7, 1 then 5 for 15.
]])

local GAME_RULES_FR = [[
Hidato — Règles

Remplissez chaque case vide de la grille avec un numéro de sorte que la séquence 1 à N soit connectée.

Règles :
• Les numéros 1 à N remplissent la grille (certains sont donnés comme indices).
• Chaque paire de numéros consécutifs (k et k+1) doit occuper des cases orthogonalement ou diagonalement adjacentes.

En partant de 1, vous devez pouvoir tracer un chemin connecté à travers tous les numéros dans l'ordre jusqu'à N.
Les numéros donnés sont fixes ; déduisez où vont tous les autres.

Appuyez sur une case pour la sélectionner, puis tapez son numéro en deux chiffres sur le clavier : 0 puis 7 pour 7, 1 puis 5 pour 15.
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
    local is_landscape = self:isLandscape()

    -- Top action bar
    local title_bar = self:buildTitleBar(_("Hidato"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getSizeButtonText(), callback = function() self:openSizeMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Digit keypad 1-9 and 0, two rows of 5.
    -- Player types 1-2 digits to enter a number (e.g. "2" for 2, "25" for 25)
    local keys = {}
    for _, d in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 }) do
        local dv = d
        keys[#keys + 1] = { text = tostring(d), callback = function() self:onDigitKey(dv) end }
    end
    local number_pad = self:buildNumberPad(keys)

    -- Bottom bar
    local action_bar = self:buildActionBar({
        { text = _("Erase"), callback = function() self:onErase() end },
        { text = _("Check"), callback = function() self:onCheck() end },
        { text = _("Hint"),  callback = function() self:onHint() end },
    })

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        number_pad,
        VerticalSpan:new{ width = Size.span.vertical_default },
        action_bar,
    }

    -- The widget draws its own outer border, so the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = HidatoBoardWidget:new{
        max_size       = math.min(budget_w, budget_h) - 2 * frame_pad,
        board          = self.board,
        onCellSelected = function(r, c) self:onCellSelected(r, c) end,
    }
    if self.selected then
        self.board_widget:setSelected(self.selected.r, self.selected.c)
    end
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
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
            -- Start two-digit accumulation. A leading "0" is allowed here:
            -- it's the only way to reach a single-digit value (1-9), since
            -- every other first digit becomes the tens place -- "0" then
            -- "5" combines to 5, just like "1" then "0" combines to 10.
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
        title     = _("Select size"),
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
        status = self:joinStatus(T("%1×%2", n, n), label, T(_("Empty: %1"), remaining))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends with a status update, so this
    -- is where the bar learns that the round ended (or was undone).
    self:refreshActionBar()
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
    return T(_("Difficulty: %1"), label)
end

function HidatoScreen:isRoundOver()
    return self.board:isSolved()
end

return HidatoScreen
