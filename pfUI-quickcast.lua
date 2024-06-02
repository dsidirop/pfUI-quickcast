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

    local _pet = "pet"
    local _player = "player"
    local _target = "target"
    local _toon_mouse_hover = "mouseover"
    local _target_of_target = "targettarget"

    local _pfui_ui_mouseover = (pfUI and pfUI.uf and pfUI.uf.mouseover) or {} -- store the original mouseover module if its present or fallback to a placeholder

    local _solo_spell_target_units = (function()
        local standardSpellTargets = { }

        table.insert(standardSpellTargets, _target) -- most common target so we check this first
        table.insert(standardSpellTargets, _player) -- these are the most rare mouse-hovering scenarios so we check them last
        table.insert(standardSpellTargets, _pet)
        
        -- table.insert(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local _party_spell_target_units = (function()
        local standardSpellTargets = { }

        table.insert(standardSpellTargets, _target) -- most common target so we check this first
        table.insert(standardSpellTargets, _player)

        for i = 1, MAX_PARTY_MEMBERS do
            table.insert(standardSpellTargets, "party" .. i)
        end

        for i = 1, MAX_PARTY_MEMBERS do -- these are the most rare mouse-hovering scenarios so we check them last
            table.insert(standardSpellTargets, "partypet" .. i)
        end

        -- table.insert(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local _raid_spell_target_units = (function()
        -- https://wowpedia.fandom.com/wiki/UnitId   prepare a list of units that can be used via spelltargetunit in vanilla wow 1.12
        -- notice that we intentionally omitted 'mouseover' below as its causing problems without offering any real benefit

        local standardSpellTargets = { }

        table.insert(standardSpellTargets, _target) -- most common target so we check this first

        for i = 1, MAX_PARTY_MEMBERS do
            table.insert(standardSpellTargets, "party" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS do
            table.insert(standardSpellTargets, "raid" .. i)
        end

        for i = 1, MAX_PARTY_MEMBERS do -- pets are more rare targets 
            table.insert(standardSpellTargets, "partypet" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS do
            table.insert(standardSpellTargets, "raidpet" .. i)
        end

        table.insert(standardSpellTargets, _player) -- these are the most rare mouse-hovering scenarios so we check them last
        
        -- table.insert(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local function tryGetUnitOfFrameHovering()
        local mouseFrame = GetMouseFocus()
        return mouseFrame and mouseFrame.label and mouseFrame.id
                and (mouseFrame.label .. mouseFrame.id)
                or nil
    end

    local function tryTranslateUnitToStandardSpellTargetUnit(unit)
        local properSpellTargetUnits = UnitInRaid(unit) and _raid_spell_target_units
                or UnitInParty(unit) and _party_spell_target_units
                or _solo_spell_target_units
        
        for _, spellTargetUnitName in pairs_(properSpellTargetUnits) do
            if unit == spellTargetUnitName or UnitIsUnit(unit, spellTargetUnitName) then -- 00
                return spellTargetUnitName
            end
        end

        return nil

        --00  try to find a valid (friendly) unitstring that can be used for SpellTargetUnit(unit) to avoid another target switch
        --    if the given unit (p.e. mouseover) and the partyX unit are the one and the same target then return partyX etc
        --
        --    even though the check 'unit == spellTargetUnitName' is performed inside UnitIsUnit() we still need to check it here first
        --    because we want to avoid the function call to UnitIsUnit() altogether if the unit is the same as the spell target unit
    end
    
    local function onSelfCast(spellName, spellId, spellBookType, proper_target)
        CastSpellByName(spellName, 1)
    end

    local function onCast(spellName, spellId, spellBookType, proper_target)
        if proper_target == _player then
            CastSpellByName(spellName, 1) -- faster
            return
        end
        
        local cvar_selfcast = getCVar_("AutoSelfCast")
        if cvar_selfcast == "0" then
            -- cast without selfcast cvar setting to allow spells to use spelltarget
            CastSpell(spellId, spellBookType) -- faster using spellid
            return
        end

        SetCVar("AutoSelfCast", "0")
        pcall(CastSpell, spellId, spellBookType) -- faster using spellid
        SetCVar("AutoSelfCast", cvar_selfcast)
    end

    local function strmatch(input, patternString, ...)
        local variadicsArray = arg

        assert(patternString ~= nil, "patternString must not be nil")

        if patternString == "" then
            return nil
        end

        local results = {string.find(input, patternString, unpack(variadicsArray))}

        local startIndex = results[1]
        if startIndex == nil then
            -- no match
            return nil
        end

        local match01 = results[3]
        if match01 == nil then
            local endIndex = results[2]
            return string.sub(input, startIndex, endIndex) -- matched but without using captures   ("Foo 11 bar   ping pong"):match("Foo %d+ bar")
        end

        table.remove(results, 1) -- pop startIndex
        table.remove(results, 1) -- pop endIndex

        return unpack(results) -- matched with captures  ("Foo 11 bar   ping pong"):match("Foo (%d+) bar")
    end

    local function strtrim(input)
        return strmatch(input, '^%s*(.*%S)') or ''
    end

    local _parsedSpellStringsCache = {}
    local function parseSpellsString(spellsString)
        local spellsArray = _parsedSpellStringsCache[spellsString]
        if spellsArray ~= nil then
            return spellsArray
        end

        spellsArray = {}
        for spell in string.gfind(spellsString, "%s*([^,;]*[^,;])%s*") do
            spell = strtrim(spell)
            if spell ~= "" then -- ignore empty strings
                table.insert(spellsArray, spell)
            end
        end

        _parsedSpellStringsCache[spellsString] = spellsArray
        return spellsArray
    end
    
    local _non_self_castable_spells = { -- some spells report 0 min/max range but are not self-castable
        ["Maul"] = true,
        ["Slam"] = true,
        ["Holy Strike"] = true,
        ["Raptor Strike"] = true,
        ["Heroic Strike"] = true,
    }
    
    local function isSpellUsable(spell)
        local spellRawName, rank, _, _, minRange, maxRange, spellId, spellBookType = pfGetSpellInfo_(spell) -- cache-aware

        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spell='" .. tostring(spell) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] rank='" .. tostring(rank) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spellRawName='" .. tostring(spellRawName) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] minRange='" .. tostring(minRange) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] maxRange='" .. tostring(maxRange) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellIndex_()] spellID='" .. tostring(spellId) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellIndex_()] spellBookType='" .. tostring(spellBookType) .. "'")

        if not rank then
            return false -- check if the player indeed knows this spell   maybe he hasnt specced for it
        end

        if not spellId then -- older versions of pfui dont return the spellid and booktype so we need to add an additional step 
            spellId, spellBookType = pfGetSpellIndex_(spellRawName) -- cache-aware   todo   remove this around the end of 2025
        end

        if not spellId then
            return false -- spell not found   shouldnt happen here but just in case
        end

        local usedAtTimestamp = getSpellCooldown_(spellId, spellBookType)

        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] start='" .. tostring(start) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] duration='" .. tostring(duration) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] alreadyActivated='" .. tostring(alreadyActivated) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [getSpellCooldown_()] modRate='" .. tostring(modRate) .. "'")
        -- print("")

        return
        spellId,
        spellBookType,
        usedAtTimestamp == 0, -- check if the spell is off cooldown
        minRange == 0 and maxRange == 0 and _non_self_castable_spells[spellRawName] == nil -- check if the spell is only cast-on-self by sniffing the min/max ranges of it
    end

    local function setTargetIfNeededAndCast(
            spellCastCallback,
            spellsString,
            proper_target,
            use_target_toggle_workaround
    )
        local spellsArray = parseSpellsString(spellsString)
        
        local targetToggled = false
        local spellThatQualified
        local wasSpellCastSuccessful = false
        for _, spell in spellsArray do
            local spellId, spellBookType, canBeUsed, isSpellCastOnSelfOnly = isSpellUsable(spell)
            if canBeUsed then
                if use_target_toggle_workaround and not isSpellCastOnSelfOnly and not targetToggled then
                    targetToggled = true
                    TargetUnit(proper_target)
                    _pfui_ui_mouseover.unit = proper_target
                end
                
                local eventualTarget = isSpellCastOnSelfOnly
                        and _player
                        or proper_target

                spellCastCallback(spell, spellId, spellBookType, eventualTarget) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

                if eventualTarget == _player then -- self-casts are 99.9999% successful unless you're low on mana   currently we have problems detecting mana shortages   we live with this for now
                    spellThatQualified = spell
                    wasSpellCastSuccessful = true
                    break
                end

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

        if targetToggled then
            TargetLastTarget()
        end

        _pfui_ui_mouseover.unit = nil -- remove temporary mouseover unit in the mouseover module of pfui

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
        local unit = _toon_mouse_hover
        if not UnitExists(unit) then
            unit = tryGetUnitOfFrameHovering()
            if unit then
                -- nothing more to do
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
                onCast,
                spell,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion    /pfquickcast.any

    -- region   /pfquickcast:heal  and  :healself

    function pfUIQuickCast.OnHeal(spellName, spellId, spellBookType, proper_target)
        -- keep the proper_target parameter even if its not needed per se this method   we want
        -- calls to this method to be hooked-upon/intercepted by third party heal-autoranking addons
        return onCast(spellName, spellId, spellBookType, proper_target)
    end

    local function deduceIntendedTarget_forFriendlySpells()
        
        local unitOfFrameHovering = tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and UnitCanAssist(_player, unitOfFrameHovering) then
            
            local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(unitOfFrameHovering) -- we need to check  
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return unit, true
        end
        
        -- UnitExists(_mouseover) no need to check this here
        if UnitCanAssist(_player, _toon_mouse_hover) and not UnitIsDeadOrGhost(_toon_mouse_hover) then
            --00 mouse hovering directly over friendly player-toons in the game-world?

            if not UnitCanAssist(_player, _target) then -- if the current target is not friendly then we dont need to use the target-swap hack and mouseover is faster 
                return _toon_mouse_hover, false
            end
            
            local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(_toon_mouse_hover)
            if unitAsTeamUnit then -- _mouseover -> "party1" or "raid1" etc   it is much more efficient this way in a team context compared to having to use target-swap hack
                return unitAsTeamUnit, false
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
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

        return setTargetIfNeededAndCast(
                onSelfCast,
                spellsString,
                _player,
                false
        )
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

        if UnitExists(_toon_mouse_hover) -- for offensive spells it is more common to use world-mouseover rather than unit-frames mouse-hovering
                and not UnitIsFriend(_player, _toon_mouse_hover)
                and not UnitIsUnit(_toon_mouse_hover, _target)
                and not UnitIsDeadOrGhost(_toon_mouse_hover) then
            --00 mouse hovering directly over an enemy toon in the game-world?
            
            if UnitIsFriend(_player, _target) then
                -- if the current target is friendly then we dont need to use the target-swap hack   simply using mouseover is faster
                return _toon_mouse_hover, false
            end

            local mindControlledFriendTurnedHostile = tryTranslateUnitToStandardSpellTargetUnit(_toon_mouse_hover) -- todo   experiment also with party1target party2target etc and see if its supported indeed
            if mindControlledFriendTurnedHostile then --             this in fact does make sense because a raid member might get mind-controlled
                return mindControlledFriendTurnedHostile, false --   and turn hostile in which case we can and should avoid the target-swap hack
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is hostile   its very resource intensive but if we dont use the hack then the offensive spell will land on the currently selected hostile target
        end

        local unitOfFrameHovering = tryGetUnitOfFrameHovering()
        if unitOfFrameHovering
                and UnitExists(unitOfFrameHovering)
                and not UnitIsFriend(_player, unitOfFrameHovering)
                and not UnitIsUnit(_target, unitOfFrameHovering)
                and not UnitIsDeadOrGhost(unitOfFrameHovering) then
            -- local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(unitOfFrameHovering) -- no point to do that here    it only makes sense for friendly units not enemy ones

            return unitOfFrameHovering, false
        end
        
        if UnitExists(_target) and not UnitIsDeadOrGhost(_target) and not UnitIsFriend(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not

            return _target, false
        end

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

        local unitOfFrameHovering = tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and not UnitIsUnit(unitOfFrameHovering, _target) then

            if not UnitExists(unitOfFrameHovering) --                  unit-frames mouse-hovering   
                    or UnitIsFriend(_player, unitOfFrameHovering) --   we check that the mouse-hover unit-frame is alive and enemy
                    or UnitIsDeadOrGhost(unitOfFrameHovering) then --  if its not then we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseHover = true
            TargetUnit(unitOfFrameHovering)

        elseif UnitExists(_toon_mouse_hover) and not UnitIsUnit(_toon_mouse_hover, _target) then

            if UnitIsFriend(_player, _toon_mouse_hover) --   is the mouse hovering directly over a enemy toon in the game world?
                    or UnitIsDead(_toon_mouse_hover) then -- we check if its enemy and alive   if its not we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseHover = true
            TargetUnit(_toon_mouse_hover)
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

        local unitOfFrameHovering = tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and not UnitIsUnit(unitOfFrameHovering, _target) then

            if not UnitIsFriend(_player, unitOfFrameHovering) or UnitIsDeadOrGhost(unitOfFrameHovering) then
                return nil, false
            end

            gotFriendCandidateFromMouseHover = true
            TargetUnit(unitOfFrameHovering)

        elseif UnitExists(_toon_mouse_hover) and not UnitIsUnit(_toon_mouse_hover, _target) then

            if not UnitIsFriend(_player, _toon_mouse_hover) or UnitIsDeadOrGhost(_toon_mouse_hover) then
                return nil, false
            end

            gotFriendCandidateFromMouseHover = true
            TargetUnit(_toon_mouse_hover)
        end
        
        if (gotFriendCandidateFromMouseHover or UnitIsFriend(_player, _target))
                and not UnitIsFriend(_player, _target_of_target)
                and not UnitIsDeadOrGhost(_target_of_target) then
            local unitAsTeamUnit = tryTranslateUnitToStandardSpellTargetUnit(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- its vital to use the target-toggle-hack otherwise the offensive spell wont be cast at all
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
                onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@enemytbf

    -- region /pfquickcast@directenemy

    local function deduceIntendedTarget_forDirectEnemy()
        if not UnitExists(_target)
                and UnitExists(_toon_mouse_hover)
                and not UnitIsFriend(_player, _toon_mouse_hover)
                and not UnitIsDeadOrGhost(_toon_mouse_hover) then
            TargetUnit(_toon_mouse_hover)
            return _target, false
        end
        
        if not UnitIsFriend(_player, _target) and not UnitIsDeadOrGhost(_target) then
            return _target, false
        end

        return nil, false -- no valid target found
    end
    
    _G.SLASH_PFQUICKCAST_DIRECT_ENEMY1 = "/pfquickcast@directenemy"
    _G.SLASH_PFQUICKCAST_DIRECT_ENEMY2 = "/pfquickcast:directenemy"
    _G.SLASH_PFQUICKCAST_DIRECT_ENEMY3 = "/pfquickcast.directenemy"
    _G.SLASH_PFQUICKCAST_DIRECT_ENEMY4 = "/pfquickcast_directenemy"
    _G.SLASH_PFQUICKCAST_DIRECT_ENEMY5 = "/pfquickcastdirectenemy"
    function SlashCmdList.PFQUICKCAST_DIRECT_ENEMY(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround = deduceIntendedTarget_forDirectEnemy()
        if proper_target == nil then
            return nil
        end

        return setTargetIfNeededAndCast(
                onCast,
                spellsString,
                _target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@directenemy

end)
