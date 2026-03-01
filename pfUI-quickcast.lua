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

-- absolutely crucial to snapshot this before SmartHealer or any other auto-ranking addon hooks into it   we definately
-- dont want the heal-autoranking-mechanism to be invoked twice in a row for this addon and once more for SlashCmdList.PFCASTFOCUS()!!
local g_hooklessPfuiCastFocus_ = SlashCmdList.PFCASTFOCUS

pfUI:RegisterModule("QuickCast", "vanilla", function()

    local _G = _G -- snapshot it locally to speed things up a bit
    
    local MAX_RAID_MEMBERS_ = _G.MAX_RAID_MEMBERS or 40 --         this constant does include the player himself in the raid-count
    local MAX_OTHER_PARTY_MEMBERS_ = _G.MAX_PARTY_MEMBERS or 4 --  even though the party contains 5 members the player himself is not counted in the MAX_PARTY_MEMBERS so the game sets it 4

    local hooklessPfuiCastFocus_ = g_hooklessPfuiCastFocus_ or SlashCmdList.PFCASTFOCUS -- just in case
    
    -- region helpers
    local pfui_ = _G.pfUI
    local type_ = _G.type
    local pairs_ = _G.pairs
    local assert_ = _G.assert
    local unpack_ = _G.unpack
    local strsub_ = _G.string.sub
    local strlen_ = _G.string.len
    local strfind_ = _G.string.find
    local rawequal_ = _G.rawequal
    local strgfind_ = _G.string.gfind
    local strlower_ = _G.string.lower
    local tableinsert_ = _G.table.insert
    local tableremove_ = _G.table.remove

    local unitExists_ = _G.UnitExists -- these are just probing functions and are safe to snapshot early
    local unitIsUnit_ = _G.UnitIsUnit -- because 3rd party addons dont care to wire-up interceptors on these
    local unitIsDead_ = _G.UnitIsDead
    local unitIsFriend_ = _G.UnitIsFriend
    local unitCanAssist_ = _G.UnitCanAssist
    local unitIsDeadOrGhost_ = _G.UnitIsDeadOrGhost
    
    local unitInRaid_ = _G.UnitInRaid
    local getNumPartyMembers_ = _G.GetNumPartyMembers

    local getLocale_ = _G.GetLocale
    local getMouseFocus_ = _G.GetMouseFocus

    local getUnitGuid_ = _G.GetUnitGuid or _G.UnitGuid -- nampower v3.x vs nampower v2.x

    local getCVar_ = _G.GetCVar
    local setCVar_ = _G.SetCVar
    local getSpellCooldown_ = _G.GetSpellCooldown

    local pfGetSpellInfo_ = _G.pfUI.api.libspell.GetSpellInfo
    local lazyPfqcOnHealSnapshot_ -- dont set this to pfUIQuickCast.OnHeal right away    we need to allow addons like SmartHealer to install their hooks first before we snapshot it!!!
    
    local _pet = "pet"
    local _player = "player"
    local _target = "target"
    local _toon_mouse_hover = "mouseover"
    local _target_of_target = "targettarget"

    local _isPlayerInDuel = false
    local _gameEventsListenerFrame = CreateFrame("Frame", "pfui.quickcast.events.listener.frame") -- Create a frame to handle events

    _gameEventsListenerFrame:RegisterEvent("DUEL_FINISHED")
    _gameEventsListenerFrame:RegisterEvent("CHAT_MSG_SYSTEM")
    _gameEventsListenerFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- _gameEventsListenerFrame:RegisterEvent("DUEL_COUNTDOWN") -- not supported by 1.12 clients
    -- _gameEventsListenerFrame:RegisterEvent("DUEL_REQUESTED") -- doesnt really offer any help

    local _duelFinalCountDownRegex = {
        ["enUS"] = "^Duel starting: 1$", --      us english
        ["enGB"] = "^Duel starting: 1$", --      british english
        ["deDE"] = "^Duell beginnt: 1$", --      german
        ["frFR"] = "^.*duel.*: 1$", --           french   todo figure out the exact phrasing used in this language
        ["esES"] = "^.*duelo.*: 1$", --          spanish  todo figure out the exact phrasing used in this language
        ["ruRU"] = "^.*Дуэль.*: 1$", --          russian  todo figure out the exact phrasing used in this language
        ["ptBR"] = "^.*Duelo.*: 1$", --          brazilian-portuguese   todo figure out the exact phrasing used in this language
        ["itIT"] = "^.*Duello.*: 1$", --         italian
        ["koKR"] = "^.*결투.*: 1$", --            korean
        ["zhCN"] = "^.*决斗.*: 1$", --            chinese simplified
        ["zhTW"] = "^.*決斗.*: 1$", --            chinese traditional
    }

    _duelFinalCountDownRegex = strlower_(_duelFinalCountDownRegex[getLocale_()] or _duelFinalCountDownRegex["enUS"])

    local PLAYER_OWN_GUID = "0x"
    local IS_GUID_CASTING_SUPPORTED = false
    local TARGET_GUIDS_STANDARD_LENGTH = -1
    _gameEventsListenerFrame:SetScript("OnEvent", function() -- dont specify arguments as it will break the 'event' var   it is meant to be accessed as a global!
        local eventSnapshot = event
        if eventSnapshot == "PLAYER_ENTERING_WORLD" then
            _isPlayerInDuel = false

            PLAYER_OWN_GUID = getUnitGuid_ and getUnitGuid_("player") or nil
            
            IS_GUID_CASTING_SUPPORTED = type_(PLAYER_OWN_GUID) == "string" and strlen_(PLAYER_OWN_GUID) > 0
            
            TARGET_GUIDS_STANDARD_LENGTH = IS_GUID_CASTING_SUPPORTED and strlen_(PLAYER_OWN_GUID) or -1
            return
        end

        if eventSnapshot == "CHAT_MSG_SYSTEM" then
            local arg1Snapshot = arg1 or ""
            if strlen_(arg1Snapshot) < 30 and strfind_(strlower_(arg1Snapshot), _duelFinalCountDownRegex) then
                _isPlayerInDuel = true
            end
            return
        end
        
        if eventSnapshot == "DUEL_FINISHED" then
            _isPlayerInDuel = false
            return
        end
    end)
    
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

        for i = 1, MAX_OTHER_PARTY_MEMBERS_ do
            -- adds party1, party2, party3, party4     but intentionally omits party0 which is the player himself because we add "player" for that down below
            tableinsert_(standardSpellTargets, "party" .. i)
        end

        for i = 1, MAX_OTHER_PARTY_MEMBERS_ do
            -- these are the most rare mouse-hovering scenarios so we check them last
            tableinsert_(standardSpellTargets, "partypet" .. i)
        end

        tableinsert_(standardSpellTargets, "pet") --    vital to add this one for when the player himself has a pet
        tableinsert_(standardSpellTargets, "player") -- vital to add this one as well because as it turns out party1->4 doesnt match properly with unitIsUnit_()
        
        -- tableinsert_(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local _raid_spell_target_units = (function()
        -- https://wowpedia.fandom.com/wiki/UnitId   prepare a list of units that can be used via spelltargetunit in vanilla wow 1.12
        -- notice that we intentionally omitted 'mouseover' below as its causing problems without offering any real benefit

        local standardSpellTargets = { }

        for i = 1, MAX_OTHER_PARTY_MEMBERS_ do
            -- adds party1, party2, party3, party4     but intentionally omits party0 which is the player himself because we add "player" for that down below
            tableinsert_(standardSpellTargets, "party" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS_ do
            -- adds raid1, raid2, ..., raid40    this does include the player himself somewhere in the raid
            tableinsert_(standardSpellTargets, "raid" .. i)
        end

        for i = 1, MAX_OTHER_PARTY_MEMBERS_ do
            -- pets are more rare targets 
            tableinsert_(standardSpellTargets, "partypet" .. i)
        end
        for i = 1, MAX_RAID_MEMBERS_ do
            -- adds raidpet1, raidpet2, ..., raidpet40    this does include the player-pet somewhere in the raid-pets
            tableinsert_(standardSpellTargets, "raidpet" .. i)
        end

        tableinsert_(standardSpellTargets, "pet") --    vital to add this one for when the player himself has a pet
        tableinsert_(standardSpellTargets, "player") -- vital to add this as well

        -- tableinsert_(standardSpellTargets, _target_of_target)  dont  it doesnt work as a spell target unit

        return standardSpellTargets
    end)()

    local function _tryGetUnitOfFrameHovering()
        local mouseFrame = getMouseFocus_()

        return mouseFrame and mouseFrame.label and mouseFrame.id
                and (mouseFrame.label .. mouseFrame.id)
                or nil
    end

    local function _isGuid(input)
        return type_(input) == "string"
                and strlen_(input) == TARGET_GUIDS_STANDARD_LENGTH
                and strsub_(input, 1, 2) == "0x"
    end

    local function _tryTranslateUnitToStandardSpelltargetUnit_(unit)
        if IS_GUID_CASTING_SUPPORTED and _isGuid(input) then
            -- we dont want to loop over all the standard spell target units if we already have a guid as input
            -- we can directly use it as a spell target unit without any translation
            return unit
        end

        if rawequal_(unit, _pet)
                or rawequal_(unit, _player)
                or rawequal_(unit, _target)
        then
            -- trivial cases
            return unit
        end

        -- searching for pets and raid members that are being targeted via _target_of_target or _toon_mouse_hover
        local properSpellTargetUnits = (unitInRaid_(_player) and _raid_spell_target_units)
                or (getNumPartyMembers_() and _party_spell_target_units)
                or _solo_spell_target_units

        for _, spellTargetUnitName in pairs_(properSpellTargetUnits) do
            if rawequal_(unit, spellTargetUnitName) then
                -- faster   we frequently get unit already formatted as "party1" or "raid1" etc
                return spellTargetUnitName
            end
        end

        for _, spellTargetUnitName in pairs_(properSpellTargetUnits) do
            if unitIsUnit_(unit, spellTargetUnitName) then
                return spellTargetUnitName
            end
        end

        return nil
    end
    
    local targetUnit_
    local spellTargetUnit_
    local spellIsTargeting_
    local targetLastTarget_
    local spellStopTargeting_
    
    local castSpell_
    local castSpellByName_
    local castSpellByNameNoQueue_
    local areLazySnapshotSpellCastFuncsInPlace_ = false
    local function _lazySnapshotSpellCastFuncs()
        if areLazySnapshotSpellCastFuncsInPlace_ then
            return
        end

        castSpell_ = _G.CastSpell --                                                 we need to allow addons like SmartHealer to hook up
        castSpellByName_ = _G.CastSpellByName --                                     their interceptors on these global functions first
        castSpellByNameNoQueue_ = _G.CastSpellByNameNoQueue or _G.CastSpellByName -- and then snapshot them hence the lazy binding here

        targetUnit_ = _G.TargetUnit
        spellTargetUnit_ = _G.SpellTargetUnit
        spellIsTargeting_ = _G.SpellIsTargeting
        targetLastTarget_ = _G.TargetLastTarget
        spellStopTargeting_ = _G.SpellStopTargeting
    end

    local function _onSelfCast(spellName, _, _, _)
        if not areLazySnapshotSpellCastFuncsInPlace_ then _lazySnapshotSpellCastFuncs() end -- lazy-setup once
        
        castSpellByName_(spellName, 1)
    end

    local _cvarAutoSelfCastCached -- getCVar_("AutoSelfCast")  dont
    local function _onCast(spellName, spellId, spellBookType, proper_target, intention_is_focus_cast)
        if not areLazySnapshotSpellCastFuncsInPlace_ then _lazySnapshotSpellCastFuncs() end -- lazy-setup once
        
        if intention_is_focus_cast or (pfui_.uf and pfui_.uf.focus and pfui_.uf.focus.label) == proper_target then -- special case
            hooklessPfuiCastFocus_(spellName) -- SlashCmdList.PFCASTFOCUS() essentially   this tends to use CastSpellByNameNoQueue in some pfui-forks which is more optimal for emergency casting like insta-heals and interrupts!
            return
        end
        
        if rawequal_(proper_target, _player) or (IS_GUID_CASTING_SUPPORTED and proper_target == PLAYER_OWN_GUID) then
            castSpellByName_(spellName, 1) -- faster
            return
        end

        if IS_GUID_CASTING_SUPPORTED and strlen_(proper_target) == TARGET_GUIDS_STANDARD_LENGTH and strsub_(proper_target, 1, 2) == "0x" then
            castSpellByName_(spellName, proper_target) -- nampower and super_wow guid-based casts
            return
        end

        _cvarAutoSelfCastCached = _cvarAutoSelfCastCached == nil
                and getCVar_("AutoSelfCast")
                or _cvarAutoSelfCastCached

        if rawequal_(_cvarAutoSelfCastCached, "0") then
            castSpell_(spellId, spellBookType) -- faster using spellid
            return
        end

        setCVar_("AutoSelfCast", "0") -- cast without selfcast cvar setting to allow spells to use spelltarget
        castSpell_(spellId, spellBookType) -- faster using spellid
        setCVar_("AutoSelfCast", _cvarAutoSelfCastCached)
    end

    local function _strmatch(input, patternString, ...)
        local variadicsArray = arg

        assert_(patternString ~= nil, "patternString must not be nil")

        if patternString == "" then
            return nil
        end

        local results = { strfind_(input, patternString, unpack_(variadicsArray)) }

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
        if rawequal_(spellsString, _lastUsedSpellsString) then
            -- very common, extremely fast and it saves us from a hefty table lookup right below
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
            if spell and spell ~= "" then
                -- ignore empty strings
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
        ["Maul"] = true, -- todo   get these names localized!
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
            intention_is_to_assist_only_friendly_targets,
            intention_is_focus_cast
    )
        if not areLazySnapshotSpellCastFuncsInPlace_ then _lazySnapshotSpellCastFuncs() end -- lazy-setup once
        
        local spellsArray = _parseSpellsString(spellsString)
        if not spellsArray then
            return nil
        end

        -- it is obvious that there is no need to target toggle over to the desired target if we are already targeting it!
        -- likewise if the target is a guid we dont need the target-toggle either
        -- we also dont need the target toggling hack if the target is the player himself
        use_target_toggle_workaround = use_target_toggle_workaround
                and not rawequal_(proper_target, _target)
                and not rawequal_(proper_target, _player)
                and (not IS_GUID_CASTING_SUPPORTED or not _isGuid(proper_target))
                and not unitIsUnit_(proper_target, _target)

        local spellId, spellBookType, canBeUsed, isSpellCastOnSelfOnly, eventualTarget, spellRawName
        local targetWasToggled, wasSpellCastSuccessful, spellThatQualified = false, false, nil
        for _, spell in spellsArray do
            spellId, spellBookType, canBeUsed, isSpellCastOnSelfOnly, spellRawName = _isSpellUsable(spell)

            if canBeUsed then
                if not targetWasToggled and not isSpellCastOnSelfOnly then
                    -- unfortunately holy shock is buggy when an enemy is targeted   it will cast on the enemy instead of the friendly target being hovered by the mouse
                    if use_target_toggle_workaround or (
                            intention_is_to_assist_only_friendly_targets
                                    and (spellRawName == "Holy Shock" or spellRawName == "Chastise")
                                    and not unitIsFriend_(_player, _target)
                    ) then
                        targetWasToggled = true
                        targetUnit_(proper_target)
                    end
                end

                eventualTarget = isSpellCastOnSelfOnly
                        and _player
                        or proper_target

                _pfui_ui_toon_mouse_hover.unit = eventualTarget

                spellCastCallback(spell, spellId, spellBookType, eventualTarget, intention_is_focus_cast) -- this is the actual cast call which can be intercepted by third party addons to autorank the healing spells etc

                if eventualTarget == _player then
                    -- self-casts are 99.9999% successful unless you're low on mana   currently we have problems detecting mana shortages   we live with this for now
                    spellThatQualified = spell
                    wasSpellCastSuccessful = true
                    break
                end

                if spellIsTargeting_() then
                    -- if the spell is awaiting a target to be specified ...
                    spellTargetUnit_(eventualTarget)
                end

                wasSpellCastSuccessful = not spellIsTargeting_()
                if wasSpellCastSuccessful then
                    spellThatQualified = spell
                    break
                end
            end
        end

        if targetWasToggled then
            targetLastTarget_()
        end

        _pfui_ui_toon_mouse_hover.unit = nil -- remove temporary mouseover unit in the mouseover module of pfui

        if not wasSpellCastSuccessful then
            -- at this point if the spell is still awaiting for a target then either there was an error or targeting is impossible   in either case need to clean up spell target
            spellStopTargeting_()
            return nil
        end

        return spellThatQualified
    end

    -- endregion helpers

    -- region   /pfquickcast.any

    local function _deduceIntendedTarget_forGenericSpells()
        -- inspired by /pfcast implementation
        local unit = _toon_mouse_hover
        if not unitExists_(unit) then
            unit = _tryGetUnitOfFrameHovering()
            if unit then
                -- nothing more to do
            elseif unitExists_(_target) then
                unit = _target
            elseif getCVar_("AutoSelfCast") == "1" then
                unit = _player
            else
                return nil
            end
        end

        local unitstr = not unitCanAssist_(_player, _target) -- 00
                and unitCanAssist_(_player, unit)
                and _tryTranslateUnitToStandardSpelltargetUnit_(unit)

        if unitstr or unitIsUnit_(_target, unit) then
            -- no target change required   we can either use spell target or the unit that is already our current target
            _pfui_ui_toon_mouse_hover.unit = (unitstr or _target)
            return _pfui_ui_toon_mouse_hover.unit, false
        end

        _pfui_ui_toon_mouse_hover.unit = unit
        return unit, true -- target change required

        -- 00  if target and mouseover are friendly units we cant use spell target as it would cast on the target instead of the mouseover
        --     however if the mouseover is friendly and the target is not we can try to obtain the best unitstring for the later SpelltargetUnit_() call
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
                use_target_toggle_workaround,
                false --  intention_is_focus_cast
        )
    end

    -- endregion    /pfquickcast.any

    -- region   /pfquickcast:heal  and  :healself

    function pfUIQuickCast.OnHeal(spellName, spellId, spellBookType, proper_target, intention_is_focus_cast)
        -- keep the proper_target parameter even if its not needed per se this method   we want
        -- calls to this method to be hooked-upon/intercepted by third party heal-autoranking addons
        return _onCast(spellName, spellId, spellBookType, proper_target, intention_is_focus_cast)
    end

    local function _deduceIntendedTarget_forFriendlySpells()

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()

        if unitOfFrameHovering and unitCanAssist_(_player, unitOfFrameHovering) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(unitOfFrameHovering) -- we need to check
            if unitAsTeamUnit then
                -- we need to use the target-swap hack here if the currently selected target is friendly   otherwise the
                -- heals we cast via CastSpell and CastSpellByName will land on the currently selected friendly target ;(
                return unitAsTeamUnit, unitCanAssist_(_player, _target)
            end

            return unitOfFrameHovering, true -- unit is friendly but it is not in the player's team    we must use target swapping 
        end

        -- unitExists_(_toon_mouse_hover) no need to check this here
        if unitCanAssist_(_player, _toon_mouse_hover) and not unitIsDeadOrGhost_(_toon_mouse_hover) then
            --00 mouse hovering directly over friendly player-toons in the game-world?

            if not unitCanAssist_(_player, _target) then
                -- if the current target is not friendly then we dont need to use the target-swap hack and mouseover is faster
                return _toon_mouse_hover, true
            end

            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(_toon_mouse_hover)
            if unitAsTeamUnit then
                -- _toon_mouse_hover -> "party1" or "raid1" etc   it is much more efficient this way in a team context compared to having to use target-swap hack
                return unitAsTeamUnit, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
        end

        if unitCanAssist_(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not            
            return _target, false
        end

        if unitCanAssist_(_player, _target_of_target) then
            -- at this point the current target is not a friendly unit so we try to heal the target of the target   useful fallback behaviour both when soloing and when raid healing
            return _target_of_target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then unitCanAssist_(_player, _toon_mouse_hover) returns false
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

        if not lazyPfqcOnHealSnapshot_ then lazyPfqcOnHealSnapshot_ = pfUIQuickCast.OnHeal end -- crucial to be snapshotted lazily!  its typically hooked upon and intercepted by external addons to autorank healing spells etc

        return _setTargetIfNeededAndCast(
                lazyPfqcOnHealSnapshot_,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true, --  setting intention_is_to_assist_only_friendly_targets=true is vital to set this for certain corner cases
                false --  intention_is_focus_cast
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

        if not lazyPfqcOnHealSnapshot_ then lazyPfqcOnHealSnapshot_ = pfUIQuickCast.OnHeal end -- crucial to be snapshotted lazily!  its typically hooked upon and intercepted by external addons to autorank healing spells etc

        return _setTargetIfNeededAndCast(
                lazyPfqcOnHealSnapshot_,
                spellsString,
                _player,
                false,
                true, --  setting intention_is_to_assist_only_friendly_targets=true is vital to set this for certain corner cases
                false --  intention_is_focus_cast
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
                true, --  intention_is_to_assist_only_friendly_targets
                false --  intention_is_focus_cast
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
                true, --  setting intention_is_to_assist_only_friendly_targets=true is vital to set this for certain corner cases
                false --  intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@friend

    -- region /pfquickcast@friendcorpse

    local function _deduceIntendedTarget_forFriendlyCorpseSpells()

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and unitIsDeadOrGhost_(unitOfFrameHovering) and unitCanAssist_(_player, unitOfFrameHovering) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(unitOfFrameHovering) -- we need to check this
            if unitAsTeamUnit then
                -- we need to use the target-swap hack here if the currently selected target is friendly   otherwise the
                -- spells we cast via CastSpell and CastSpellByName will land on the currently selected friendly target ;(
                return unitAsTeamUnit, unitCanAssist_(_player, _target)
            end

            return unit, true
        end

        -- unitExists_(_toon_mouse_hover) no need to check this here
        if unitIsDeadOrGhost_(_toon_mouse_hover) and unitCanAssist_(_player, _toon_mouse_hover) then
            --00 mouse hovering directly over friendly player-toons in the game-world?

            if not unitCanAssist_(_player, _target) then
                -- if the current target is not friendly then we dont need to use the target-swap hack and mouseover is faster
                return _toon_mouse_hover, true
            end

            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(_toon_mouse_hover)
            if unitAsTeamUnit then
                -- _toon_mouse_hover -> "party1" or "raid1" etc   it is much more efficient this way in a team context compared to having to use target-swap hack
                return unitAsTeamUnit, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is friendly   if we dont use the hack then the heal will land on the currently selected friendly target
        end

        if unitIsDeadOrGhost_(_target) and unitCanAssist_(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not            
            return _target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then unitCanAssist_(_player, _toon_mouse_hover) returns false
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
                use_target_toggle_workaround,
                false -- intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@friendcorpse

    -- region /pfquickcast@enemy

    local function _deduceIntendedTarget_forOffensiveSpells()

        if unitExists_(_toon_mouse_hover) -- for offensive spells it is more common to use world-mouseover rather than unit-frames mouse-hovering
                and not unitIsFriend_(_player, _toon_mouse_hover)
                and not unitIsUnit_(_toon_mouse_hover, _target)
                and not unitIsDeadOrGhost_(_toon_mouse_hover) then
            --00 mouse hovering directly over an enemy toon in the game-world?

            if unitIsFriend_(_player, _target) then
                -- if the current target is friendly then we dont need to use the target-swap hack   simply using mouseover is faster
                return _toon_mouse_hover, false
            end

            local mindControlledFriendTurnedHostile = _tryTranslateUnitToStandardSpelltargetUnit_(_toon_mouse_hover) -- todo   experiment also with party1target party2target etc and see if its supported indeed
            if mindControlledFriendTurnedHostile then
                --             this in fact does make sense because a raid member might get mind-controlled
                return mindControlledFriendTurnedHostile, false --   and turn hostile in which case we can and should avoid the target-swap hack
            end

            return _toon_mouse_hover, true -- we need to use the target-swap hack here because the currently selected target is hostile   its very resource intensive but if we dont use the hack then the offensive spell will land on the currently selected hostile target
        end

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering
                and unitExists_(unitOfFrameHovering)
                and not unitIsFriend_(_player, unitOfFrameHovering)
                and not unitIsUnit_(_target, unitOfFrameHovering)
                and not unitIsDeadOrGhost_(unitOfFrameHovering) then
            -- local unitAsTeamUnit = tryTranslateUnitToStandardSpelltargetUnit_(unitOfFrameHovering) -- no point to do that here    it only makes sense for friendly units not enemy ones

            return unitOfFrameHovering, false
        end

        if unitExists_(_target) and not unitIsDeadOrGhost_(_target) and not unitIsFriend_(_player, _target) then
            -- if we get here we have no mouse-over or mouse-focus so we simply examine if the current target is friendly or not

            return _target, false
        end

        return nil, false -- no valid target found

        -- 00  strangely enough if the mouse hovers over the player toon then unitCanAssist_(_player, _toon_mouse_hover) returns false but it doesnt matter really
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forOffensiveSpells()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                false -- intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@enemy

    -- region /pfquickcast@healtote

    local function _deduceIntendedTarget_forFriendlyTargetOfTheEnemy()
        if not areLazySnapshotSpellCastFuncsInPlace_ then _lazySnapshotSpellCastFuncs() end -- lazy-setup once

        local gotEnemyCandidateFromMouseFrameHovering = false

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and not unitIsUnit_(unitOfFrameHovering, _target) then
            if not unitExists_(unitOfFrameHovering) --                  unit-frames mouse-hovering   
                    or unitIsFriend_(_player, unitOfFrameHovering) --   we check that the mouse-hover unit-frame is alive and enemy
                    or unitIsDeadOrGhost_(unitOfFrameHovering) then
                --  if its not then we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseFrameHovering = true
            targetUnit_(unitOfFrameHovering)

        elseif unitExists_(_toon_mouse_hover) and not unitIsUnit_(_toon_mouse_hover, _target) then
            if unitIsFriend_(_player, _toon_mouse_hover) --   is the mouse hovering directly over a enemy toon in the game world?
                    or unitIsDead_(_toon_mouse_hover) then
                -- we check if its enemy and alive   if its not we guard close
                return nil, false
            end

            gotEnemyCandidateFromMouseFrameHovering = true
            targetUnit_(_toon_mouse_hover)
        end

        if (gotEnemyCandidateFromMouseFrameHovering or not unitIsFriend_(_player, _target))
                and unitCanAssist_(_player, _target_of_target)
                and not unitIsDead_(_target_of_target) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- free world pvp situations without raid
        end

        if gotEnemyCandidateFromMouseFrameHovering then
            targetLastTarget_()
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forFriendlyTargetOfTheEnemy()
        if proper_target == nil then
            return nil
        end

        if not lazyPfqcOnHealSnapshot_ then lazyPfqcOnHealSnapshot_ = pfUIQuickCast.OnHeal end -- crucial to be snapshotted lazily!  its typically hooked upon and intercepted by external addons to autorank healing spells etc

        return _setTargetIfNeededAndCast(
                lazyPfqcOnHealSnapshot_,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true, --  setting intention_is_to_assist_only_friendly_targets=true is vital to set this for certain corner cases
                false --  intention_is_focus_cast
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forFriendlyTargetOfTheEnemy()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true, --  setting intention_is_to_assist_only_friendly_targets=true is vital to set this for certain corner cases
                false --  intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@friendtote

    -- region /pfquickcast@intervene

    local function _deduceIntendedTarget_forIntervene()

        if not unitIsFriend_(_player, _target)
                and unitCanAssist_(_player, _target_of_target)
                and not unitIsUnit_(_player, _target_of_target)
                and not unitIsDead_(_target_of_target) then

            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(_target_of_target) -- raid context
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forIntervene()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                true, --  setting intention_is_to_assist_only_friendly_targets=true is vital to set this for certain corner cases
                false --  intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@intervene

    -- region /pfquickcast@enemytbf

    local function _deduceIntendedTarget_forEnemyTargetedByFriend()

        local gotFriendCandidateFromMouseHover = false

        local unitOfFrameHovering = _tryGetUnitOfFrameHovering()
        if unitOfFrameHovering and not unitIsUnit_(unitOfFrameHovering, _target) then

            if not unitIsFriend_(_player, unitOfFrameHovering) or unitIsDeadOrGhost_(unitOfFrameHovering) then
                return nil, false
            end

            gotFriendCandidateFromMouseHover = true
            targetUnit_(unitOfFrameHovering)

        elseif unitExists_(_toon_mouse_hover) and not unitIsUnit_(_toon_mouse_hover, _target) then

            if not unitIsFriend_(_player, _toon_mouse_hover) or unitIsDeadOrGhost_(_toon_mouse_hover) then
                return nil, false
            end

            gotFriendCandidateFromMouseHover = true
            targetUnit_(_toon_mouse_hover)
        end

        if (gotFriendCandidateFromMouseHover or unitIsFriend_(_player, _target))
                and not unitIsFriend_(_player, _target_of_target)
                and not unitIsDeadOrGhost_(_target_of_target) then
            local unitAsTeamUnit = _tryTranslateUnitToStandardSpelltargetUnit_(_target_of_target) -- raid context
            if unitAsTeamUnit then
                return unitAsTeamUnit, false
            end

            return _target_of_target, true -- its vital to use the target-toggle-hack otherwise the offensive spell wont be cast at all
        end

        if gotFriendCandidateFromMouseHover then
            targetLastTarget_()
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

        local proper_target, use_target_toggle_workaround = _deduceIntendedTarget_forEnemyTargetedByFriend()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                use_target_toggle_workaround,
                false -- intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@enemytbf

    -- region /pfquickcast@directenemy
 
    local function _deduceIntendedTarget_forDirectEnemy()
        if not unitExists_(_target)
                and unitExists_(_toon_mouse_hover)
                and not unitIsFriend_(_player, _toon_mouse_hover)
                and not unitIsDeadOrGhost_(_toon_mouse_hover) then
            targetUnit_(_toon_mouse_hover)
            return _target, false
        end
        
        if (_isPlayerInDuel or not unitIsFriend_(_player, _target)) and not unitIsDeadOrGhost_(_target) then --00
            return _target, false
        end

        return nil, false -- no valid target found

        --00  there is a known limitation when someone is dueling a person in the same party/raid
        --    which causes the unitIsFriend_(_player) to return true for the duel opponent :(
        --
        --    this is why we take into account the _isPlayerInDuel flag here
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
                proper_target, -- essentially always _target
                use_target_toggle_workaround,
                false -- intention_is_focus_cast
        )
    end

    -- endregion /pfquickcast@directenemy


    -- region /pfquickcast@focus

    local function _deduceIntendedTarget_forFocus()
        local pfFocus = pfui_.uf and pfui_.uf.focus
        if not pfFocus or not pfFocus:IsShown() or pfFocus.label == nil or pfFocus.label == "" then
            return nil -- no focus set
        end

        return pfFocus.label
    end

    _G.SLASH_PFQUICKCAST_FOCUS1 = "/pfquickcast@focus"
    _G.SLASH_PFQUICKCAST_FOCUS2 = "/pfquickcast:focus"
    _G.SLASH_PFQUICKCAST_FOCUS3 = "/pfquickcast.focus"
    _G.SLASH_PFQUICKCAST_FOCUS4 = "/pfquickcast_focus"
    _G.SLASH_PFQUICKCAST_FOCUS5 = "/pfquickcastfocus"
    function SlashCmdList.PFQUICKCAST_FOCUS(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target = _deduceIntendedTarget_forFocus()
        if proper_target == nil then
            return nil
        end

        return _setTargetIfNeededAndCast(
                _onCast,
                spellsString,
                proper_target,
                true, -- use_target_toggle_workaround   needed for legacy contexts where guid-casting is not supported!
                true, -- intention_is_to_assist_only_friendly_targets
                true --  intention_is_focus_cast   speeds things up inside _onCast()
        )
    end

    -- endregion /pfquickcast@focus


    -- region /pfquickcast@healfocus

    _G.SLASH_PFQUICKCAST_HEAL_FOCUS1 = "/pfquickcast@healfocus"
    _G.SLASH_PFQUICKCAST_HEAL_FOCUS2 = "/pfquickcast:healfocus"
    _G.SLASH_PFQUICKCAST_HEAL_FOCUS3 = "/pfquickcast.healfocus"
    _G.SLASH_PFQUICKCAST_HEAL_FOCUS4 = "/pfquickcast_healfocus"
    _G.SLASH_PFQUICKCAST_HEAL_FOCUS5 = "/pfquickcasthealfocus"
    function SlashCmdList.PFQUICKCAST_HEAL_FOCUS(spellsString)
        -- local func = loadstring(spell or "")   intentionally disabled to avoid overhead

        if not spellsString then
            return nil
        end

        local proper_target = _deduceIntendedTarget_forFocus()
        if proper_target == nil then
            return nil
        end

        if not lazyPfqcOnHealSnapshot_ then lazyPfqcOnHealSnapshot_ = pfUIQuickCast.OnHeal end -- crucial to be snapshotted lazily!  its typically hooked upon and intercepted by external addons to autorank healing spells etc

        return _setTargetIfNeededAndCast(
                lazyPfqcOnHealSnapshot_,
                spellsString,
                proper_target,
                true, -- use_target_toggle_workaround   needed for legacy contexts where guid-casting is not supported!
                true, -- intention_is_to_assist_only_friendly_targets
                true --  intention_is_focus_cast   speeds things up inside _onCast()
        )
    end

    -- endregion /pfquickcast@healfocus

end)
