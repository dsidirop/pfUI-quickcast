-- to future maintainers    this implementation has been derived from the mouseover.lua module of pfUI version 5.4.5 (commit c6574adb)
-- to future maintainers    it makes sense to keep track of said original implementation in case of future changes and mirror them here whenever it makes sense

local _pfUIQuickCast = {}

function _pfUIQuickCast:New()
    local obj = {}

    setmetatable(obj, self)

    self.__index = self

    return obj
end

pfUIQuickCast = _pfUIQuickCast:New() -- globally exported singleton symbol for third party addons to be able to hook into the quickcast functionality

pfUI:RegisterModule("QuickCast", "vanilla", function()
    if not pfUI.uf then
        return -- unit frames are not loaded? abort
    end

    local _pfui_ui_mouseover = pfUI.uf.mouseover or {} -- store the original mouseover unit

    local _spell_target_units = (function()
        local x = { [1] = "player", [2] = "target", [3] = "mouseover" } -- prepare a list of units that can be used via spelltargetunit

        for i = 1, MAX_PARTY_MEMBERS do table.insert(x, "party" .. i) end
        for i = 1, MAX_RAID_MEMBERS do table.insert(x, "raid" .. i) end

        return x
    end)()

    local function getUnitString(unit)
        for _, unitstr in pairs(_spell_target_units) do
            if UnitIsUnit(unit, unitstr) then -- if the mouseover unit and then partyX unit are the same then return partyX etc
                return unitstr
            end
        end

        return nil

        -- try to find a valid (friendly) unitstring that can be used for SpellTargetUnit(unit) to avoid another target switch
    end

    local function deduceIntendedTarget()
        local unit = "mouseover"
        if not UnitExists(unit) then
            local frame = GetMouseFocus()
            if frame.label and frame.id then
                unit = frame.label .. frame.id
            elseif UnitExists("target") then
                unit = "target"
            elseif GetCVar("AutoSelfCast") == "1" then
                unit = "player"
            else
                return nil
            end
        end

        local unitstr = not UnitCanAssist("player", "target") -- 00
            and UnitCanAssist("player", unit)
            and getUnitString(unit)

        if unitstr or UnitIsUnit("target", unit) then -- no target change required   we can either use spell target or the unit that is already our current target
            _pfui_ui_mouseover.unit = (unitstr or "target")
            return _pfui_ui_mouseover.unit, false
        end

        _pfui_ui_mouseover.unit = unit
        return unit, true -- target change required

        -- 00  if target and mouseover are friendly units we cant use spell target as it would cast on the target instead of the mouseover
        --     however if the mouseover is friendly and the target is not we can try to obtain the best unitstring for the later SpellTargetUnit() call
    end

    function pfUIQuickCast.OnCast(spell, proper_target) -- keep the proper target parameter even if its not needed per se   this method is intended to be hooked upon by third party addons
        local cvar_selfcast = GetCVar("AutoSelfCast")
        if cvar_selfcast == "0" then                -- cast without selfcast cvar setting to allow spells to use spelltarget
            CastSpellByName(spell, nil)
            return
        end

        SetCVar("AutoSelfCast", "0")
        pcall(CastSpellByName, spell, nil)
        SetCVar("AutoSelfCast", cvar_selfcast)
    end

    local function setTargetIfNeededAndCast(spell, proper_target, use_target_toggle_workaround)
        if use_target_toggle_workaround then
            TargetUnit(proper_target)
        end

        pfUIQuickCast.OnCast(spell, proper_target) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

        if SpellIsTargeting() then             -- if the spell is awaiting a target to be specified then set spell target to proper_target
            SpellTargetUnit(proper_target)
        end

        if SpellIsTargeting() then -- at this point if we the spell is still awaiting for a target then either there was an error or targeting is impossible   in either case need to clean up spell target
            SpellStopTargeting()
        end

        _pfui_ui_mouseover.unit = nil -- remove temporary mouseover unit in the mouseover module of pfui

        if use_target_toggle_workaround then
            TargetLastTarget()
        end
    end

    _G.SLASH_PFQUICKCAST1 = "/pfquickcast"
    function SlashCmdList.PFQUICKCAST(spell) -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spell then
            return
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget()
        if proper_target == nil then
            return
        end

        setTargetIfNeededAndCast(spell, proper_target, use_target_toggle_workaround) -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
    end
end)
