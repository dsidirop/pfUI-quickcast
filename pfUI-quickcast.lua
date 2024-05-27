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
        local spellsArray = _parsedSpellStringsCache[spellsString]
        if spellsArray ~= nil then
            return spellsArray
        end

        spellsArray = {}
        for spell in string.gfind(spellsString, "%s*([^,;]*[^,;])%s*") do
            if spell ~= "" then -- ignore empty strings
                table.insert(spellsArray, spell)
            end
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
        local spellThatQualified
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

    -- region   /pfquickcast:heal  and  :healself

    function pfUIQuickCast.OnHeal(spell, proper_target)
        -- keep the proper_target parameter even if its not needed per se this method   we want
        -- calls to this method to be hooked-upon/intercepted by third party heal-autoranking addons
        return onCast(spell, proper_target)
    end

    local function deduceIntendedTarget_forFriendlySpells()
        local mouseFrame = GetMouseFocus() -- unit-frames mouse-hovering
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
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forFriendlySpells()
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

    _G.SLASH_PFQUICKCAST_HEAL_SELF1 = "/pfquickcast@healself"
    _G.SLASH_PFQUICKCAST_HEAL_SELF2 = "/pfquickcast:healself"
    _G.SLASH_PFQUICKCAST_HEAL_SELF3 = "/pfquickcast.healself"
    _G.SLASH_PFQUICKCAST_HEAL_SELF4 = "/pfquickcast_healself"
    _G.SLASH_PFQUICKCAST_HEAL_SELF5 = "/pfquickcasthealself"
    function SlashCmdList.PFQUICKCAST_HEAL_SELF(spellsString)
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

    -- endregion /pfquickcast@heal and :healself

    -- region /pfquickcast@self
    
    _G.SLASH_PFQUICKCAST_SELF1 = "/pfquickcast@self"
    _G.SLASH_PFQUICKCAST_SELF2 = "/pfquickcast:self"
    _G.SLASH_PFQUICKCAST_SELF3 = "/pfquickcast.self"
    _G.SLASH_PFQUICKCAST_SELF4 = "/pfquickcast_self"
    _G.SLASH_PFQUICKCAST_SELF5 = "/pfquickcastself"
    function SlashCmdList.PFQUICKCAST_SELF(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        return setTargetIfNeededAndCast(onSelfCast, spellsString, _player, false)
    end

    -- endregion /pfquickcast@heal and :self
    
    -- region /pfquickcast@friend
    
    _G.SLASH_PFQUICKCAST_FRIEND1 = "/pfquickcast@friend"
    _G.SLASH_PFQUICKCAST_FRIEND2 = "/pfquickcast:friend"
    _G.SLASH_PFQUICKCAST_FRIEND3 = "/pfquickcast.friend"
    _G.SLASH_PFQUICKCAST_FRIEND4 = "/pfquickcast_friend"
    _G.SLASH_PFQUICKCAST_FRIEND5 = "/pfquickcastfriend"
    function SlashCmdList.PFQUICKCAST_FRIEND(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forFriendlySpells()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(
                onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@friend

    -- region /pfquickcast@enemy

    local function deduceIntendedTarget_forOffensiveSpells()
        -- print("********")
        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 000")
        
        local mouseFrame = GetMouseFocus() -- unit-frames mouse-hovering
        if mouseFrame.label and mouseFrame.id then
            local unit = mouseFrame.label .. mouseFrame.id

            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 010 enemy unit=" .. tostring(unit))

            if UnitExists(unit) and not UnitIsFriend(_player, unit) and not UnitIsUnit(_target, unit) then
                -- local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(unit) -- no point to do that here    it only makes sense for friendly units not enemy ones
                
                -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 020 enemy unit=" .. tostring(unit) .. ", unitAsTeamUnit=" .. tostring(unitAsTeamUnit))

                return unit, false
            end

            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 030")
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 040 UnitExists(_mouseover)="..tostring(UnitExists(_mouseover)))
        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 040 not UnitIsFriend(_player, _mouseover)="..tostring(not UnitIsFriend(_player, _mouseover)))
        if UnitExists(_mouseover) and not UnitIsFriend(_player, _mouseover) and not UnitIsUnit(_target, _mouseover) then
            --00 mouse hovering directly over a enemy toon in the game-world?

            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 050    UnitName(_mouseover)='" .. UnitName(_mouseover) .. "'")
            
            return _mouseover, true
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 060")
        if UnitExists(_target) and not UnitIsFriend(_player, _target) then
            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 070")
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not
            return _target, false
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 080")
        if not UnitIsFriend(_player, _target_of_target) then
            -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 090")
            
            -- at this point the current target is a friendly unit so we try to spell-cast on its own enemy target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false
        end

        -- print("** [pfUI-quickcast] [deduceIntendedTarget_forOffensiveSpells] 100")

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _mouseover) returns false but it doesnt matter really
        --     since noone is using this kind of mousehover to heal himself
    end

    _G.SLASH_PFQUICKCAST_ENEMY1 = "/pfquickcast@enemy"
    _G.SLASH_PFQUICKCAST_ENEMY2 = "/pfquickcast:enemy"
    _G.SLASH_PFQUICKCAST_ENEMY3 = "/pfquickcast.enemy"
    _G.SLASH_PFQUICKCAST_ENEMY4 = "/pfquickcast_enemy"
    _G.SLASH_PFQUICKCAST_ENEMY5 = "/pfquickcastenemy"
    function SlashCmdList.PFQUICKCAST_ENEMY(spellsString)
        -- we export this function to the global scope so as to make it accessible to users lua scripts
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround  = deduceIntendedTarget_forOffensiveSpells()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(
                onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@enemy

    -- region /pfquickcast@healtote

    local function deduceIntendedTarget_forFriendlyTargetOfTheEnemy()

        local gotEnemyCandidateFromMouseHover = false

        local mouseFrame = GetMouseFocus()
        local mouseFrameUnit = mouseFrame.label and mouseFrame.id
                and (mouseFrame.label .. mouseFrame.id)
                or nil
        if mouseFrameUnit and not UnitIsUnit(mouseFrameUnit, _target) then

            if not UnitExists(mouseFrameUnit) --                  unit-frames mouse-hovering   
                    or UnitIsFriend(_player, mouseFrameUnit) --   we check that the mouse-hover unit-frame is alive and enemy
                    or UnitIsDead(mouseFrameUnit) then --         if its not then we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseHover = true
            TargetUnit(mouseFrameUnit)

        elseif UnitExists(_mouseover) and not UnitIsUnit(_mouseover, _target) then

            if UnitIsFriend(_player, _mouseover) --   is the mouse hovering directly over a enemy toon in the game world?
                    or UnitIsDead(_mouseover) then -- we check if its enemy and alive   if its not we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseHover = true
            TargetUnit(_mouseover)
        end

        if (gotEnemyCandidateFromMouseHover or not UnitIsFriend(_player, _target))
                and UnitCanAssist(_player, _target_of_target)
                and not UnitIsDead(_target_of_target) then
            local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- free world pvp situations without raid
        end
        
        if gotEnemyCandidateFromMouseHover then
            TargetLastTarget()
        end

        return nil, false -- no valid target found
    end

    _G.SLASH_PFQUICKCAST_HEAL_TOTE1 = "/pfquickcast@healtote"
    _G.SLASH_PFQUICKCAST_HEAL_TOTE2 = "/pfquickcast:healtote"
    _G.SLASH_PFQUICKCAST_HEAL_TOTE3 = "/pfquickcast.healtote"
    _G.SLASH_PFQUICKCAST_HEAL_TOTE4 = "/pfquickcast_healtote"
    _G.SLASH_PFQUICKCAST_HEAL_TOTE5 = "/pfquickcasthealtote"
    function SlashCmdList.PFQUICKCAST_HEAL_TOTE(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround  = deduceIntendedTarget_forFriendlyTargetOfTheEnemy()
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

    -- endregion /pfquickcast@healtote

    -- region /pfquickcast@enemytbf

    local function deduceIntendedTarget_forEnemyTargetedByFriend()

        local gotFriendCandidateFromMouseHover = false

        local mouseFrame = GetMouseFocus()
        local mouseFrameUnit = mouseFrame.label and mouseFrame.id
                and (mouseFrame.label .. mouseFrame.id)
                or nil
        if mouseFrameUnit and not UnitIsUnit(mouseFrameUnit, _target) then

            if not UnitExists(mouseFrameUnit) -- unit-frames mouse-hovering   
                    or not UnitIsFriend(_player, mouseFrameUnit)
                    or UnitIsDead(mouseFrameUnit) then
                return nil, false
            end

            gotFriendCandidateFromMouseHover = true
            TargetUnit(mouseFrameUnit)

        elseif UnitExists(_mouseover) and not UnitIsUnit(_mouseover, _target) then

            if not UnitIsFriend(_player, _mouseover) --   is the mouse hovering directly over a enemy toon in the game world?
                    or UnitIsDead(_mouseover) then --     we check if its enemy and alive   if its not we guard close
                return nil, false
            end

            gotFriendCandidateFromMouseHover = true
            TargetUnit(_mouseover)
        end

        if (gotFriendCandidateFromMouseHover or UnitIsFriend(_player, _target))
                and not UnitIsFriend(_player, _target_of_target)
                and not UnitIsDead(_target_of_target) then
            local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- free world pvp situations without raid
        end

        if gotFriendCandidateFromMouseHover then
            TargetLastTarget()
        end

        return nil, false -- no valid target found
    end

    _G.SLASH_PFQUICKCAST_ENEMY_TBF1 = "/pfquickcast@enemytbf"
    _G.SLASH_PFQUICKCAST_ENEMY_TBF2 = "/pfquickcast:enemytbf"
    _G.SLASH_PFQUICKCAST_ENEMY_TBF3 = "/pfquickcast.enemytbf"
    _G.SLASH_PFQUICKCAST_ENEMY_TBF4 = "/pfquickcast_enemytbf"
    _G.SLASH_PFQUICKCAST_ENEMY_TBF5 = "/pfquickcastenemytbf"
    function SlashCmdList.PFQUICKCAST_ENEMY_TBF(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround  = deduceIntendedTarget_forEnemyTargetedByFriend()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(
                onCast, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@enemytbf

end)
