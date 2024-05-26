-- to future maintainers    this implementation has been derived from the mouseover.lua module of pfUI version 5.4.5 (commit c6574adb)
-- to future maintainers    it makes sense to keep track of said original implementation in case of future changes and mirror them here whenever it makes sense

local _pfUIQuickCast = {}

function _pfUIQuickCast:New()
    local obj = {} -- in the future any configuration options can be stored here

    setmetatable(obj, self)

    self.__index = self

    return obj
end

pfUIQuickCast = _pfUIQuickCast:New() -- globally exported singleton symbol for third party addons to be able to hook into the quickcast functionality

pfUI:RegisterModule("QuickCast", "vanilla", function()
    -- region helpers

    local pairs_ = _G.pairs
    local getCVar_ = _G.GetCVar
    local getSpellCooldown_ = _G.GetSpellCooldown
    
    local pfGetSpellInfo_ = _G.pfUI.api.libspell.GetSpellInfo
    local pfGetSpellIndex_ = _G.pfUI.api.libspell.GetSpellIndex

    local _player = "player"
    local _target = "target"
    local _mouseover = "mouseover"
    local _target_of_target = "targettarget"

    local _pfui_ui_mouseover = (pfUI and pfUI.uf and pfUI.uf.mouseover) or {} -- store the original mouseover module if its present or fallback to a placeholder

    local _spell_target_units = (function()
        local x = { [1] = _player, [2] = _target, [3] = _mouseover } -- prepare a list of units that can be used via spelltargetunit

        for i = 1, MAX_PARTY_MEMBERS do
            table.insert(x, "party" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS do
            table.insert(x, "raid" .. i)
        end

        return x
    end)()

    local function tryTranslateUnitToStandardSpellTargetUnit(unit)
        for _, spellTargetUnitName in pairs_(_spell_target_units) do
            if unit == spellTargetUnitName or UnitIsUnit(unit, spellTargetUnitName) then
                -- if the mouseover unit and the partyX unit are the one and the same target then return partyX etc
                return spellTargetUnitName
            end
        end

        return nil

        -- try to find a valid (friendly) unitstring that can be used for SpellTargetUnit(unit) to avoid another target switch
    end
    
    local function onSelfCast(spell)
        CastSpellByName(spell, 1)
    end

    local function onCast(spell, proper_target)
        if proper_target == _player then
            onSelfCast(spell) -- faster
            return
        end
        
        local cvar_selfcast = getCVar_("AutoSelfCast")
        if cvar_selfcast == "0" then
            -- cast without selfcast cvar setting to allow spells to use spelltarget
            CastSpellByName(spell, nil)
            return
        end

        SetCVar("AutoSelfCast", "0")
        pcall(CastSpellByName, spell, nil)
        SetCVar("AutoSelfCast", cvar_selfcast)
    end

    local _parsedSpellStringsCache = {}
    local function parseSpellsString(spellsString)
        if _parsedSpellStringsCache[spellsString] then
            return _parsedSpellStringsCache[spellsString]
        end

        local spellsArray = {}
        for spell in string.gfind(spellsString, "%s*([^,;]*[^,;])%s*") do
            table.insert(spellsArray, spell)
        end

        _parsedSpellStringsCache[spellsString] = spellsArray
        return spellsArray
    end
    
    local function isSpellUsable(spell)
        local _, rank = pfGetSpellInfo_(spell) -- cache-aware

        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [getSpellInfo()] spell='" .. tostring(spell) .. "'")
        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [getSpellInfo()] rank='" .. tostring(rank) .. "'")

        if not rank then
            return false -- check if the player indeed knows this spell   maybe he hasnt specced for it
        end

        local spellId, spellBookType = pfGetSpellIndex_(spell) -- cache-aware
        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [getSpellIndex()] spellID='" .. tostring(spellId) .. "'")

        if not spellId then
            return false -- spell not found   shouldnt happen here but just in case
        end

        local usedAtTimestamp = getSpellCooldown_(spellId, spellBookType)

        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [GetSpellCooldown()] start='" .. tostring(start) .. "'")
        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [GetSpellCooldown()] duration='" .. tostring(duration) .. "'")
        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [GetSpellCooldown()] alreadyActivated='" .. tostring(alreadyActivated) .. "'")
        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast] [GetSpellCooldown()] modRate='" .. tostring(modRate) .. "'")
        --print("")

        return usedAtTimestamp == 0 -- check if the spell is off cooldown
    end

    local function setTargetIfNeededAndCast(spellCastCallback, spellsString, proper_target, use_target_toggle_workaround, switch_back_to_previous_target_in_the_end)
        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] proper_target=" .. tostring(proper_target))
        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] use_target_toggle_workaround=" .. tostring(use_target_toggle_workaround))
        --print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] switch_back_to_previous_target_in_the_end=" .. tostring(switch_back_to_previous_target_in_the_end))

        if use_target_toggle_workaround then
            TargetUnit(proper_target)
        end

        _pfui_ui_mouseover.unit = proper_target

        local spellsArray = parseSpellsString(spellsString)
        local wasSpellCastSuccessful = false
        for _, spell in spellsArray do
            if isSpellUsable(spell) then
                spellCastCallback(spell, proper_target) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

                if proper_target == _player then -- self-casts are 99.9999% successful
                    wasSpellCastSuccessful = true
                    break
                end

                if SpellIsTargeting() then
                    -- if the spell is awaiting a target to be specified then set spell target to proper_target
                    SpellTargetUnit(proper_target)
                end

                wasSpellCastSuccessful = not SpellIsTargeting() -- todo  test that spells on cooldown are not considered as successfully cast
                if wasSpellCastSuccessful then
                    break
                end
            end
        end

        if use_target_toggle_workaround or switch_back_to_previous_target_in_the_end then
            -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] switching back target ...")
            TargetLastTarget()
        end

        _pfui_ui_mouseover.unit = nil -- remove temporary mouseover unit in the mouseover module of pfui

        if not wasSpellCastSuccessful then
            -- at this point if the spell is still awaiting for a target then either there was an error or targeting is impossible   in either case need to clean up spell target
            SpellStopTargeting()
            return ""
        end

        return spell
    end

    -- endregion helpers

    -- region   /pfquickcast.any

    local function deduceIntendedTarget_forGenericSpells()
        -- inspired by /pfcast implementation
        local unit = _mouseover
        if not UnitExists(unit) then
            local frame = GetMouseFocus()
            if frame.label and frame.id then
                unit = frame.label .. frame.id
            elseif UnitExists(_target) then
                unit = _target
            elseif getCVar_("AutoSelfCast") == "1" then
                unit = _player
            else
                return nil
            end
        end

        local unitstr = not UnitCanAssist(_player, _target) -- 00
                and UnitCanAssist(_player, unit)
                and tryTranslateUnitToStandardSpellTargetUnit(unit)

        if unitstr or UnitIsUnit(_target, unit) then
            -- no target change required   we can either use spell target or the unit that is already our current target
            _pfui_ui_mouseover.unit = (unitstr or _target)
            return _pfui_ui_mouseover.unit, false
        end

        _pfui_ui_mouseover.unit = unit
        return unit, true -- target change required

        -- 00  if target and mouseover are friendly units we cant use spell target as it would cast on the target instead of the mouseover
        --     however if the mouseover is friendly and the target is not we can try to obtain the best unitstring for the later SpellTargetUnit() call
    end

    _G.SLASH_PFQUICKCAST_ANY1 = "/pfquickcast@any"
    _G.SLASH_PFQUICKCAST_ANY2 = "/pfquickcast:any"
    _G.SLASH_PFQUICKCAST_ANY3 = "/pfquickcast.any"
    _G.SLASH_PFQUICKCAST_ANY4 = "/pfquickcast_any"
    _G.SLASH_PFQUICKCAST_ANY5 = "/pfquickcast"
    function SlashCmdList.PFQUICKCAST_ANY(spell)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spell then
            return
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forGenericSpells()
        if proper_target == nil then
            return
        end

        return setTargetIfNeededAndCast(onCast, spell, proper_target, use_target_toggle_workaround) -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
    end

    -- endregion    /pfquickcast.any

    -- region   /pfquickcast:heal  and  :selfheal

    function pfUIQuickCast.OnHeal(spell, proper_target)
        -- keep the proper_target parameter even if its not needed per se this method   we want
        -- calls to this method to be hooked-upon/intercepted by third party heal-autoranking addons
        return onCast(spell, proper_target)
    end

    local function deduceIntendedTarget_forFriendlies()
        local mouseFrame = GetMouseFocus() -- unit frames mouse hovering
        if mouseFrame.label and mouseFrame.id then
            local unit = mouseFrame.label .. mouseFrame.id
            if UnitCanAssist(_player, unit) then
                local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(unit) -- _mouseover -> "party1" or "raid1" etc    todo   examine if we really need this here ...
                if unitAsTeamUnit then
                    return unitAsTeamUnit, false
                end

                return unit, true, false
            end
        end

        if UnitCanAssist(_player, _mouseover) then
            --00 mouse hovering directly over friendly players? (meaning their toon - not their unit frame)
            return _mouseover, UnitCanAssist(_player, _target), false --00 we need to use the target-swap hack here if and only if the currently selected target is friendly otherwise the heal will land on the currently selected friendly target
        end

        if UnitCanAssist(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not
            return _target, false, false
        end

        if UnitCanAssist(_player, _target_of_target) then
            -- at this point the current target is not a friendly unit so we try to heal the target of the target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _mouseover) returns false but it doesnt matter really
        --     since noone is using this kind of mousehover to heal himself
    end

    _G.SLASH_PFQUICKCAST_HEAL1 = "/pfquickcast@heal"
    _G.SLASH_PFQUICKCAST_HEAL2 = "/pfquickcast:heal"
    _G.SLASH_PFQUICKCAST_HEAL3 = "/pfquickcast.heal"
    _G.SLASH_PFQUICKCAST_HEAL4 = "/pfquickcast_heal"
    _G.SLASH_PFQUICKCAST_HEAL5 = "/pfquickcastheal"
    function SlashCmdList.PFQUICKCAST_HEAL(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return ""
        end

        local proper_target, use_target_toggle_workaround, switch_back_to_previous_target_in_the_end = deduceIntendedTarget_forFriendlies()
        if proper_target == nil then
            return ""
        end

        return setTargetIfNeededAndCast(pfUIQuickCast.OnHeal, spellsString, proper_target, use_target_toggle_workaround, switch_back_to_previous_target_in_the_end) -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
    end

    _G.SLASH_PFQUICKCAST_SELFHEAL1 = "/pfquickcast@selfheal"
    _G.SLASH_PFQUICKCAST_SELFHEAL2 = "/pfquickcast:selfheal"
    _G.SLASH_PFQUICKCAST_SELFHEAL3 = "/pfquickcast.selfheal"
    _G.SLASH_PFQUICKCAST_SELFHEAL4 = "/pfquickcast_selfheal"
    _G.SLASH_PFQUICKCAST_SELFHEAL5 = "/pfquickcastselfheal"
    function SlashCmdList.PFQUICKCAST_SELFHEAL(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return ""
        end

        return setTargetIfNeededAndCast(pfUIQuickCast.OnHeal, spellsString, _player, false) -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
    end

    -- endregion /pfquickcast@heal and :selfheal

    -- region /pfquickcast@self
    
    _G.SLASH_PFQUICKCAST_SELF1 = "/pfquickcast@self"
    _G.SLASH_PFQUICKCAST_SELF2 = "/pfquickcast:self"
    _G.SLASH_PFQUICKCAST_SELF3 = "/pfquickcast.self"
    _G.SLASH_PFQUICKCAST_SELF4 = "/pfquickcast_self"
    _G.SLASH_PFQUICKCAST_SELF5 = "/pfquickcastself"
    function SlashCmdList.PFQUICKCAST_SELF(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return ""
        end

        return setTargetIfNeededAndCast(onSelfCast, spellsString, _player, false)
    end

    -- endregion /pfquickcast@heal and :self
    
    -- region /pfquickcast@friendlies

    _G.SLASH_PFQUICKCAST_FRIENDLIES1 = "/pfquickcast@friendlies"
    _G.SLASH_PFQUICKCAST_FRIENDLIES2 = "/pfquickcast:friendlies"
    _G.SLASH_PFQUICKCAST_FRIENDLIES3 = "/pfquickcast.friendlies"
    _G.SLASH_PFQUICKCAST_FRIENDLIES4 = "/pfquickcast_friendlies"
    _G.SLASH_PFQUICKCAST_FRIENDLIES5 = "/pfquickcastfriendlies"
    function SlashCmdList.PFQUICKCAST_FRIENDLIES(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return ""
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forFriendlies()
        if proper_target == nil then
            return ""
        end

        return setTargetIfNeededAndCast(onCast, spellsString, proper_target, use_target_toggle_workaround)
    end

    -- endregion /pfquickcast@friendlies

    -- region /pfquickcast@hostiles

    local function deduceIntendedTarget_forHostiles()
        -- todo   at some point this could be merged with deduceIntendedTarget_forFriendlies 
        local mouseFrame = GetMouseFocus() -- unit frames mouse hovering
        if mouseFrame.label and mouseFrame.id then
            local unit = mouseFrame.label .. mouseFrame.id

            if not UnitIsFriend(_player, unit) then
                -- local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(unit) -- no point to do that here    it only makes sense for friendly units not hostile ones

                return unit, true -- todo   confirm that we need the target-switch hack here for hostile spells
            end

            if UnitIsFriend(unit, _target) then
                -- here the mouse-focused unit is friendly but its attacking a hostile unit so we can try casting on that one

                TargetUnit(unit) -- todo   examine if this approach works as intended
                return _target_of_target, false, true
            end
        end

        if UnitExists(_mouseover) and not UnitIsFriend(_player, _mouseover) then
            --00 mouse hovering directly over hostiles? (meaning their toon - not their unit frame)
            return _mouseover, not UnitCanAssist(_player, _target) --00 we need to use the target-swap hack here if and only if the currently selected target is hostile otherwise the spell will land on the currently selected enemy target
        end

        if not UnitIsFriend(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not
            return _target, false
        end

        if not UnitIsFriend(_player, _target_of_target) then
            -- at this point the current target is a friendly unit so we try to spell-cast on its own hostile target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _mouseover) returns false but it doesnt matter really
        --     since noone is using this kind of mousehover to heal himself
    end

    _G.SLASH_PFQUICKCAST_HOSTILES1 = "/pfquickcast@hostiles"
    _G.SLASH_PFQUICKCAST_HOSTILES2 = "/pfquickcast:hostiles"
    _G.SLASH_PFQUICKCAST_HOSTILES3 = "/pfquickcast.hostiles"
    _G.SLASH_PFQUICKCAST_HOSTILES4 = "/pfquickcast_hostiles"
    _G.SLASH_PFQUICKCAST_HOSTILES5 = "/pfquickcasthostiles"
    function SlashCmdList.PFQUICKCAST_HOSTILES(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return ""
        end

        local proper_target, use_target_toggle_workaround, switch_back_to_previous_target_in_the_end  = deduceIntendedTarget_forHostiles()
        if proper_target == nil then
            return ""
        end

        return setTargetIfNeededAndCast(onCast, spellsString, proper_target, use_target_toggle_workaround, switch_back_to_previous_target_in_the_end)
    end

    -- endregion /pfquickcast@hostiles
end)
