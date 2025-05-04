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
    local assert_ = _G.assert
    local unpack_ = _G.unpack
    local strsub_ = _G.string.sub
    local strfind_ = _G.string.find
    local rawequal_ = _G.rawequal
    local strgfind_ = _G.string.gfind
    local tableinsert_ = _G.table.insert
    local tableremove_ = _G.table.remove

    local getCVar_ = _G.GetCVar
    local setCVar_ = _G.SetCVar
    local getSpellCooldown_ = _G.GetSpellCooldown

    local pfGetSpellInfo_ = _G.pfUI.api.libspell.GetSpellInfo

    local _pet = "pet"
    local _player = "player"
    local _target = "target"
    local _toon_mouse_hover = "mouseover"
    local _target_of_target = "targettarget"

    local _pfui_ui_toon_mouse_hover = (pfUI and pfUI.uf and pfUI.uf.mouseover) or {} -- store the original mouseover module if its present or fallback to a placeholder

    local _solo_spell_target_units = (function()
        local standardSpellTargets = { }

        tableinsert_(standardSpellTargets, _target) -- most common target so we check this first
        tableinsert_(standardSpellTargets, _player) -- these are the most rare mouse-hovering scenarios so we check them last
        tableinsert_(standardSpellTargets, _pet)
        
        -- tableinsert_(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local _party_spell_target_units = (function()
        local standardSpellTargets = { }

        for i = 1, MAX_PARTY_MEMBERS do
            tableinsert_(standardSpellTargets, "party" .. i)
        end

        for i = 1, MAX_PARTY_MEMBERS do -- these are the most rare mouse-hovering scenarios so we check them last
            tableinsert_(standardSpellTargets, "partypet" .. i)
        end

        tableinsert_(standardSpellTargets, "player") -- vital to add this one as well because as it turns out party1->4 doesnt match properly with UnitIsUnit()

        -- tableinsert_(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local _raid_spell_target_units = (function()
        -- https://wowpedia.fandom.com/wiki/UnitId   prepare a list of units that can be used via spelltargetunit in vanilla wow 1.12
        -- notice that we intentionally omitted 'mouseover' below as its causing problems without offering any real benefit

        local standardSpellTargets = { }

        for i = 1, MAX_PARTY_MEMBERS do
            tableinsert_(standardSpellTargets, "party" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS do
            tableinsert_(standardSpellTargets, "raid" .. i)
        end

        for i = 1, MAX_PARTY_MEMBERS do -- pets are more rare targets 
            tableinsert_(standardSpellTargets, "partypet" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS do
            tableinsert_(standardSpellTargets, "raidpet" .. i)
        end

        tableinsert_(standardSpellTargets, "player") -- vital to add this as well
        
        -- tableinsert_(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local function _tryGetUnitOfFrameHovering()
        local mouseFrame = GetMouseFocus()
        return mouseFrame and mouseFrame.label and mouseFrame.id
                and (mouseFrame.label .. mouseFrame.id)
                or nil
    end

    local function _tryTranslateUnitToStandardSpellTargetUnit(unit) -- 00
        if rawequal_(unit, _player) or rawequal_(unit, _target) or rawequal_(unit, _pet) then -- trivial cases
            return unit
        end

        -- searching for pets and raid members that are being targeted via _target_of_target or _toon_mouse_hover
        local properSpellTargetUnits = (UnitInRaid(_player) and _raid_spell_target_units)
                or (GetNumPartyMembers() and _party_spell_target_units)
                or _solo_spell_target_units

        for _, spellTargetUnitName in pairs_(properSpellTargetUnits) do
            if rawequal_(unit, spellTargetUnitName) then -- faster   we frequently get unit already formatted as "party1" or "raid1" etc
                return spellTargetUnitName
            end
        end

        for _, spellTargetUnitName in pairs_(properSpellTargetUnits) do
            if UnitIsUnit(unit, spellTargetUnitName) then
                return spellTargetUnitName
            end
        end

        return nil
    end

    local function _onSelfCast(spellName, _, _, _)
        CastSpellByName(spellName, 1)
    end

    local _cvarAutoSelfCastCached -- getCVar_("AutoSelfCast")  dont
    local function _onCast(spellName, spellId, spellBookType, proper_target)
        if rawequal_(proper_target, _player) then
            CastSpellByName(spellName, 1) -- faster
            return
        end

        _cvarAutoSelfCastCached = _cvarAutoSelfCastCached == nil
                and getCVar_("AutoSelfCast")
                or _cvarAutoSelfCastCached

        if rawequal_(_cvarAutoSelfCastCached, "0") then
            CastSpell(spellId, spellBookType) -- faster using spellid
            return
        end
        
        setCVar_("AutoSelfCast", "0") -- cast without selfcast cvar setting to allow spells to use spelltarget
        CastSpell(spellId, spellBookType) -- faster using spellid
        setCVar_("AutoSelfCast", _cvarAutoSelfCastCached)
    end

    local function _strmatch(input, patternString, ...)
        local variadicsArray = arg

        assert_(patternString ~= nil, "patternString must not be nil")

        if patternString == "" then
            return nil
        end

        local results = { strfind_(input, patternString, unpack_(variadicsArray))}

        local startIndex = results[1]
        if startIndex == nil then
            -- no match
            return nil
        end

        local match01 = results[3]
        if match01 == nil then
            local endIndex = results[2]
            return strsub_(input, startIndex, endIndex) -- matched but without using captures   ("Foo 11 bar   ping pong"):match("Foo %d+ bar")
        end

        tableremove_(results, 1) -- pop startIndex
        tableremove_(results, 1) -- pop endIndex

        return unpack_(results) -- matched with captures  ("Foo 11 bar   ping pong"):match("Foo (%d+) bar")
    end

    local function _strtrim(input)
        return _strmatch(input, '^%s*(.*%S)') or ''
    end

    local _lastUsedSpellsString
    local _lastUsedSpellsArrayResult
    local _parsedSpellStringsCache = {}
    local function _parseSpellsString(spellsString)
        if rawequal_(spellsString, _lastUsedSpellsString) then -- very common, extremely fast and it saves us from a hefty table lookup right below
            return _lastUsedSpellsArrayResult
        end

        if spellsString == nil then
            return nil
        end
        
        local spellsArray = _parsedSpellStringsCache[spellsString]
        if spellsArray ~= nil then
            _lastUsedSpellsString = spellsString
            _lastUsedSpellsArrayResult = spellsArray
            return spellsArray
        end

        local spellsStringTrimmed = _strtrim(spellsString)
        
        spellsArray = _parsedSpellStringsCache[spellsStringTrimmed]
        if spellsArray ~= nil then
            _lastUsedSpellsString = spellsString
            _lastUsedSpellsArrayResult = spellsArray
            return spellsArray
        end

        spellsArray = {}
        for spell in strgfind_(spellsString, "%s*([^,]*[^,])%s*") do
            spell = _strtrim(spell)
            if spell and spell ~= "" then -- ignore empty strings
                tableinsert_(spellsArray, spell)
            end
        end

        _lastUsedSpellsString = spellsString
        _lastUsedSpellsArrayResult = spellsArray
        _parsedSpellStringsCache[spellsString] = spellsArray
        _parsedSpellStringsCache[spellsStringTrimmed] = spellsArray
        return spellsArray
    end
    
    local _non_self_castable_spells = { -- some spells report 0 min/max range but are not self-castable
        ["Maul"] = true,
        ["Slam"] = true,
        ["Holy Strike"] = true,
        ["Raptor Strike"] = true,
        ["Heroic Strike"] = true,
    }
    
    local function _isSpellUsable(spell)
        local spellRawName, rank, _, _, minRange, maxRange, spellId, spellBookType = pfGetSpellInfo_(spell) -- cache-aware

        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spell='" .. tostring(spell) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] rank='" .. tostring(rank) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spellRawName='" .. tostring(spellRawName) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] minRange='" .. tostring(minRange) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] maxRange='" .. tostring(maxRange) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spellID='" .. tostring(spellId) .. "'")
        -- print("** [pfUI-quickcast] [isSpellUsable()] [pfGetSpellInfo_()] spellBookType='" .. tostring(spellBookType) .. "'")

        if not rank then
            return false -- check if the player indeed knows this spell   maybe he hasnt specced for it
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
        minRange == 0 and maxRange == 0 and _non_self_castable_spells[spellRawName] == nil,
        spellRawName -- check if the spell is only cast-on-self by sniffing the min/max ranges of it
    end

    local function _setTargetIfNeededAndCast(
            spellCastCallback,
            spellsString,
            proper_target,
            use_target_toggle_workaround,
            intention_is_to_assist_friendly_target
    )
        local spellsArray = _parseSpellsString(spellsString)
        if not spellsArray then
            return nil
        end

        -- it is obvious that there is no need to target toggle over to the desired target if we are already targeting it!
        use_target_toggle_workaround = use_target_toggle_workaround and not UnitIsUnit(proper_target, _target)
        
        local spellId, spellBookType, canBeUsed, isSpellCastOnSelfOnly, eventualTarget, spellRawName
        local targetWasToggled, wasSpellCastSuccessful, spellThatQualified = false, false, nil
        for _, spell in spellsArray do
            spellId, spellBookType, canBeUsed, isSpellCastOnSelfOnly, spellRawName = _isSpellUsable(spell)

            if canBeUsed then
                if not targetWasToggled and not isSpellCastOnSelfOnly then
                    -- unfortunately holy shock is buggy when an enemy is targeted   it will cast on the enemy instead of the friendly target
                    if use_target_toggle_workaround or (
                            intention_is_to_assist_friendly_target and spellRawName == "Holy Shock" and not UnitIsFriend(_player, _target)
                    ) then
                        targetWasToggled = true
                        TargetUnit(proper_target)
                    end
                end

                eventualTarget = isSpellCastOnSelfOnly
                        and _player
                        or proper_target

                _pfui_ui_toon_mouse_hover.unit = eventualTarget

                spellCastCallback(spell, spellId, spellBookType, eventualTarget) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

                if eventualTarget == _player then -- self-casts are 99.9999% successful unless you're low on mana   currently we have problems detecting mana shortages   we live with this for now
                    spellThatQualified = spell
                    wasSpellCastSuccessful = true
                    break
                end

                if SpellIsTargeting() then
                    -- if the spell is awaiting a target to be specified ...
                    SpellTargetUnit(eventualTarget)
                end

                wasSpellCastSuccessful = not SpellIsTargeting()
                if wasSpellCastSuccessful then
                    spellThatQualified = spell
                    break
                end
            end
        end

        if targetWasToggled then
            TargetLastTarget()
        end

        _pfui_ui_toon_mouse_hover.unit = nil -- remove temporary mouseover unit in the mouseover module of pfui

        if not wasSpellCastSuccessful then
            -- at this point if the spell is still awaiting for a target then either there was an error or targeting is impossible   in either case need to clean up spell target
            SpellStopTargeting()
            return nil
        end

        return spellThatQualified
    end

    -- endregion helpers

    -- region   /pfquickcast.any

    local function _deduceIntendedTarget_forGenericSpells()
        -- inspired by /pfcast implementation
        local unit = _toon_mouse_hover
        if not UnitExists(unit) then
            unit = _tryGetUnitOfFrameHovering()
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
                and _tryTranslateUnitToStandardSpellTargetUnit(unit)

        if unitstr or UnitIsUnit(_target, unit) then
            -- no target change required   we can either use spell target or the unit that is already our current target
            _pfui_ui_toon_mouse_hover.unit = (unitstr or _target)
            return _pfui_ui_toon_mouse_hover.unit, false
        end

        _pfui_ui_toon_mouse_hover.unit = unit
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forGenericSpells()
        if proper_target == nil then
            return
        end

        return _setTargetIfNeededAndCast(
                _onCast,
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
        return _onCast(spellName, spellId, spellBookType, proper_target)
    end

    local function _deduceIntendedTarget_forFriendlySpells()
        
        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and UnitCanAssist(_player, unitOfFrameHovering) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(unitOfFrameHovering) -- we need to check
            if unitAsTeamUnit then
                -- we need to use the target-swap hack here if the currently selected target is friendly   otherwise the
                -- heals we cast via CastSpell and CastSpellByName will land on the currently selected friendly target ;(
                return unitAsTeamUnit, UnitCanAssist(_player, _target)
            end

            return unit, true
        end

        -- UnitExists(_toon_mouse_hover) no need to check this here
        if UnitCanAssist(_player, _toon_mouse_hover) and not UnitIsDeadOrGhost(_toon_mouse_hover) then
            --00 mouse hovering directly over friendly player-toons in the game-world?
 
            if not UnitCanAssist(_player, _target) then -- if the current target is not friendly then we dont need to use the target-swap hack and mouseover is faster
                return _toon_mouse_hover, true
            end

            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(_toon_mouse_hover)
            if unitAsTeamUnit then -- _toon_mouse_hover -> "party1" or "raid1" etc   it is much more efficient this way in a team context compared to having to use target-swap hack
                return unitAsTeamUnit, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
        end

        if UnitCanAssist(_player, _target) then -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not            
            return _target, false
        end

        if UnitCanAssist(_player, _target_of_target) then -- at this point the current target is not a friendly unit so we try to heal the target of the target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _toon_mouse_hover) returns false
        --     but it doesnt matter really since noone is using this kind of mousehover to heal himself
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forFriendlySpells()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                pfUIQuickCast.OnHeal, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true -- setting intention_is_to_assist_friendly_target=true is vital to set this for certain corner cases
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

        return _setTargetIfNeededAndCast(
                pfUIQuickCast.OnHeal, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spellsString,
                _player,
                false,
                true -- setting intention_is_to_assist_friendly_target=true is vital to set this for certain corner cases
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

        return _setTargetIfNeededAndCast(
                _onSelfCast,
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forFriendlySpells()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true -- setting intention_is_to_assist_friendly_target=true is vital to set this for certain corner cases
        )
    end

    -- endregion /pfquickcast@friend

    -- region /pfquickcast@friendcorpse

    local function _deduceIntendedTarget_forFriendlyCorpseSpells()

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and UnitIsDeadOrGhost(unitOfFrameHovering) and UnitCanAssist(_player, unitOfFrameHovering) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(unitOfFrameHovering) -- we need to check
            if unitAsTeamUnit then
                -- we need to use the target-swap hack here if the currently selected target is friendly   otherwise the
                -- spells we cast via CastSpell and CastSpellByName will land on the currently selected friendly target ;(
                return unitAsTeamUnit, UnitCanAssist(_player, _target)
            end

            return unit, true
        end

        -- UnitExists(_toon_mouse_hover) no need to check this here
        if UnitIsDeadOrGhost(_toon_mouse_hover) and UnitCanAssist(_player, _toon_mouse_hover) then
            --00 mouse hovering directly over friendly player-toons in the game-world?

            if not UnitCanAssist(_player, _target) then -- if the current target is not friendly then we dont need to use the target-swap hack and mouseover is faster
                return _toon_mouse_hover, true
            end

            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(_toon_mouse_hover)
            if unitAsTeamUnit then -- _toon_mouse_hover -> "party1" or "raid1" etc   it is much more efficient this way in a team context compared to having to use target-swap hack
                return unitAsTeamUnit, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
        end

        if UnitIsDeadOrGhost(_target) and UnitCanAssist(_player, _target) then -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not            
            return _target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _toon_mouse_hover) returns false
        --     but it doesnt matter really since noone is using this kind of mousehover to heal himself
    end
    
    _G.SLASH_PFQUICKCAST_FRIEND_CORPSE1 = "/pfquickcast@friendcorpse"
    _G.SLASH_PFQUICKCAST_FRIEND_CORPSE2 = "/pfquickcast:friendcorpse"
    _G.SLASH_PFQUICKCAST_FRIEND_CORPSE3 = "/pfquickcast.friendcorpse"
    _G.SLASH_PFQUICKCAST_FRIEND_CORPSE4 = "/pfquickcast_friendcorpse"
    _G.SLASH_PFQUICKCAST_FRIEND_CORPSE5 = "/pfquickcastfriendcorpse"
    function SlashCmdList.PFQUICKCAST_FRIEND_CORPSE(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forFriendlyCorpseSpells()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@friendcorpse

    -- region /pfquickcast@enemy

    local function _deduceIntendedTarget_forOffensiveSpells()

        if UnitExists(_toon_mouse_hover) -- for offensive spells it is more common to use world-mouseover rather than unit-frames mouse-hovering
                and not UnitIsFriend(_player, _toon_mouse_hover)
                and not UnitIsUnit(_toon_mouse_hover, _target)
                and not UnitIsDeadOrGhost(_toon_mouse_hover) then
            --00 mouse hovering directly over an enemy toon in the game-world?
            
            if UnitIsFriend(_player, _target) then
                -- if the current target is friendly then we dont need to use the target-swap hack   simply using mouseover is faster
                return _toon_mouse_hover, false
            end

            local mindControlledFriendTurnedHostile = _tryTranslateUnitToStandardSpellTargetUnit(_toon_mouse_hover) -- todo   experiment also with party1target party2target etc and see if its supported indeed
            if mindControlledFriendTurnedHostile then --             this in fact does make sense because a raid member might get mind-controlled
                return mindControlledFriendTurnedHostile, false --   and turn hostile in which case we can and should avoid the target-swap hack
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is hostile   its very resource intensive but if we dont use the hack then the offensive spell will land on the currently selected hostile target
        end

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
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

        -- 00  strangely enough if the mouse hovers over the player toon then UnitCanAssist(_player, _toon_mouse_hover) returns false but it doesnt matter really
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

        local proper_target, use_target_toggle_workaround  = _deduceIntendedTarget_forOffensiveSpells()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@enemy

    -- region /pfquickcast@healtote

    local function _deduceIntendedTarget_forFriendlyTargetOfTheEnemy()

        local gotEnemyCandidateFromMouseFrameHovering = false

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and not UnitIsUnit(unitOfFrameHovering, _target) then
            if not UnitExists(unitOfFrameHovering) --                  unit-frames mouse-hovering   
                    or UnitIsFriend(_player, unitOfFrameHovering) --   we check that the mouse-hover unit-frame is alive and enemy
                    or UnitIsDeadOrGhost(unitOfFrameHovering) then --  if its not then we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseFrameHovering = true
            TargetUnit(unitOfFrameHovering)

        elseif UnitExists(_toon_mouse_hover) and not UnitIsUnit(_toon_mouse_hover, _target) then
            if UnitIsFriend(_player, _toon_mouse_hover) --   is the mouse hovering directly over a enemy toon in the game world?
                    or UnitIsDead(_toon_mouse_hover) then -- we check if its enemy and alive   if its not we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseFrameHovering = true
            TargetUnit(_toon_mouse_hover)
        end

        if (gotEnemyCandidateFromMouseFrameHovering or not UnitIsFriend(_player, _target))
                and UnitCanAssist(_player, _target_of_target)
                and not UnitIsDead(_target_of_target) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- free world pvp situations without raid
        end
        
        if gotEnemyCandidateFromMouseFrameHovering then
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

        local proper_target, use_target_toggle_workaround  = _deduceIntendedTarget_forFriendlyTargetOfTheEnemy()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                pfUIQuickCast.OnHeal, -- this can be hooked upon and intercepted by external addons to autorank healing spells etc
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true -- setting intention_is_to_assist_friendly_target=true is vital to set this for certain corner cases
        )
    end

    -- endregion /pfquickcast@healtote

    -- region /pfquickcast@friendtote
    
    _G.SLASH_PFQUICKCAST_FRIEND_TOTE1 = "/pfquickcast@friendtote"
    _G.SLASH_PFQUICKCAST_FRIEND_TOTE2 = "/pfquickcast:friendtote"
    _G.SLASH_PFQUICKCAST_FRIEND_TOTE3 = "/pfquickcast.friendtote"
    _G.SLASH_PFQUICKCAST_FRIEND_TOTE4 = "/pfquickcast_friendtote"
    _G.SLASH_PFQUICKCAST_FRIEND_TOTE5 = "/pfquickcastfriendtote"
    function SlashCmdList.PFQUICKCAST_FRIEND_TOTE(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround  = _deduceIntendedTarget_forFriendlyTargetOfTheEnemy()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true -- setting intention_is_to_assist_friendly_target=true is vital to set this for certain corner cases
        )
    end
    
    -- endregion /pfquickcast@friendtote

    -- region /pfquickcast@intervene

    local function _deduceIntendedTarget_forIntervene()

        if not UnitIsFriend(_player, _target)
                and UnitCanAssist(_player, _target_of_target)
                and not UnitIsUnit(_player, _target_of_target)
                and not UnitIsDead(_target_of_target) then

            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- free world pvp situations without raid
        end

        return nil, false -- no valid target found
    end

    _G.SLASH_PFQUICKCAST_INTERVENE1 = "/pfquickcast@intervene"
    _G.SLASH_PFQUICKCAST_INTERVENE2 = "/pfquickcast:intervene"
    _G.SLASH_PFQUICKCAST_INTERVENE3 = "/pfquickcast.intervene"
    _G.SLASH_PFQUICKCAST_INTERVENE4 = "/pfquickcast_intervene"
    _G.SLASH_PFQUICKCAST_INTERVENE5 = "/pfquickcastintervene"
    function SlashCmdList.PFQUICKCAST_INTERVENE(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target, use_target_toggle_workaround  = _deduceIntendedTarget_forIntervene()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true -- setting intention_is_to_assist_friendly_target=true is vital to set this for certain corner cases
        )
    end

    -- endregion /pfquickcast@intervene

    -- region /pfquickcast@enemytbf

    local function _deduceIntendedTarget_forEnemyTargetedByFriend()

        local gotFriendCandidateFromMouseHover = false

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
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
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpellTargetUnit(_target_of_target) -- raid context
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

        local proper_target, use_target_toggle_workaround  = _deduceIntendedTarget_forEnemyTargetedByFriend()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@enemytbf

    -- region /pfquickcast@directenemy

    local function _deduceIntendedTarget_forDirectEnemy()
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forDirectEnemy()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                _target,
                use_target_toggle_workaround
        )
    end

    -- endregion /pfquickcast@directenemy

end)
