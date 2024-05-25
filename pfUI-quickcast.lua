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

    -- region helpers

    local _pfui_ui_mouseover = pfUI.uf.mouseover or {} -- store the original mouseover unit

    local _spell_target_units = (function()
        local x = { [1] = "player", [2] = "target", [3] = "mouseover" } -- prepare a list of units that can be used via spelltargetunit

        for i = 1, MAX_PARTY_MEMBERS do table.insert(x, "party" .. i) end
        for i = 1, MAX_RAID_MEMBERS do table.insert(x, "raid" .. i) end

        return x
    end)()

    local function tryTranslateUnitToGeneric(unit)
        for _, unitstr in pairs(_spell_target_units) do
            if UnitIsUnit(unit, unitstr) then -- if the mouseover unit and then partyX unit are the same then return partyX etc
                return unitstr
            end
        end

        return nil

        -- try to find a valid (friendly) unitstring that can be used for SpellTargetUnit(unit) to avoid another target switch
    end

    local function onCast(spell)
        local cvar_selfcast = GetCVar("AutoSelfCast")
        if cvar_selfcast == "0" then -- cast without selfcast cvar setting to allow spells to use spelltarget
            CastSpellByName(spell, nil)
            return
        end

        SetCVar("AutoSelfCast", "0")
        pcall(CastSpellByName, spell, nil)
        SetCVar("AutoSelfCast", cvar_selfcast)
    end

    -- endregion helpers

    -- region   /pfquickcast.any

    local function deduceIntendedTarget_forGenericSpells()
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
            and tryTranslateUnitToGeneric(unit)

        if unitstr or UnitIsUnit("target", unit) then -- no target change required   we can either use spell target or the unit that is already our current target
            _pfui_ui_mouseover.unit = (unitstr or "target")
            return _pfui_ui_mouseover.unit, false
        end

        _pfui_ui_mouseover.unit = unit
        return unit, true -- target change required

        -- 00  if target and mouseover are friendly units we cant use spell target as it would cast on the target instead of the mouseover
        --     however if the mouseover is friendly and the target is not we can try to obtain the best unitstring for the later SpellTargetUnit() call
    end

    local function setTargetIfNeededAndCast(spell, proper_target, use_target_toggle_workaround)
        if use_target_toggle_workaround then
            TargetUnit(proper_target)
        end

        onCast(spell)

        if SpellIsTargeting() then -- if the spell is awaiting a target to be specified then set spell target to proper_target
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

    _G.SLASH_PFQUICKCAST_ANY1 = "/pfquickcast"
    _G.SLASH_PFQUICKCAST_ANY2 = "/pfquickcast:any"
    _G.SLASH_PFQUICKCAST_ANY3 = "/pfquickcast.any"
    _G.SLASH_PFQUICKCAST_ANY4 = "/pfquickcast_any"
    function SlashCmdList.PFQUICKCAST_ANY(spell) -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spell then
            return
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forGenericSpells()
        if proper_target == nil then
            return
        end

        setTargetIfNeededAndCast(spell, proper_target, use_target_toggle_workaround) -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
    end

    -- endregion    /pfquickcast.any

    -- region   /pfquickcast.heal

    function pfUIQuickCast.OnHeal(spell, proper_target)
        -- keep the proper_target parameter even if its not needed per se this method calls to this
        -- method are intended to be hooked-upon/intercepted by third party heal-autoranking addons
        return onCast(spell)
    end

    local _player = "player"
    local _target = "target"
    local _mouseover = "mouseover"
    local _target_of_target = "targettarget"
    local function deduceIntendedTarget_forHealing()

        local mouseFrame = GetMouseFocus() -- unit frames mouse hovering
        if mouseFrame.label and mouseFrame.id then
            local unit = mouseFrame.label .. mouseFrame.id

            if UnitCanAssist(_player, unit) then
                local unitAsTeamUnit = tryTranslateUnitToGeneric(unit) -- "mouseover" -> "party1" or "raid1" etc    todo   examine if we really need this here ...
                if unitAsTeamUnit then
                    _pfui_ui_mouseover.unit = unitAsTeamUnit
                    return unitAsTeamUnit, false
                end

                _pfui_ui_mouseover.unit = unit -- shouldnt happen but just in case
                return unit, true
            end
        end

        if UnitCanAssist(_player, _mouseover) then --00 mouse hovering directly over friendly players? (meaning their toon - not their unit frame)
            _pfui_ui_mouseover.unit = _mouseover
            return _mouseover, UnitCanAssist(_player, _target) -- we need to use the target-swap hack here if and only if the currently selected target is friendly otherwise the heal will land on the currently selected friendly target
        end

        if UnitCanAssist(_player, _target) then -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not
            _pfui_ui_mouseover.unit = _target
            return _target, false
        end

        if UnitCanAssist(_player, _target_of_target) then -- the current target is not a friendly unit so we try to heal the target of the target   useful fallback behaviour both when soloing and when raid healing
            _pfui_ui_mouseover.unit = _target_of_target
            return _target_of_target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _mouseover) returns false but it doesnt matter really
        --     since noone is using this kind of mousehover to heal himself
    end

    local function setTargetIfNeededAndHeal(spell, proper_target, use_target_toggle_workaround)
        --print("** [pfUI-quickcast] setTargetIfNeededAndHeal#05a proper_target=" .. tostring(proper_target))
        --print("** [pfUI-quickcast] setTargetIfNeededAndHeal#05b use_target_toggle_workaround=" .. tostring(use_target_toggle_workaround))

        if use_target_toggle_workaround then
            TargetUnit(proper_target)
        end

        pfUIQuickCast.OnHeal(spell, proper_target) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

        if SpellIsTargeting() then                 -- if the spell is awaiting a target to be specified then set spell target to proper_target
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

    _G.SLASH_PFQUICKCAST_HEAL1 = "/pfquickcast:heal"
    _G.SLASH_PFQUICKCAST_HEAL2 = "/pfquickcast.heal"
    _G.SLASH_PFQUICKCAST_HEAL3 = "/pfquickcast_heal"
    _G.SLASH_PFQUICKCAST_HEAL4 = "/pfquickcastheal"
    function SlashCmdList.PFQUICKCAST_HEAL(spell) -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spell then
            return
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forHealing()
        if proper_target == nil then
            return
        end

        setTargetIfNeededAndHeal(spell, proper_target, use_target_toggle_workaround) -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
    end

    -- endregion /pfquickcast.heal
end)
