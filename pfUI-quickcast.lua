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
            CastSpellByName(spell, 1) -- faster
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
        local spellRawName, rank = pfGetSpellInfo_(spell) -- cache-aware

        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spell='" .. tostring(spell) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] rank='" .. tostring(rank) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spellRawName='" .. tostring(spellRawName) .. "'")

        if not rank then
            return false -- check if the player indeed knows this spell   maybe he hasnt specced for it
        end

        local spellId, spellBookType = pfGetSpellIndex_(spellRawName) -- cache-aware
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellIndex_()] spellID='" .. tostring(spellId) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellIndex_()] spellBookType='" .. tostring(spellBookType) .. "'")

        if not spellId then
            return false -- spell not found   shouldnt happen here but just in case
        end

        local usedAtTimestamp = getSpellCooldown_(spellId, spellBookType)

        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] start='" .. tostring(start) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] duration='" .. tostring(duration) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] alreadyActivated='" .. tostring(alreadyActivated) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] modRate='" .. tostring(modRate) .. "'")
        -- print("")

        return usedAtTimestamp == 0 -- check if the spell is off cooldown
    end

    local function setTargetIfNeededAndCast(
            spellCastCallback,
            spellsString,
            proper_target,
            use_target_toggle_workaround
    )
        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] spellsString=" .. tostring(spellsString))
        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] proper_target=" .. tostring(proper_target))
        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] use_target_toggle_workaround=" .. tostring(use_target_toggle_workaround))

        if use_target_toggle_workaround then
            TargetUnit(proper_target)
        end

        _pfui_ui_mouseover.unit = proper_target

        local spellsArray = parseSpellsString(spellsString)
        local spellThatQualified = nil
        local wasSpellCastSuccessful = false
        for _, spell in spellsArray do
            if isSpellUsable(spell) then
                -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] spell=" .. tostring(spell))
                spellCastCallback(spell, proper_target) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

                if proper_target == _player then -- self-casts are 99.9999% successful unless you're low on mana   currently we have problems detecting mana shortages
                    spellThatQualified = spell
                    wasSpellCastSuccessful = true
                    break
                end

                -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] SpellIsTargeting()=" .. tostring(SpellIsTargeting()))
                if SpellIsTargeting() then
                    -- if the spell is awaiting a target to be specified then set spell target to proper_target
                    SpellTargetUnit(proper_target)
                end

                wasSpellCastSuccessful = not SpellIsTargeting() -- todo  test that spells on cooldown are not considered as successfully cast
                if wasSpellCastSuccessful then
                    spellThatQualified = spell
                    break
                end
            end
        end

        if use_target_toggle_workaround then
            -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] switching back target ...")
            TargetLastTarget()
        end

        _pfui_ui_mouseover.unit = nil -- remove temporary mouseover unit in the mouseover module of pfui

        -- print("** [pfUI-quickcast] [setTargetIfNeededAndCast()] wasSpellCastSuccessful=" .. tostring(wasSpellCastSuccessful))
        if not wasSpellCastSuccessful then
            -- at this point if the spell is still awaiting for a target then either there was an error or targeting is impossible   in either case need to clean up spell target
            SpellStopTargeting()
            return nil
        end

        return spellThatQualified
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

        return setTargetIfNeededAndCast(
                onCast, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spell,
                proper_target,
                use_target_toggle_workaround
        )
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

                return unit, true
            end

        end
        
        -- UnitExists(_mouseover) no need to check this here
        if UnitCanAssist(_player, _mouseover) then
            --00 mouse hovering directly over friendly players? (meaning their toon - not their unit frame)
            return _mouseover, UnitCanAssist(_player, _target) --00 we need to use the target-swap hack here if and only if the currently selected target is friendly otherwise the heal will land on the currently selected friendly target
        end

        if UnitCanAssist(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not
            return _target, false
        end

        if UnitCanAssist(_player, _target_of_target) then
            -- at this point the current target is not a friendly unit so we try to heal the target of the target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false
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
            return nil
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forFriendlies()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(
                pfUIQuickCast.OnHeal, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
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
            return nil
        end

        return setTargetIfNeededAndCast(
                pfUIQuickCast.OnHeal, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spellsString,
                _player,
                false
        )
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
            return nil
        end

        return setTargetIfNeededAndCast(onSelfCast, spellsString, _player, false)
    end

    -- endregion /pfquickcast@heal and :self
    
    -- region /pfquickcast@friends
    
    _G.SLASH_PFQUICKCAST_FRIENDS1 = "/pfquickcast@friends"
    _G.SLASH_PFQUICKCAST_FRIENDS2 = "/pfquickcast:friends"
    _G.SLASH_PFQUICKCAST_FRIENDS3 = "/pfquickcast.friends"
    _G.SLASH_PFQUICKCAST_FRIENDS4 = "/pfquickcast_friends"
    _G.SLASH_PFQUICKCAST_FRIENDS5 = "/pfquickcastfriends"
    function SlashCmdList.PFQUICKCAST_FRIENDS(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forFriendlies()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(onCast, spellsString, proper_target, use_target_toggle_workaround)
    end

    -- endregion /pfquickcast@friends

    -- region /pfquickcast@hostiles

    local function deduceIntendedTarget_forHostiles()
        -- print("********")
        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 000")
        
        local mouseFrame = GetMouseFocus() -- unit frames mouse hovering
        if mouseFrame.label and mouseFrame.id then
            local unit = mouseFrame.label .. mouseFrame.id

            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 010 hostile unit=" .. tostring(unit))

            if UnitExists(unit) and not UnitIsFriend(_player, unit) and not UnitIsUnit(_target, unit) then
                -- local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(unit) -- no point to do that here    it only makes sense for friendly units not hostile ones
                
                -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 020 hostile unit=" .. tostring(unit) .. ", unitAsTeamUnit=" .. tostring(unitAsTeamUnit))

                return unit, false
            end

            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 030")
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 040 UnitExists(_mouseover)="..tostring(UnitExists(_mouseover)))
        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 040 not UnitIsFriend(_player, _mouseover)="..tostring(not UnitIsFriend(_player, _mouseover)))
        if UnitExists(_mouseover) and not UnitIsFriend(_player, _mouseover) and not UnitIsUnit(_target, _mouseover) then
            --00 mouse hovering directly over hostiles? (meaning their toon - not their unit frame)

            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 050    UnitName(_mouseover)='" .. UnitName(_mouseover) .. "'")
            
            return _mouseover, true
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 060")
        if UnitExists(_target) and not UnitIsFriend(_player, _target) then
            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 070")
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not
            return _target, false
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 080")
        if not UnitIsFriend(_player, _target_of_target) then
            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 090")
            
            -- at this point the current target is a friendly unit so we try to spell-cast on its own hostile target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forHostiles] 100")

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
            return nil
        end

        local proper_target, use_target_toggle_workaround  = deduceIntendedTarget_forHostiles()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(onCast, spellsString, proper_target, use_target_toggle_workaround)
    end

    -- endregion /pfquickcast@hostiles
end)
