local HB_GENERIC_FEATS, HB_GENERIC_OPTION_IDS -- cached source contract for historical selectors
local PR = {}
local BuildFiles=Ext.Require('Shared/PresetFiles.lua')
local BuildData=Ext.Require('Shared/BuildPresetData.lua')
local BuildImporter=Ext.Require('Shared/BuildPresetImporter.lua')
local BUILD_DIR='HomeBrew/BuildPresets'
local BUILD_ROW_TYPE='PR_BuildPresetRow_v1'


local POPUP_VM_TYPE = "PR_RespecChoiceVM"
local TOAST_VM_TYPE = "PR_NotificationToastVM"
local CHOICE_WIDGET_NAMES = { "PR_RespecChoice", "PR_RespecChoice_c" }
local TOAST_WIDGET_NAME = "PR_NotificationToast"

local VANILLA_RESPEC_WIDGET_NAMES = { "CharacterRespec", "CharacterRespec_c" }
local IMPROVED_UI_UUID = "26922ba9-6018-5252-075d-7ff2ba6ed879"
local MAX_TOAST_BIND_ATTEMPTS = 20
local POPUP_BIND_RETRY_TICKS = 20
local MAX_POPUP_BIND_RETRIES = 90 -- 90 polls at 20 ticks; never retry indefinitely when BG3 has no native screen
local MAX_AUTO_CONFIRM_ATTEMPTS = 180
local TOAST_BASE_DURATION_MS = 6000
local TOAST_EXTRA_LEVEL_DURATION_MS = 500
local MAX_PASSIVE_SLOTS = 12

-- Temporary navigation diagnostics for the redesigned Partial Respec popup.
-- Does not inspect or modify game progression.
local navEvents = {}

local HB_PASSIVE_PAIR_ALLOWED = {
    ["d215b9ad-9753-4d74-8ff9-24bf1dce53d6"]={["ASI_Strength"]=true,["ASI_Dexterity"]=true,["ASI_Constitution"]=true,["ASI_Intelligence"]=true,["ASI_Wisdom"]=true,["ASI_Charisma"]=true},
    ["56c3c247-35cf-4ffd-86dd-7d249cc1808f"]={["BarbarousAssault"]=true,["BrutalCritical"]=true,["DangerSense"]=true,["DeathGlare"]=true,["Faceoff"]=true,["FuriousCriticals"]=true,["LandsStride"]=true,["OverwhelmingPower"]=true,["PeakPhysicality"]=true,["RageoftheMountain"]=true,["RageoftheUndefeated"]=true,["RagingVitality"]=true,["RelentlessRage"]=true,["RipandTear"]=true,["RootedinAnger"]=true,["TemperedRetaliation"]=true,["TerrifyingBellow"]=true,["UnrelentingRampage"]=true,["UnarmouredBeast"]=true,["UnstoppableForce"]=true},
    ["cec2d95b-451c-40f8-8e17-9e547d363e8e"]={["Aggressive_Rhythm"]=true,["Discerning_Insult"]=true,["Distracting_Dissonance"]=true,["Dueling_Ditties"]=true,["Echoes_of_Fortitude"]=true,["Encouraging_Momentum"]=true,["Engaging_Composition"]=true,["Guiding_Performance"]=true,["Harmonious_Aura"]=true,["Infuriating_Amplification"]=true,["Inspirational_Resonance"]=true,["Inspiring_Crescendo"]=true,["Insufferable_Discord"]=true,["Melodic_Precision"]=true,["Mobile_Maestro"]=true,["Mocksmith"]=true,["Silver_Tongued_Savant"]=true,["Soothing_Words"]=true,["Unprecedented_Encore"]=true,["Vigorously_Tuned"]=true},
    ["c09815f7-282b-4ccf-bd89-a51caa1b550f"]={["Aegis"]=true,["Blessed_Resolve"]=true,["BloodforBlood"]=true,["Consecrative_Sacrifice"]=true,["Divine_Resiliance"]=true,["Divine_Restoration"]=true,["Ethereal_Intuition"]=true,["Flames_of_Repentance"]=true,["Holy_Fortitude"]=true,["Guided_Strikes"]=true,["Holy_Retribution"]=true,["Immaculate_Ward"]=true,["Martyrdom"]=true,["Paradisiacal_Gift"]=true,["Sacral_Bulwark"]=true,["Sanctified_Presence"]=true,["Sanctifying_Aura"]=true,["Stalwart"]=true,["Stout_Believer"]=true,["Venerational_Strikes"]=true},
    ["7bc235ac-7eeb-49d3-8249-c3313d87af75"]={["Armour_of_Thorns"]=true,["Combats_Harvest"]=true,["Earthern_Sentinel"]=true,["Feral_Precision"]=true,["Feral_Resiliance"]=true,["Ferocious_Stand"]=true,["Instinctive_Transformation"]=true,["Kindred_Instinct"]=true,["WildShape_Combat"]=true,["Natural_Bounty"]=true,["Natural_Resurgence"]=true,["Natures_Mercy"]=true,["Natures_Wrath"]=true,["Pack_Leader"]=true,["Primal_Bloodletter"]=true,["Primal_Surge"]=true,["Primal_Takedown"]=true,["Shapechangers_Versatility"]=true,["Territorial_Dominance"]=true,["Wild_Stride"]=true},
    ["0de08fff-ab18-442f-a0b1-f53e7be04c03"]={["Aspect_of_Defiance"]=true,["Challengers_Call"]=true,["Charge_of_the_Collective"]=true,["Duellist"]=true,["Full_Arsenal"]=true,["Heavy_Assault"]=true,["Intuitive_Warning"]=true,["Ironclad"]=true,["Iron_Will"]=true,["Leaders_Momentum"]=true,["Martial_Fortress"]=true,["Martial_Reclaim"]=true,["Merciless"]=true,["Natural_Born_Leader"]=true,["Opportunist"]=true,["Proper_Form"]=true,["Reckless_Abandon"]=true,["Sentinels_Protection"]=true,["Tactical_Retreat"]=true,["Tunnel_Fighter"]=true},
    ["b441c722-e4d4-4702-861a-039bfd77c124"]={["Counterflow"]=true,["Critical_Flow"]=true,["Dance_of_Flowing_Water"]=true,["Deflective_Reflex"]=true,["Dexterous_Ward"]=true,["Fist_of_Crushing_Rock"]=true,["Focused_Stream"]=true,["Fortified_Psyche"]=true,["Harmonious_Barrage"]=true,["Harmonious_Defense"]=true,["Martial_Empowerment"]=true,["Mystic_Strikes"]=true,["Opportune_Reversal"]=true,["Resonance_of_Body"]=true,["Sagacious_Resilience"]=true,["Soused_Rampart"]=true,["Tempestuous_Reprise"]=true,["Tranquil_Fortitude"]=true,["Windwaker"]=true,["Zen_Accuracy"]=true},
    ["d84c7f36-8c5b-4b17-b95a-e1da725f9004"]={["Attonement"]=true,["Critical_Oath"]=true,["Death_Sentence"]=true,["Divine_Health"]=true,["Divine_Resurgence"]=true,["Divine_Sense"]=true,["Divine_Shielding"]=true,["Holy_Bulwark"]=true,["Holy_Wrath"]=true,["Infallible_Beacon"]=true,["Lay_On_Hands"]=true,["Oathbound_Renewal"]=true,["Oath_Channeling"]=true,["Principle_of_Belief"]=true,["Repel_the_Damned"]=true,["Resplendent_Reverb"]=true,["Smite_Makes_Right"]=true,["Stalwart_Eruption"]=true,["Stalwart_Resolve"]=true,["Visage_of_Sanctity"]=true},
    ["a533fde7-ee0a-46ce-92e2-9763201a54d2"]={["Ambush_Breaker"]=true,["Ballistic_Infusion"]=true,["Beastbonds_Precision"]=true,["Beastial_Recovery"]=true,["Blood_Bond"]=true,["Bounty_Hunter"]=true,["Close_Quarters_Shooter"]=true,["Escapist"]=true,["Explosive_Arrowheads"]=true,["Hidden_Inventory"]=true,["Marksmans_Edge"]=true,["Multiattack_Defense"]=true,["Natural_Huntsman"]=true,["Natural_Opportunity"]=true,["Protective_Bond"]=true,["Sniper"]=true,["Superior_Technique"]=true,["Sure_Shot"]=true,["Two_Weapon_Fighting"]=true,["Wanton_Synergy"]=true},
    ["4f744a6e-8589-4a46-89ab-a95415a73245"]={["Cunning_Strikes"]=true,["Cutthroat"]=true,["Elusive_Retreat"]=true,["Elusive_Shadow"]=true,["Fast_Hands"]=true,["Fatal_Manoeuvre"]=true,["Grievous_Wounds"]=true,["Illusory_Advantage"]=true,["Light_Footwork"]=true,["Low_Visibility"]=true,["Manipulator"]=true,["Now_You_See_Me"]=true,["Quick_Reflexes"]=true,["Reactive_Movement"]=true,["Sharp_Eyes"]=true,["CSpectre"]=true,["Spectral_Hunter"]=true,["Umbral_Sight"]=true,["Vanishing_Act"]=true,["Venomous"]=true},
    ["28e5fed3-bd41-4b74-ab48-b8e824ad3443"]={["ArcaneOverflow"]=true,["ArcaneOppression"]=true,["ArcaneReservoir"]=true,["CharismaticInfusion"]=true,["CharismaticShield"]=true,["DormantCharge"]=true,["ElementalAfterglow"]=true,["EnchantingInfluence"]=true,["EphemeralBarrier"]=true,["EssentialEpiphany"]=true,["EvasiveWarp"]=true,["LatentAcuity"]=true,["MistyEscape"]=true,["MysticEmpowerment"]=true,["NaturalVortex"]=true,["ReactiveReprise"]=true,["SharedCreation"]=true,["SorcerousAcumen"]=true,["SorcerousFocus"]=true,["VeiledSynergy"]=true},
    ["1e1a9a4d-38f4-4a05-b080-d32c2b872250"]={["BaneofthePact"]=true,["BindingTransposition"]=true,["BoundElements"]=true,["BoundCompulsion"]=true,["CurseofHellfire"]=true,["DarkRetaliation"]=true,["CDevilsSight"]=true,["EldritchEnervation"]=true,["EldritchLethargy"]=true,["EldritchPull"]=true,["HellishRebuttal"]=true,["HellboundVision"]=true,["LuckoftheDevil"]=true,["MasterofChaos"]=true,["OneWithShadows"]=true,["PactProtection"]=true,["PactStricken"]=true,["RepellingBlast"]=true,["ResiliantServitude"]=true,["ShadeWalker"]=true},
    ["93d41226-d7af-495c-b023-08a6af077962"]={["Arcane_Interruption"]=true,["Arcane_Reverb"]=true,["Arcane_Shield"]=true,["Boon_of_Plumes"]=true,["Edict_of_Divinity"]=true,["Elemental_Countercharge"]=true,["Enchanted_Safeguard"]=true,["Flames_Riposte"]=true,["Illusory_Phantasm"]=true,["Magical_Insight"]=true,["Mystic_Override"]=true,["Potent_Cantrips"]=true,["Potent_Spells"]=true,["Spellblade"]=true,["Spellbound_Rebirth"]=true,["Spell_Surge"]=true,["Telekinetic_Command"]=true,["CWarMagic"]=true,["Wizards_Clarity"]=true,["Woven_Precision"]=true},
    ["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]={["AdaptivePlating"]=true,["ArcaneCalibrationMatrix"]=true,["AutomatedArcaneSuppression"]=true,["CastleDefense"]=true,["DeadZoneCalibration"]=true,["ElementalPayload"]=true,["EmergencyPowerCell"]=true,["FailsafeInjection"]=true,["IncendiaryRounds"]=true,["KineticFeedbackLoop"]=true,["LikeClockwork"]=true,["ModularAugmentation"]=true,["NaniteDispersionField"]=true,["Overclocked"]=true,["PrecisionRifling"]=true,["RecoilCompensation"]=true,["Safeguard"]=true,["SpeedLoader"]=true,["SyntheticActionEconomy"]=true,["VitalAim"]=true},
}

local function NavigationLog(message)
    navEvents[#navEvents + 1] = tostring(message)
    if #navEvents > 100 then table.remove(navEvents, 1) end
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile, "HomeBrew/Diagnostics/HB_RespecNavigation_Diagnostics.txt",
            table.concat(navEvents, "\n") .. "\n")
    end
end

local registered = false
local toastGeneration = 0
local toastTimerId = nil
local autoConfirmInProgress = false
local autoConfirmMode = nil
local autoConfirmCharacter = nil
local popupShowGeneration = 0
local popupRetryEventId = nil
-- Partial-confirm handshakes must never leave an uncloseable popup or accept a
-- delayed server ACK after the user has cancelled/restarted the request.
local partialConfirmSequence = 0
local partialPendingRequestId = nil
local partialPendingCharacter = nil
local partialAckWaitTicks = 0
local PARTIAL_ACK_TIMEOUT_TICKS = 600
local function ClearPartialPending()
    partialPendingRequestId = nil
    partialPendingCharacter = nil
    partialAckWaitTicks = 0
end

-- Last-resort request if the native respec screen mounts without the HB
-- choice event (observed for some caster-respec sequences). Never send a
-- character UUID from the client; the server verifies the active definition
-- and the owning peer before beginning/resending a dialog.
local respecRecoveryTicks = 0
local respecRecoveryRequested = false
local respecPopupReceivedThisScreen = false
local RESPEC_RECOVERY_DELAY_TICKS = 360
local loadOrderWarned = false

local LOCA_HANDLES = {
    ClassLevel = "hf39c9f10gb179g4084g8ff6gc74285976171",
    SummaryHeader = "h2559478fg7db0g4c65gb791gbb5b2f8cce16",
    Classes = "h5e37a2dfg4880g424bga1e6ge5cb67ad838b",
    NoClasses = "h4c0fbf6egc03cg4114g9db7g5a83d073ccf7",
    Subclasses = "h294a397ag4d41g4d36g903eg6902f6f3441c",
    Feats = "h5f0a79b9g4348g4049g9b77g0ff34a14484a",
    ClassPassives = "h6f3bc421g66a2g43a8gb450g95cd5c862ffb",
    ListSeparator = "h9e2ea072gc77dg475dgb36eg2d90b35ef740",
    ToastLevels = "h424602aag4ac8g437bgba0bg09b557a3a31e",
    ToastClasses = "ha2a60b34gfd95g4cd6gafa6g934565f64fa5",
    ToastReady = "hd2c871c3g413fg44b9gb1b1g17f37946342a",
    UnknownClass = "hca715032g6928g42e4g91ebg062f59702816",
    UnknownSubclass = "h5ea6b060g79d4g4542ga9beg674b004d3428",
    UnknownFeat = "h1fa2342eg6b09g4874gbd98g2d575b62a78a",
    UnknownPassive = "h17481e45gd9d8g48e7ga58ag752a8cf65a78",
}

local function InterpolateFallback(template, ...)
    local result = template
    for index, value in ipairs({ ... }) do
        result = result:gsub("%[" .. index .. "%]", function()
            return tostring(value or "")
        end)
    end
    return result
end

--- Localizes the handle and substitutes [n] placeholders, falling back to the template on failure.
local function Interpolate(handle, fallback, ...)
    local args = { ... }
    local message = Ext.Loca.GetTranslatedString(handle)
    if message and message ~= "" and message ~= handle then
        for index, value in ipairs(args) do
            message = message:gsub("%[" .. index .. "%]", function()
                return tostring(value or "")
            end)
        end
        local text = message:gsub("<br>", "\n")
        return text
    end
    return InterpolateFallback(fallback, table.unpack(args))
end

--- Resolves an entry to display text: localized handle first, fallback name, then "?".
---@param entry table|string|nil
---@param kind "Class"|"Subclass"|"Feat"|"Passive"
---@return string
local function DisplayName(entry, kind)
    if type(entry) == "string" then return entry end

    local genericFallback = "Unknown " .. kind:lower()
    local fallback = entry and entry.DisplayNameFallback
    if not fallback or fallback == "" or fallback == genericFallback then
        fallback = "?"
    end
    local handle = entry and entry.DisplayNameHandle
    if handle then
        local translated = Ext.Loca.GetTranslatedString(handle)
        if translated then return translated end
    end

    local unknownHandle = LOCA_HANDLES["Unknown" .. kind]
    return Interpolate(unknownHandle, fallback, fallback)
end

local function Join(values)
    return table.concat(values, Ext.Loca.GetTranslatedString(LOCA_HANDLES.ListSeparator, ", "))
end

---@param classes table|nil
---@return string
local function BuildClassText(classes)
    local values = {}
    for _, entry in ipairs(classes or {}) do
        local name = DisplayName(entry.Name, "Class")
        values[#values + 1] = Interpolate(
            LOCA_HANDLES.ClassLevel,
            "[1] [2]",
            name,
            entry.Level or 0
        )
    end
    return #values > 0 and Join(values) or Ext.Loca.GetTranslatedString(LOCA_HANDLES.NoClasses, "None")
end

---@param entries table|nil
---@param kind "Subclass"|"Feat"|"Passive"
---@return string
local function BuildNameText(entries, kind)
    local values = {}
    for _, entry in ipairs(entries or {}) do
        values[#values + 1] = DisplayName(entry, kind)
    end
    return Join(values)
end

--- Display names for choices from HB's ExtraActions selector.
--- The level-up record, not the current passive status, determines the value.
local EXTRA_RESOURCE_NAMES = {
    ExtraActions_Action = "Action",
    ExtraActions_BonusAction = "Bonus Action",
    ExtraActions_Reaction = "Reaction",
}

local function ExtraResourceName(passiveId)
    local id = tostring(passiveId or "")
    if EXTRA_RESOURCE_NAMES[id] then return EXTRA_RESOURCE_NAMES[id] end
    local fallback = id:gsub("^ExtraActions_", "")
    fallback = fallback:gsub("([a-z])([A-Z])", "%1 %2"):gsub("_", " ")
    return fallback
end

--- Renders the popup summary text (kept levels, classes, subclasses, feats).
---@param summary table|nil
---@return string
local function BuildSummary(summary)
    summary = summary or {}
    local level = tonumber(summary.Level) or 1
    local lines = {
        Interpolate(
            LOCA_HANDLES.SummaryHeader,
            "<i>Kept through level [1]</i>:",
            level
        ),
        Interpolate(
            LOCA_HANDLES.Classes,
            "Classes: [1]",
            BuildClassText(summary.Classes)
        ),
    }

    if #(summary.Subclasses or {}) > 0 then
        lines[#lines + 1] = Interpolate(
            LOCA_HANDLES.Subclasses,
            "Subclasses: [1]",
            BuildNameText(summary.Subclasses, "Subclass")
        )
    end

    if #(summary.Feats or {}) > 0 then
        local heading = Interpolate(LOCA_HANDLES.Feats, "Feats: [1]", ""):gsub("[:%s]+$", "")
        lines[#lines + 1] = heading .. "\n" .. BuildNameText(summary.Feats, "Feat")
    end

    -- Cumulative preserved choices, marked with character levels so multiclass
    -- class-level 5 picks aren't mistaken for character level 5 picks.
    local resources = {}
    for _, entry in ipairs(summary.ExtraResources or {}) do
        resources[#resources + 1] = ("%s (level %d)"):format(
            ExtraResourceName(entry.PassiveId), tonumber(entry.Level) or 1)
    end
    if #resources > 0 then
        lines[#lines + 1] = "Extra Resources: " .. table.concat(resources, ", ")
    end

    return table.concat(lines, "\n")
end

--- A deliberately read-only display of choices recorded at the selected level.
--- This does not attempt to infer spell/skill choices from raw component data.
local function BuildLevelChoiceText(summary)
    local choice = summary and summary.LevelChoices or {}
    local level = tonumber(choice.Level) or tonumber(summary and summary.Level) or 1
    local lines = { ("Level %d - recorded choices (preview)"):format(level) }

    if choice.HistoryAvailable == false then
        lines[#lines + 1] = "Level-up history unavailable for this level"
    end

    if choice.Class then
        lines[#lines + 1] = "Class: " .. DisplayName(choice.Class, "Class")
    else
        lines[#lines + 1] = "Class: not recorded"
    end
    if choice.SubClass then
        lines[#lines + 1] = "Subclass: " .. DisplayName(choice.SubClass, "Subclass")
    end
    if choice.Feat then
        lines[#lines + 1] = "Feat: " .. DisplayName(choice.Feat, "Feat")
    end

    local passives = {}
    for _, entry in ipairs(choice.ClassPassives or {}) do
        passives[#passives + 1] = DisplayName(entry, "Passive")
    end
    if #passives > 0 then
        lines[#lines + 1] = "HB passive choices: " .. table.concat(passives, ", ")
    end
    local resources = {}
    for _, passiveId in ipairs(choice.ExtraResources or {}) do
        resources[#resources + 1] = ExtraResourceName(passiveId)
    end
    if #resources > 0 then
        lines[#lines + 1] = "Extra Resource: " .. table.concat(resources, ", ")
    end
    if #(choice.Spells or {}) > 0 then
        lines[#lines + 1] = "Recorded spell choices: " .. table.concat(choice.Spells, ", ")
    end
    if #lines <= 2 and choice.HistoryAvailable ~= false then
        lines[#lines + 1] = "No other tracked choices at this level"
    end
    return table.concat(lines, "\n")
end

---@param vm ViewModel
---@param passives table|nil
local function SetPassiveSlots(vm, passives)
    passives = passives or {}
    vm.PR_HasClassPassives = #passives > 0

    for index = 1, MAX_PASSIVE_SLOTS do
        local entry = passives[index]
        vm["PR_Passive" .. index .. "Visible"] = entry ~= nil
        local name = entry and DisplayName(entry, "Passive") or ""
        vm["PR_Passive" .. index .. "Name"] = entry and (name .. (index < math.min(#passives, MAX_PASSIVE_SLOTS) and "," or "")) or ""
    end
end

--- Renders the completion toast text (restored levels + classes kept).
---@param classes table|nil
---@param levelCount integer|nil
---@return string
local function BuildToastMarkup(classes, levelCount)
    local level = math.max(1, tonumber(levelCount) or 1)
    return table.concat({
        Interpolate(
            LOCA_HANDLES.ToastLevels,
            "<i>Levels 1-[1] restored</i>",
            level
        ),
        Interpolate(
            LOCA_HANDLES.ToastClasses,
            "Classes kept: [1]",
            BuildClassText(classes)
        ),
        Interpolate(
            LOCA_HANDLES.ToastReady,
            "Ready to rebuild from level [1]",
            level + 1
        ),
    }, "\n")
end

local function RegisterVM()
    if registered then return end

    local popupProperties = {
        PR_PopupVisible = { Type = "Bool", Notify = true },
        PR_ModeTitle = { Type = "String", Notify = true },
        PR_ModeHelp = { Type = "String", Notify = true },
        PR_ModeSelectVisible = { Type = "Bool", Notify = true },
        PR_PartialViewVisible = { Type = "Bool", Notify = true },
        PR_EditorViewVisible = { Type = "Bool", Notify = true },
        PR_HasLevelSlider = { Type = "Bool", Notify = true },
        PR_CanHistoricalRespec = { Type = "Bool", Notify = true },
        PR_OpenPartialRespec = { Type = "Command" },
        PR_OpenBuildEditor = { Type = "Command" },
        PR_OpenNativePreview = { Type = "Command" },
        PR_BuildButtonsVisible={Type='Bool',Notify=true},
        PR_BuildOpen={Type='Bool',Notify=true},
        PR_BuildSaveMode={Type='Bool',Notify=true},
        PR_BuildLoadMode={Type='Bool',Notify=true},
        PR_BuildTitle={Type='String',Notify=true},
        PR_BuildStatus={Type='String',Notify=true},
        PR_BuildName={Type='String',Notify=true},
        PR_BuildSelectedIndex={Type='Int32',Notify=true},
        PR_BuildSelectionChanged={Type='Command'},
        PR_BuildRows={Type='Collection'},
        PR_BuildCanSave={Type='Bool',Notify=true},
        PR_BuildCanLoad={Type='Bool',Notify=true},
        PR_BuildCanDelete={Type='Bool',Notify=true},
        PR_BuildSaveLabel={Type='String',Notify=true},
        PR_BuildBusy={Type='Bool',Notify=true},
        PR_BuildOpenSave={Type='Command'},
        PR_BuildOpenLoad={Type='Command'},
        PR_BuildSave={Type='Command'},
        PR_BuildLoad={Type='Command'},
        PR_BuildBack={Type='Command'},
        PR_BuildDelete={Type='Command'},
        PR_BackToModes = { Type = "Command" },
        PR_EditorApplyCommand = { Type = "Command" },
        PR_EditorHasEdits = { Type = "Bool", Notify = true },
        PR_EditorStagedText = { Type = "String", Notify = true },
        PR_EditorStatus = { Type = "String", Notify = true },
        PR_EditorBusy = { Type = "Bool", Notify = true },
        PR_SelectedLevel = { Type = "Double", Notify = true },
        PR_MaxLevel = { Type = "Double" },
        PR_Summary = { Type = "String", Notify = true },
        PR_LevelChoices = { Type = "String", Notify = true },
        PR_ExtraEditVisible = { Type = "Bool", Notify = true },
        PR_ExtraEditSelected = { Type = "String", Notify = true },
        PR_ExtraEditSummary = { Type = "String", Notify = true },
        PR_ConfirmLabel = { Type = "String", Notify = true },
        PR_EditAction = { Type = "Command" },
        PR_EditBonusAction = { Type = "Command" },
        PR_EditReaction = { Type = "Command" },
        PR_OtherEditVisible = { Type = "Bool", Notify = true },
        PR_OtherCanStage = { Type = "Bool", Notify = true },
        PR_OtherTarget = { Type = "String", Notify = true },
        PR_OtherOption = { Type = "String", Notify = true },
        PR_OtherFeedback = { Type = "String", Notify = true },
        PR_OtherTargetPrevious = { Type = "Command" },
        PR_OtherTargetNext = { Type = "Command" },
        PR_OtherOptionPrevious = { Type = "Command" },
        PR_OtherOptionNext = { Type = "Command" },
        PR_OtherStage = { Type = "Command" },
        PR_OtherClear = { Type = "Command" },
        PR_PassiveEditVisible = { Type = "Bool", Notify = true },
        PR_PassiveEditTarget = { Type = "String", Notify = true },
        PR_PassiveEditProposed = { Type = "String", Notify = true },
        PR_PassiveEditFeedback = { Type = "String", Notify = true },
        PR_PassiveTargetPrevious = { Type = "Command" },
        PR_PassiveTargetNext = { Type = "Command" },
        PR_PassiveOptionPrevious = { Type = "Command" },
        PR_PassiveOptionNext = { Type = "Command" },
        PR_PassiveStage = { Type = "Command" },
        PR_PassiveReset = { Type = "Command" },
        PR_HasClassPassives = { Type = "Bool", Notify = true },
        PR_CurrentPlayer = { Type = "Object" },
        PR_ConfirmCommand = { Type = "Command" },
        PR_FullRespecCommand = { Type = "Command" },
        PR_CancelRespecCommand = { Type = "Command" },
        PR_LevelChangedCommand = { Type = "Command" },
    }
    for index = 1, MAX_PASSIVE_SLOTS do
        popupProperties["PR_Passive" .. index .. "Visible"] = { Type = "Bool", Notify = true }
        popupProperties["PR_Passive" .. index .. "Name"] = { Type = "String", Notify = true }
    end

    -- The popup (single-slider level picker: value N keeps levels 1-N)
    Ext.UI.RegisterType(BUILD_ROW_TYPE,{Name={Type='String'},Detail={Type='String'}})
    Ext.UI.RegisterType(POPUP_VM_TYPE, popupProperties)

    -- The toast
    Ext.UI.RegisterType(TOAST_VM_TYPE, {
        PR_ToastMarkup = { Type = "String", Notify = true },
        PR_ToastTitle = { Type = "String", Notify = true },
        PR_ToastVisible = { Type = "Bool", Notify = true },
    })

    registered = true
    PRPrint(1, "Partial respec ViewModel types registered")
end

local function CancelToastTimer()
    toastGeneration = toastGeneration + 1
    if toastTimerId then
        Ext.Timer.Cancel(toastTimerId)
        toastTimerId = nil
    end
end

local function CancelPopupRetry()
    if popupRetryEventId then
        Ext.Events.Tick:Unsubscribe(popupRetryEventId)
        popupRetryEventId = nil
    end
end

--- Recursive search for a named Noesis visual child, used by FindWidget.
---@param widget NoesisObject
---@param name string
---@param depth integer
---@return NoesisObject|nil
local function FindVisualChild(widget, name, depth)
    if not widget or depth > 12 then return nil end

    local childCount = widget.VisualChildrenCount
    if type(childCount) ~= "number" then return nil end

    for index = childCount, 1, -1 do
        local child = widget:VisualChild(index)
        if child then
            local childName = child.Name
            if childName == name then return child end

            local nested = FindVisualChild(child, name, depth + 1)
            if nested then return nested end
        end
    end

    return nil
end

---@param name string
---@return NoesisObject|nil
local function FindWidget(name)
    local root = Ext.UI.GetRoot()
    if not root then return nil end
    local contentRoot = root:Find("ContentRoot")
    if not contentRoot then return nil end
    return FindVisualChild(contentRoot, name, 0)
end

---@return ViewModel|nil
local function CurrentVM()
    for _, name in ipairs(CHOICE_WIDGET_NAMES) do
        local widget = FindWidget(name)
        if widget then return widget.DataContext end
    end
    return nil
end

--- Returns the toast widget's ViewModel, creating and binding it if the widget has none.
---@return ViewModel|nil
local function CurrentToastVM()
    RegisterVM()
    local widget = FindWidget(TOAST_WIDGET_NAME)
    if not widget then return nil end

    local vm = widget.DataContext
    local ok, visible = pcall(function()
        return vm and vm.PR_ToastVisible
    end)
    if ok and visible ~= nil then return vm end

    local newVM = Ext.UI.Instantiate("se::" .. TOAST_VM_TYPE)
    newVM.PR_ToastMarkup = ""
    newVM.PR_ToastTitle = "Partial Respec Complete"
    newVM.PR_ToastVisible = false
    widget.DataContext = newVM
    return newVM
end

local function HideToast()
    CancelToastTimer()
    local vm = CurrentToastVM()
    if vm then
        vm.PR_ToastVisible = false
    end
end

---@param vm ViewModel|nil
---@param maxLevel integer
---@return integer
local function SelectedLevel(vm, maxLevel)
    local value = tonumber(vm and vm.PR_SelectedLevel) or maxLevel
    local level = math.floor(value + 0.5)
    if level < 1 then level = 1 end
    if level > maxLevel then level = maxLevel end
    return level
end

---@param vm ViewModel
---@param levelSummaries table<integer, table>
---@param level integer
local RESOURCE_CHOICES = {
    "ExtraActions_Action", "ExtraActions_BonusAction", "ExtraActions_Reaction"
}

-- Flatten all editable passive groups at the chosen character level. The
-- existing target left/right arrows browse passives across group boundaries,
-- so the UI works for Fighter's maneuvers AND HonedTechniques on one level.
local function GroupsAtLevel(summaries, level)
    local choice = summaries[level] and summaries[level].LevelChoices
    return choice and choice.EditablePassiveGroups or {}
end
local function TargetsAtLevel(summaries, level)
    local targets = {}
    for _, group in ipairs(GroupsAtLevel(summaries, level)) do
        for _, id in ipairs(group.Picked or {}) do
            targets[#targets+1] = { Group=group, From=tostring(id) }
        end
    end
    return targets
end
local function PassiveEditKey(group, from)
    return tostring(group.SelectorId) .. "|" .. tostring(group.PassiveList) .. "|" .. tostring(from)
end
local function PassiveLabel(group, id)
    for _, option in ipairs(group and group.Options or {}) do
        if tostring(option.PassiveId) == tostring(id) then
            return DisplayName(option, "Passive")
        end
    end
    return tostring(id or "Unknown")
end
local function SelectedPassiveTarget(summaries, level, cursors)
    local targets = TargetsAtLevel(summaries, level)
    local cursor = cursors[level] or { Target=1, Option=1, ListKey="" }
    cursors[level] = cursor
    if #targets == 0 then return nil, cursor, targets end
    cursor.Target = math.max(1, math.min(cursor.Target, #targets))
    local target = targets[cursor.Target]
    local key = tostring(target.Group.PassiveList) .. "|" .. tostring(target.Group.SelectorId)
    if cursor.ListKey ~= key then
        cursor.Option = 1
        cursor.ListKey = key
    end
    local options = target.Group.Options or {}
    cursor.Option = math.max(1, math.min(cursor.Option, #options))
    return target, cursor, targets
end
local function StagedPassiveRows(stagedPassives)
    local rows = {}
    for level, perLevel in pairs(stagedPassives) do
        for _, edit in pairs(perLevel) do rows[#rows+1] = edit end
    end
    table.sort(rows, function(a,b)
        if a.Level ~= b.Level then return a.Level < b.Level end
        return PassiveEditKey(a, a.From) < PassiveEditKey(b, b.From)
    end)
    return rows
end
-- Feats, abilities, spell/cantrip selections, proficiencies and expertise all
-- use the same historical-choice navigator.  Provenance is supplied by the
-- server from the recorded level-up history, never invented by the client.
local function OtherAtLevel(summaries, level)
    local row=summaries[level] and summaries[level].LevelChoices
    return row and row.OtherChoices or {}
end
local function OtherKey(item)
    return table.concat({item.Kind,item.Source,item.EntryIndex,item.SlotIndex},"|")
end
local function SelectedOther(summaries,level,cursors)
    local list=OtherAtLevel(summaries,level)
    local cursor=cursors[level] or {Target=1,Option=1,Key=""}
    cursors[level]=cursor
    if #list==0 then return nil,cursor,list end
    cursor.Target=math.max(1,math.min(#list,cursor.Target))
    local row=list[cursor.Target]
    local key=OtherKey(row)
    if cursor.Key~=key then cursor.Option=1;cursor.Key=key end
    cursor.Option=math.max(1,math.min(#row.Options,cursor.Option))
    return row,cursor,list
end
local function OtherDisplay(item,value)
    for _,option in ipairs(item and item.Options or {}) do
        if option.Id==value then return option.Name end
    end
    return tostring(value or "Unknown")
end
local function StagedOtherRows(staged)
    local result={}
    for _,byLevel in pairs(staged) do
        for _,edit in pairs(byLevel) do result[#result+1]=edit end
    end
    table.sort(result,function(a,b)
        if a.Level~=b.Level then return a.Level<b.Level end
        return OtherKey(a)<OtherKey(b)
    end)
    return result
end
local function RefreshOtherEditor(vm,summaries,level,staged,cursors)
    local row,cursor,all=SelectedOther(summaries,level,cursors)
    vm.PR_OtherEditVisible=row~=nil
    if not row then
        vm.PR_OtherTarget="No feat, ability, spell or skill selections recorded at this level"
        vm.PR_OtherOption=""; vm.PR_OtherFeedback=""
        return
    end
    local option=row.Options[cursor.Option]
    local stagedRow=staged[level] and staged[level][OtherKey(row)]
    vm.PR_OtherTarget=("%s: %s  (%d/%d)"):format(row.Kind,
        OtherDisplay(row,row.From),cursor.Target,#all)
    vm.PR_OtherOption=option and ("Replace with: %s  (%d/%d)"):format(
        OtherDisplay(row,option.Id),cursor.Option,#row.Options) or "No available candidates"
    vm.PR_OtherCanStage=(level>1 or row.LevelOneVerified==true)
        and row.Editable and option~=nil
    vm.PR_OtherFeedback=not row.Editable and "Choice recorded, but no verified replacement list is available."
        or stagedRow and ("Staged: "..OtherDisplay(row,stagedRow.To))
        or "Select a replacement, then Stage Swap. Experimental: use a disposable save."
end

local function RefreshLevelText(vm, levelSummaries, level, stagedResources, stagedPassives, cursors, feedback,
    stagedOther, otherCursors)
    local summary = levelSummaries[level] or { Level = level }
    vm.PR_Summary = level>1 and BuildSummary(levelSummaries[level-1])
        or "Native first-level respec. Choose class and subclass in BG3; HomeBrew restores saved levels 2+ only when both match the original build."
    vm.PR_LevelChoices = BuildLevelChoiceText(summary)
    SetPassiveSlots(vm, summary.ClassPassives)

    local historical = summary.LevelChoices and summary.LevelChoices.ExtraResources or {}
    local original = #historical == 1 and tostring(historical[1]) or nil
    local canEdit = original ~= nil and EXTRA_RESOURCE_NAMES[original] ~= nil and level > 1
    vm.PR_ExtraEditVisible = canEdit
    local chosen = (stagedResources[level] and stagedResources[level].To) or original
    vm.PR_ExtraEditSelected = canEdit and ("Level " .. level .. "  |  Selected: " .. ExtraResourceName(chosen))
        or "No editable Extra Resource selection at this level"

    local target, cursor, targets = SelectedPassiveTarget(levelSummaries, level, cursors)
    local group, targetId = target and target.Group, target and target.From
    local option = group and group.Options[cursor.Option]
    local candidate = option and tostring(option.PassiveId)
    local canEditPassive = level >= 1 and targetId ~= nil and candidate ~= nil
        and (level>1 or (summary.LevelChoices and summary.LevelChoices.HistoryAvailable==true
            and group and group.Editable~=false and not group.FeatOwnerVerified))
    vm.PR_PassiveEditVisible = canEditPassive
    vm.PR_PassiveEditTarget = canEditPassive
        and ("[" .. tostring(group.SelectorId) .. "] Replace: " .. PassiveLabel(group, targetId)
             .. "  (" .. cursor.Target .. "/" .. #targets .. ")")
        or "No verifiable editable passive choices at this level"
    vm.PR_PassiveEditProposed = canEditPassive
        and ("With: " .. PassiveLabel(group, candidate) .. "  (" .. cursor.Option .. "/" .. #group.Options .. ")")
        or ""
    vm.PR_PassiveEditFeedback = feedback[level] or "Select a passive and replacement; other levels remain unchanged."
    RefreshOtherEditor(vm,levelSummaries,level,stagedOther,otherCursors)

    local count, lines = 0, {}
    for i = 1, #levelSummaries do
        local edit = stagedResources[i]
        if edit then
            count = count + 1
            lines[#lines + 1] = ("Lv %d resource: %s -> %s"):format(i,
                ExtraResourceName(edit.From), ExtraResourceName(edit.To))
        end
    end
    for _, passive in ipairs(StagedPassiveRows(stagedPassives)) do
        count = count + 1
        local displayGroup
        for _, g in ipairs(GroupsAtLevel(levelSummaries, passive.Level)) do
            if g.SelectorId == passive.SelectorId and g.PassiveList == passive.PassiveList then
                displayGroup = g; break
            end
        end
        lines[#lines + 1] = ("Lv %d [%s]: %s -> %s"):format(passive.Level,
            tostring(passive.SelectorId), PassiveLabel(displayGroup, passive.From),
            PassiveLabel(displayGroup, passive.To))
    end
    for _, e in ipairs(StagedOtherRows(stagedOther)) do
        count=count+1
        lines[#lines+1] = ("Lv %d %s: %s -> %s"):format(e.Level,e.Kind,e.From,e.To)
    end
    -- Partial Respec and historical editing now have separate confirmation
    -- controls, so selecting a level can never accidentally apply an edit.
    vm.PR_ConfirmLabel = level==1 and "Restore Higher Levels" or "Confirm Partial Respec"
    vm.PR_EditorHasEdits = count > 0 and not vm.PR_EditorBusy
    vm.PR_EditorStagedText = count > 0
        and table.concat(lines, "\n")
        or "No changes staged yet."
    vm.PR_ExtraEditSummary = vm.PR_EditorStagedText
    if not vm.PR_EditorBusy then
        vm.PR_EditorStatus = feedback[level]
            or "Historical edits are experimental. Test on a disposable save."
    end
end

-- The server response handler is outside BuildVM; keep request identity here.
local nativeSliderPrepareSeq=0
local nativeSliderPendingId=nil
local function BuildVM(character, maxLevel, levelSummaries)
    RegisterVM()
    HideToast()
    maxLevel = math.max(1, maxLevel)
    local stagedResources, stagedPassives, cursors, feedback = {}, {}, {}, {}
    local stagedOther, otherCursors = {}, {}
    local vm = Ext.UI.Instantiate("se::" .. POPUP_VM_TYPE)
    vm.PR_PopupVisible = true
    vm.PR_MaxLevel = maxLevel
    vm.PR_CanHistoricalRespec = (maxLevel>1)
    vm.PR_SelectedLevel = maxLevel
    vm.PR_EditorBusy = false
    vm.PR_EditorStatus = "Selective Respec edits are validated before your build is restored."
    local mode = "choose"
    vm.PR_BuildOpen=false
    vm.PR_BuildButtonsVisible=true
    vm.PR_BuildSaveMode=false;vm.PR_BuildLoadMode=false
    vm.PR_BuildName='';vm.PR_BuildSelectedIndex=-1
    vm.PR_BuildTitle='Build Presets';vm.PR_BuildStatus=''
    vm.PR_BuildSaveLabel='Save';vm.PR_BuildCanSave=true
    vm.PR_BuildCanLoad=false;vm.PR_BuildCanDelete=false;vm.PR_BuildBusy=false
    local OpenNativeLevelEditor, CommitNativeLevelRespec
    local StagePassiveAt, StageResourceAt, StageOtherAt
    local buildPendingPreset=nil
    local buildImportFile=nil
    local buildEntries={}
    local buildReplacePending=false
    local buildDeletePending=false
    -- The Noesis Collection has no reliable atomic Reset. Append newly
    -- discovered entries in the same order as buildEntries, so the ListBox
    -- SelectedIndex and the backing filename always refer to the same row.
    -- Called at menu creation and again on Load, including after a Save.
    -- Resolve the installed localization of saved class/subclass UUIDs.
    -- These names are display-only: compatibility and replay use the GUIDs.
    local presetClassNameCache={}
    local function PresetClassDisplayName(uuid,kind)
        uuid=tostring(uuid or '')
        if uuid=='' or uuid=='00000000-0000-0000-0000-000000000000' then
            return kind=='subclass' and 'No Subclass' or 'Unknown Class'
        end
        if presetClassNameCache[uuid] then return presetClassNameCache[uuid] end
        local name=nil
        if Ext.StaticData and Ext.StaticData.Get then
            local ok,data=pcall(Ext.StaticData.Get,uuid,'ClassDescription')
            if ok and data then
                local handle=nil
                pcall(function()
                    local label=data.DisplayName
                    local raw=label and label.Handle
                    handle=raw and tostring(raw.Handle or raw) or nil
                end)
                if handle and handle~='' and not handle:find('^ResStr_')
                    and Ext.Loca and Ext.Loca.GetTranslatedString then
                    local good,localized=pcall(Ext.Loca.GetTranslatedString,handle)
                    if good and type(localized)=='string' and localized~=''
                        and localized~=handle then name=localized end
                end
                if not name then
                    local okName,raw=pcall(function() return data.Name end)
                    if okName and raw then
                        local text=tostring(raw)
                        if not text:match('^%x%x%x%x%x%x%x%x%-') then
                            text=text:gsub('^ProgressionSubClass_','')
                                :gsub('^ProgressionClass_','')
                                :gsub('^SubClass_',''):gsub('^Class_','')
                                :gsub('([a-z])([A-Z])','%1 %2'):gsub('_',' ')
                            if text~='' then name=text end
                        end
                    end
                end
            end
        end
        name=name or (kind=='subclass' and 'Unknown Subclass' or 'Unknown Class')
        presetClassNameCache[uuid]=name
        return name
    end
    local function PresetBuildDetail(entry)
        -- Display ONLY the original level-one class/subclass: this is the
        -- prerequisite for loading even when the build multiclasses later.
        -- The character level remains the total level of the saved build.
        local starting=entry and entry.StartingClass
        if type(starting)~='table' then return 'Unknown Class / No Subclass / Level '..tostring(entry and entry.Level or '?') end
        local cls=PresetClassDisplayName(starting.Class,'class')
        local sub=PresetClassDisplayName(starting.SubClass,'subclass')
        return cls..' / '..sub..' / Level '..tostring(entry.Level)
    end
    -- Use the SAME starting-class/subclass and level-cap predicate as the
    -- authoritative server. The popup already receives the original recorded
    -- CCLevelUp provenance for every level, so there is no need to guess from
    -- current native-screen class labels or client-side class names.
    local function BuildReceiverHistory()
        local rows={}
        for level=1,maxLevel do
            local choice=levelSummaries[level] and levelSummaries[level].LevelChoices
            local source=choice and choice.Source
            if not choice or choice.HistoryAvailable~=true
                or type(source)~='table' or type(source.ClassId)~='string'
                or source.ClassId=='' then
                return nil,'Original class history is unavailable at level '..level..'.'
            end
            rows[level]={Class=source.ClassId,
                SubClass=tostring(source.SubClassId or '00000000-0000-0000-0000-000000000000')}
        end
        return {components={ccLevelUp={LevelUps=rows}}}
    end
    local function CanLoadBuildEntry(entry)
        if not entry then return false,'Select a saved build.' end
        local receiver,reason=BuildReceiverHistory()
        if not receiver then return false,reason end
        -- Re-read the current JSON rather than trusting a cached label if the
        -- user has replaced the saved file while this panel is open.
        local preset,why=BuildFiles.Read(BUILD_DIR,entry.File)
        if not preset then return false,tostring(why) end
        return BuildData.Compatible(preset,receiver)
    end
    local buildRowsByFile={}
    local function RefreshBuildEntries(ownerVM)
        local files,why=BuildFiles.Discover(BUILD_DIR)
        if not files then
            NavigationLog('BUILD_PRESET_DISCOVERY_FAILED '..tostring(why)..' '..tostring(BuildFiles.LastDiscoveryReport()))
            return false,why
        end
        local additions={}
        for _,file in ipairs(files) do
            if not buildRowsByFile[file:lower()] then
                local entry=BuildFiles.Read(BUILD_DIR,file)
                if type(entry)=='table' and entry.Kind=='HomeBrewBuild'
                    and entry.Deleted~=true then
                    local valid=BuildData.Validate(entry)
                    if valid then additions[#additions+1]={Name=entry.Name,
                        File=file,Level=entry.LevelCount,
                        StartingClass={Class=entry.Levels[1].Class,
                            SubClass=entry.Levels[1].SubClass}} end
                end
            end
        end
        table.sort(additions,function(a,b)
            return a.Name:lower()<b.Name:lower()
        end)
        for _,entry in ipairs(additions) do
            buildEntries[#buildEntries+1]=entry
            buildRowsByFile[entry.File:lower()]=true
            local item=Ext.UI.Instantiate(BUILD_ROW_TYPE)
            item.Name=entry.Name
            item.Detail=PresetBuildDetail(entry)
            ownerVM.PR_BuildRows[#ownerVM.PR_BuildRows+1]=item
        end
        NavigationLog('BUILD_PRESET_DISCOVERY '..tostring(BuildFiles.LastDiscoveryReport())
            ..' listed='..#buildEntries)
        return true
    end
    RefreshBuildEntries(vm)
    local function BuildLive()
        return CurrentVM()
    end
    local function EnterBuild(mode)
        local active=BuildLive()
        if not active or not active.PR_PopupVisible then return end
        if mode~='Save' and mode~='Load' then return end
        active.PR_BuildOpen=true
        active.PR_BuildSaveMode=mode=='Save'
        active.PR_BuildLoadMode=mode=='Load'
        active.PR_BuildTitle=mode=='Save' and 'Save Character Build' or 'Load Character Build'
        active.PR_BuildStatus=''
        local discovered=true
        local why=nil
        if mode=='Load' then discovered,why=RefreshBuildEntries(active) end
        active.PR_BuildSelectedIndex=-1
        active.PR_BuildCanLoad=false
        active.PR_BuildCanDelete=false
        if mode=='Load' then
            if not discovered then active.PR_BuildStatus=tostring(why)
            elseif #buildEntries==0 then active.PR_BuildStatus='No builds saved yet.' end
        end
        active.PR_ModeSelectVisible=false
        active.PR_BuildButtonsVisible=false
        buildReplacePending=false;buildDeletePending=false
        active.PR_BuildSaveLabel='Save'
    end
    local function BuildLoadIncompatibilityText(reason)
        -- This message identifies the ONLY class/subclass that matters for
        -- loading: the recorded starting class, not a later multiclass.
        if reason=='Starting class or subclass differs from the saved build.' then
            return 'Incompatible Starting Class or Subclass'
        end
        return 'Cannot load build: '..tostring(reason)
    end
    local function RefreshBuildSelection(active,showReason)
        if not active or not active.PR_BuildLoadMode then return false end
        local selected=tonumber(active.PR_BuildSelectedIndex) or -1
        local entry=selected%1==0 and selected>=0 and selected<#buildEntries
            and buildEntries[selected+1] or nil
        local compatible,reason=CanLoadBuildEntry(entry)
        active.PR_BuildCanLoad=(not active.PR_BuildBusy) and compatible==true
        -- An incompatible preset can still be deleted; only loading is blocked.
        active.PR_BuildCanDelete=(not active.PR_BuildBusy) and entry~=nil
        if showReason then
            active.PR_BuildStatus=entry and not compatible
                and BuildLoadIncompatibilityText(reason) or ''
        end
        NavigationLog('BUILD_PRESET_SELECTED index='..tostring(selected)
            ..' compatible='..tostring(compatible)..' reason='..tostring(reason))
        return compatible==true,reason
    end
    PR.RefreshBuildSelection=function(active)
        return RefreshBuildSelection(active or BuildLive(),false)
    end
    vm.PR_BuildSelectionChanged:SetHandler(function()
        local active=BuildLive()
        if not active or not active.PR_BuildLoadMode or active.PR_BuildBusy then return end
        buildDeletePending=false
        RefreshBuildSelection(active,true)
    end)
    vm.PR_BuildOpenSave:SetHandler(function() if mode=='choose' then EnterBuild('Save') end end)
    vm.PR_BuildOpenLoad:SetHandler(function() if mode=='choose' then EnterBuild('Load') end end)
    vm.PR_BuildBack:SetHandler(function()
        local active=BuildLive();if not active then return end
        if active.PR_BuildBusy then return end
        if buildReplacePending or buildDeletePending then
            buildReplacePending=false;buildDeletePending=false
            active.PR_BuildSaveLabel='Save';active.PR_BuildStatus='';return
        end
        active.PR_BuildOpen=false;active.PR_ModeSelectVisible=true
        active.PR_BuildButtonsVisible=true
        active.PR_BuildCanDelete=false
    end)
    vm.PR_BuildSave:SetHandler(function()
        local active=BuildLive()
        if not active or not active.PR_BuildSaveMode or active.PR_BuildBusy then return end
        local name=tostring(active.PR_BuildName or '')
        local valid,clean=pcall(BuildFiles.CleanName,name)
        if not valid then active.PR_BuildStatus=tostring(clean);return end
        local existing=BuildFiles.FileFor(clean,'build')
        local exists=Ext.IO.LoadFile(BUILD_DIR..'/'..existing)~=nil
        if exists and not buildReplacePending then
            buildReplacePending=true;active.PR_BuildSaveLabel='Replace'
            active.PR_BuildStatus='A preset with this name already exists. Select Replace to overwrite it.'
            return
        end
        active.PR_BuildBusy=true;active.PR_BuildCanSave=false
        active.PR_BuildStatus='Saving historical build…'
        PartialRespecChannel:SendToServer({Character=character,
            BuildPresetOperation='Save',Name=clean,Replace=buildReplacePending})
    end)
    vm.PR_BuildLoad:SetHandler(function()
        local active=BuildLive()
        if not active or not active.PR_BuildLoadMode or active.PR_BuildBusy then return end
        local compatible,reason=RefreshBuildSelection(active,false)
        if not compatible then
            active.PR_BuildStatus=BuildLoadIncompatibilityText(reason)
            return
        end
        local entry=buildEntries[(tonumber(active.PR_BuildSelectedIndex) or -1)+1]
        local preset,why=BuildFiles.Read(BUILD_DIR,entry.File)
        if not preset then active.PR_BuildStatus=tostring(why);return end
        local valid,why=BuildData.Validate(preset)
        if not valid then active.PR_BuildStatus=tostring(why);return end
        -- A build is applied only by the explicit Load button, never by
        -- selecting a row. Server preflights and assembles it BEFORE the
        -- native level-one Confirm is allowed to execute. Reuse the proven
        -- engine-owned class replay, not the ordinary historical editor.
        if partialPendingRequestId then return end
        partialConfirmSequence=partialConfirmSequence+1
        partialPendingRequestId=tostring(character)..':build-auto:'..tostring(partialConfirmSequence)
        partialPendingCharacter=character
        partialAckWaitTicks=0
        buildPendingPreset=nil
        buildImportFile=nil
        active.PR_BuildBusy=true
        active.PR_BuildCanLoad=false
        active.PR_BuildCanDelete=false
        active.PR_BuildStatus='Validating and applying saved build…'
        NavigationLog('BUILD_PRESET_DIRECT_APPLY_REQUEST file='..tostring(entry.File)
            ..' id='..partialPendingRequestId)
        PartialRespecChannel:SendToServer({Character=character,
            NativeFirstLevelSlider=true,BuildPresetAutoApply=true,
            BuildPresetFile=entry.File,RequestId=partialPendingRequestId})
    end)
    vm.PR_BuildDelete:SetHandler(function()
        local active=BuildLive()
        if not active or not active.PR_BuildLoadMode or active.PR_BuildBusy then return end
        local entry=buildEntries[(tonumber(active.PR_BuildSelectedIndex) or -1)+1]
        if not entry then active.PR_BuildStatus='Select a saved build.';return end
        if not buildDeletePending then
            buildDeletePending=true
            active.PR_BuildStatus='Select Delete again to hide '..entry.Name..'. The JSON file can also be deleted manually.'
            return
        end
        local path=BUILD_DIR..'/'..entry.File
        local previous=Ext.IO.LoadFile(path)
        if previous and Ext.IO.SaveFile(path..'.bak',previous)==false then
            active.PR_BuildStatus='Could not preserve the saved build.';return
        end
        local ok,why=BuildFiles.Tombstone(BUILD_DIR,entry.File)
        if not ok then active.PR_BuildStatus=tostring(why);return end
        active.PR_BuildStatus='Preset hidden. Reopen Respec to refresh the list.'
        active.PR_BuildCanDelete=false
        active.PR_BuildCanLoad=false
        buildDeletePending=false
    end)

    -- The original Ext.UI.Instantiate() Noesis proxy expires after the popup
    -- mounts. Resolve the live DataContext for every later navigation event.
    -- Only startup initialization may use the freshly instantiated VM.
    local function SetMode(nextMode, initialVM)
        -- Level-one characters have no historical progression to preserve.
        -- Full Respec stays available; guard commands even if UI is bypassed.
        if maxLevel<=1 and (nextMode=="partial" or nextMode=="editor") then
            NavigationLog("RESPEC_LEVEL_ONE_HISTORICAL_BLOCK mode="..nextMode)
            return false
        end
        local current = initialVM or CurrentVM()
        if not current then
            NavigationLog("MODE " .. tostring(nextMode) .. ": live popup ViewModel unavailable")
            return false
        end
        if nextMode == "editor" then
            -- Native historical editing starts on the next tick. Keep the
            -- already-visible chooser exactly as it is until ShowPreview
            -- succeeds and hides this popup; otherwise the Selective Respec
            -- heading/help flash above an empty transitional panel.
            -- Preserve the live widget tree for CurrentVM/ShowPreview.
            -- The editor state still changes immediately for command guards.
            mode = nextMode
            return true
        end
        current.PR_ModeSelectVisible = (nextMode == "choose")
        current.PR_BuildButtonsVisible = (nextMode == "choose")
        current.PR_PartialViewVisible = (nextMode == "partial")
        -- Selective Respec lives exclusively in BG3's native CharacterRespec.
        -- Never reveal the old custom Apply/Stage historical editor, even
        -- during one deferred tick or after an unsuccessful native bind.
        current.PR_EditorViewVisible = false
        current.PR_HasLevelSlider = (nextMode == "partial")
        if nextMode == "partial" then
            current.PR_ModeTitle = "Partial Respec"
            current.PR_ModeHelp = "Select the first level to rebuild. Your earlier levels are preserved."
        else
            current.PR_ModeTitle = "Respec"
            current.PR_ModeHelp = "Choose how you want to rebuild your character."
        end
        mode = nextMode
        return true
    end
    SetMode("choose", vm)
    NavigationLog("BuildVM initialized: mode=choose; level=" .. tostring(maxLevel))
    -- The new menu buttons use Noesis Click event triggers in XAML. Keep
    -- their own registered commands instead of hijacking the existing ones.
    vm.PR_OpenPartialRespec:SetHandler(function()
        NavigationLog("CLICK Partial Respec")
        local ok, applied = pcall(SetMode, "partial")
        NavigationLog(ok and applied and "MODE partial applied" or ("MODE partial failed: " .. tostring(applied)))
    end)
    vm.PR_OpenBuildEditor:SetHandler(function()
        NavigationLog("CLICK Selective Respec")
        -- A second click during the one-tick handoff must not queue a
        -- duplicate native ShowPreview mount.
        if mode ~= "choose" then return end
        buildImportFile=nil
        if not SetMode("editor") then return end
        local live=CurrentVM()
        if not live or live.PR_EditorBusy then return end
        live.PR_SelectedLevel=1 -- enter at the character's first historical level
        -- Defer native entry until Noesis has switched away from the mode
        -- selector. The overlay might not have mounted in the click frame.
        Ext.OnNextTick(function()
            if mode=="editor" and OpenNativeLevelEditor then OpenNativeLevelEditor() end
        end)
    end)
    OpenNativeLevelEditor = function()
        if mode ~= "editor" then return end
        local current = CurrentVM()
        if not current or current.PR_EditorBusy then return end
        local bridge = _G.HB_NativeLevelBridge
        if not bridge or not bridge.ShowPreview then
            SetMode("choose")
            current.PR_ModeHelp = "The native Selective Respec screen is unavailable. Exit respec and retry; see HB_NativeLevelScreen_Diagnostics.txt."
            NavigationLog("RESPEC_NATIVE_ENTRY_UNAVAILABLE; legacy editor suppressed")
            return
        end
        local opened = bridge.ShowPreview(levelSummaries, maxLevel,
            SelectedLevel(current, maxLevel), function(jumpToLevel)
                local active = CurrentVM()
                if active then
                    if jumpToLevel then
                        active.PR_SelectedLevel = math.max(1, math.min(maxLevel, jumpToLevel))
                    end
                    RefreshLevelText(active, levelSummaries, SelectedLevel(active,maxLevel),
                        stagedResources, stagedPassives, cursors, feedback, stagedOther, otherCursors)
                    active.PR_PopupVisible = true
                    -- Return to the supported mode chooser after closing the
                    -- native editor, never the old Selective Respec fallback.
                    SetMode("choose")
                end
            end, function(level, selectorId, passiveList, from, to)
                -- Verify the source group again before staging anything.
                -- The native preview never alters the native character VM.
                if mode ~= "editor" then return false, "Edit Build is not active." end
                local active = CurrentVM()
                -- The popup is hidden while the native-side list is visible;
                -- its visual tree may temporarily be unavailable to FindWidget.
                -- The editing mode/staging tables remain valid Lua state.
                if active and active.PR_EditorBusy then return false, "Build editing is busy." end
                for _, group in ipairs(GroupsAtLevel(levelSummaries, level)) do
                    if tostring(group.SelectorId)==tostring(selectorId)
                        and tostring(group.PassiveList)==tostring(passiveList) then
                        return StagePassiveAt(level, group, from, to)
                    end
                end
                return false, "That selector is no longer part of this level."
            end, StagedPassiveRows(stagedPassives),
            function(level, newResource)
                if not StageResourceAt then return false, "Resource editing is not ready." end
                return StageResourceAt(level, newResource)
            end,
            function(level, row, newChoice)
                if type(row)=="table" and (row.Kind=="HB_GenericSpellAdd"
                    or row.Kind=="HB_GenericSpellRecorded") then
                    if mode~="editor" then return false,"Selective Respec editor is not active." end
                    local featId=tostring(row.FeatId or ""):lower()
                    local selectorIndex=tonumber(row.SelectorIndex)
                    local contract=rawget(_G,"HB_GENERIC_FEATS") or HB_GENERIC_FEATS
                    local groups=contract and contract.SpellSelectors and contract.SpellSelectors(featId)
                    local group=groups and selectorIndex and groups[selectorIndex]
                    if not group or tostring(row.List or "")~=group.List then
                        return false,"Spell selector differs from the installed feat definition."
                    end
                    local source,stage,count=nil,nil,0
                    for _,choice in ipairs(OtherAtLevel(levelSummaries,level)) do
                        if choice.Kind=="Feat" then
                            source=choice;count=count+1
                            stage=stagedOther[level] and stagedOther[level][OtherKey(choice)]
                        end
                    end
                    if count~=1 or not source then
                        return false,"Original feat is unavailable."
                    end
                    if row.Kind=="HB_GenericSpellRecorded" and not stage
                        and tostring(source.From or "")==featId then
                        -- Re-edit a feat already owned in this save. Recover
                        -- every original group from the authoritative level
                        -- summary; do not invent or discard any spell slots.
                        local original,seen,owned={},{},0
                        for index,g in ipairs(groups) do original[index]={} end
                        for _,recorded in ipairs(OtherAtLevel(levelSummaries,level)) do
                            if (recorded.Kind=="Spell" or recorded.Kind=="Cantrip")
                                and tostring(recorded.FeatOwnerId or "")==featId then
                                owned=owned+1
                                local match=nil
                                for index,g in ipairs(groups) do
                                    if tostring(recorded.List or "")==g.List
                                        and tostring(recorded.SelectorId or "")==g.Selector
                                        and tonumber(recorded.DefinitionIndex)==g.Index-1
                                        and ((recorded.Kind=="Cantrip")==g.Cantrip)
                                        and tostring(recorded.Source or "")=="Upgrades.Spells" then
                                        if match then return false,"Ambiguous recorded spell selector." end
                                        match=index
                                    end
                                end
                                if not match or seen[tostring(recorded.From or "")] then
                                    return false,"Original spell selection ownership is ambiguous."
                                end
                                seen[tostring(recorded.From)]=true
                                original[match][#original[match]+1]=tostring(recorded.From)
                            end
                        end
                        local total=0
                        for index,g in ipairs(groups) do
                            if #original[index]~=g.Count then
                                return false,"Original feat has an incomplete recorded spell group."
                            end
                            total=total+#original[index]
                        end
                        if owned~=total or owned==0 then
                            return false,"Original feat spell record counts do not agree."
                        end
                        stage={Level=level,Kind="Feat",Source=source.Source,
                            List=source.List,EntryIndex=source.EntryIndex,
                            SlotIndex=source.SlotIndex,From=source.From,To=source.From,
                            GenericFeatChoices=original}
                        stagedOther[level]=stagedOther[level] or {}
                        stagedOther[level][OtherKey(source)]=stage
                    end
                    if not stage or stage.Kind~="Feat"
                        or stage.To~=featId or stage.From~=source.From then
                        return false,"Select the replacement feat first."
                    end
                    local id=tostring(newChoice or "")
                    local foundStat,stat=pcall(Ext.Stats.Get,id)
                    if not foundStat or not stat then return false,"Spell is not installed." end
                    local foundRank,rawRank=pcall(function() return stat.Level end)
                    local rank=foundRank and tonumber(rawRank) or nil
                    if rank==nil then
                        local ok,value=pcall(function() return stat.SpellLevel end)
                        rank=ok and tonumber(value) or nil
                    end
                    if rank==nil or (group.Cantrip and rank~=0)
                        or (not group.Cantrip and rank==0) then
                        return false,"Selected spell is not valid for this feat group."
                    end
                    local options=rawget(_G,"HB_GENERIC_SPELL_OPTIONS")
                    local cached=options and options[group.List.."|"..tostring(group.Cantrip)]
                    local permitted=false
                    for _,option in ipairs(cached or {}) do
                        if tostring(option.PassiveId or "")==id then permitted=true;break end
                    end
                    if not permitted then return false,"Spell is not in the installed feat's spell list." end
                    local choices=stage.GenericFeatChoices or {}
                    local existing=choices[selectorIndex] or {}
                    local updated,found,seen={},false,{}
                    for _,entry in ipairs(existing) do
                        if seen[entry] then return false,"Duplicate staged spell." end
                        seen[entry]=true
                        if entry==id then found=true else updated[#updated+1]=entry end
                    end
                    if not found then
                        if #updated>=group.Count then return false,"Unselect another spell first." end
                        updated[#updated+1]=id
                    end
                    choices[selectorIndex]=updated
                    stage.GenericFeatChoices=choices
                    NavigationLog("GENERIC_SPELL_CLICK_ACCEPT level="..tostring(level)
                        .." feat="..featId.." index="..selectorIndex.." count="..#updated)
                    return true,tostring(#updated).."/"..group.Count.." selected"
                end
                if type(row)=="table" and row.Kind=="HB_GenericPassiveAdd" then
                    if mode~="editor" then
                        NavigationLog("GENERIC_PASSIVE_CLICK_REJECT level="..tostring(level)
                            .." reason=editor_not_active")
                        return false,"Selective Respec editor is not active."
                    end
                    local featId=tostring(row.FeatId or ""):lower()
                    local selectorIndex=tonumber(row.SelectorIndex)
                    -- NativeHistoricalPreview renders these entries from the
                    -- same canonical feat definition. Prefer its live shared
                    -- contract over an early local fallback loaded while the
                    -- startup UI was still initializing. Do not trust caller-
                    -- supplied group counts, names or passive IDs.
                    local contract=rawget(_G,"HB_GENERIC_FEATS")
                    local optionIds=rawget(_G,"HB_GENERIC_OPTION_IDS")
                    if type(contract)~="table" or type(contract.PassiveSelectors)~="function" then
                        contract=HB_GENERIC_FEATS
                    end
                    if type(optionIds)~="table" then optionIds=HB_GENERIC_OPTION_IDS end
                    local groups=contract and contract.PassiveSelectors(featId)
                    local group=groups and selectorIndex and groups[selectorIndex]
                    local listId=group and tostring(group.List or "") or ""
                    local suppliedList=tostring(row.List or "")
                    local options=optionIds and optionIds[listId]
                    if not group or HB_PASSIVE_PAIR_ALLOWED[featId]
                        or suppliedList~=listId or type(options)~="table" or #options==0 then
                        -- Never silently reject an otherwise live native click.
                        -- This reports exactly which catalog input differed.
                        NavigationLog("GENERIC_PASSIVE_CATALOG_REJECT feat="..featId
                            .." index="..tostring(selectorIndex)
                            .." groupCount="..tostring(groups and #groups)
                            .." sourceList="..listId.." clickedList="..suppliedList
                            .." optionCount="..tostring(options and #options)
                            .." localContract="..tostring(contract==HB_GENERIC_FEATS))
                        return false,"Feat selector cannot be verified against the installed definition."
                    end
                    local source,stage,count=nil,nil,0
                    for _,choice in ipairs(OtherAtLevel(levelSummaries,level)) do
                        if choice.Kind=="Feat" then
                            source=choice;count=count+1
                            stage=stagedOther[level] and stagedOther[level][OtherKey(choice)]
                        end
                    end
                    if count~=1 or not stage or stage.Kind~="Feat" or stage.To~=featId
                        or stage.From~=source.From then
                        return false,"Select the replacement feat before editing its choices."
                    end
                    local id=tostring(newChoice or "")
                    local allowed=false
                    for _,entry in ipairs(options) do
                        if entry==id then allowed=true;break end
                    end
                    if not allowed then return false,"Selected passive is not in the feat's source list." end
                    local ok,stat=pcall(Ext.Stats.Get,id)
                    if not ok or not stat then return false,"Selected passive is not installed." end
                    local choices=stage.GenericFeatChoices or {}
                    local selected=choices[selectorIndex] or {}
                    local nextIds,found,seen={},false,{}
                    for _,picked in ipairs(selected) do
                        if seen[picked] then return false,"Staged feat selector is duplicated." end
                        seen[picked]=true
                        if picked==id then found=true else nextIds[#nextIds+1]=picked end
                    end
                    if not found then
                        if #nextIds>=group.Count then
                            return false,"Unselect one of this group's choices first."
                        end
                        nextIds[#nextIds+1]=id
                    end
                    choices[selectorIndex]=nextIds
                    stage.GenericFeatChoices=choices
                    NavigationLog("GENERIC_PASSIVE_CLICK_ACCEPT level="..tostring(level)
                        .." feat="..featId.." selector="..selectorIndex
                        .." id="..id.." count="..#nextIds.."/"..group.Count)
                    return true,tostring(#nextIds).."/"..group.Count.." selections"
                end
                if row and row.Kind=="HB_ElementalAdeptAdd" then
                    -- This is a NEW feat secondary selector, not an existing
                    -- CCLevelUp passive swap. Resolve the exact already-staged
                    -- feat transaction instead of inventing an independent edit.
                    -- Log every rejection: native checkbox events previously
                    -- appeared to do nothing when this callback failed.
                    local function Report(accepted,reason)
                        NavigationLog("ELEMENTAL_ADD_CLICK level="..tostring(level)
                            .." id="..tostring(newChoice)
                            .." accepted="..tostring(accepted)
                            .." reason="..tostring(reason))
                        return accepted,reason
                    end
                    if mode~="editor" then
                        return Report(false,"Selective Respec editor is not active.")
                    end
                    local recorded=OtherAtLevel(levelSummaries,level)
                    local feat,edit=nil,nil
                    local featCount=0
                    for _,candidate in ipairs(recorded) do
                        if candidate.Kind=="Feat" then
                            featCount=featCount+1
                            feat=candidate
                            edit=stagedOther[level] and stagedOther[level][OtherKey(candidate)]
                        end
                    end
                    if featCount~=1 or not edit or edit.Kind~="Feat"
                        or tostring(edit.To or "")~="fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
                        or tostring(edit.From or "")~=tostring(feat.From or "")
                        or tostring(edit.Level or "")~=tostring(level) then
                        return Report(false,"Select Elemental Adept as the new feat first (staged feat transaction unavailable).")
                    end
                    local legal={Acid=true,Cold=true,Fire=true,Force=true,
                        Lightning=true,Necrotic=true,Poison=true,Psychic=true,
                        Radiant=true,Thunder=true}
                    local id=tostring(newChoice or "")
                    local name=id:match("^ElementalAdept_([%a]+)$")
                    if not name or not legal[name] then
                        return Report(false,"That is not a valid Elemental Adept element.")
                    end
                    local list,already,seen={},false,{}
                    for _,existing in ipairs(edit.ElementChoices or {}) do
                        existing=tostring(existing)
                        local element=existing:match("^ElementalAdept_([%a]+)$")
                        if not element or not legal[element] or seen[existing] then
                            return Report(false,"Previously staged element selections are invalid.")
                        end
                        seen[existing]=true
                        if existing==id then already=true
                        else list[#list+1]=existing end
                    end
                    if not already then
                        if #list>=2 then
                            return Report(false,"Unselect one of your two elements first.")
                        end
                        list[#list+1]=id
                    end
                    -- Keep the staged transaction authoritative. A hidden
                    -- popup's Noesis tree can be temporarily unavailable
                    -- during a native TogglePassive click; updating its
                    -- summary must NEVER turn an accepted choice into an
                    -- apparent failure or leave preview state out of sync.
                    edit.ElementChoices=list
                    local refreshed,err=pcall(Refresh)
                    if not refreshed then
                        NavigationLog("ELEMENTAL_ADD_POPUP_REFRESH_DEFERRED "..tostring(err))
                    end
                    return Report(true,(#list.."/2 Elemental Adept choices selected"))
                end
                if type(row)=="table" and row.Kind=="HB_AccordAdd" then
                    if mode~="editor" then return false,"Selective Respec is not active." end
                    local target="cdcbc538-883b-401c-a8ed-1373fb6d1720"
                    local source,stage,count=nil,nil,0
                    for _,option in ipairs(OtherAtLevel(levelSummaries,level)) do
                        if option.Kind=="Feat" then
                            count=count+1;source=option
                            stage=stagedOther[level] and stagedOther[level][OtherKey(option)]
                        end
                    end
                    if count~=1 or not stage or stage.Kind~="Feat"
                        or tostring(stage.To or "")~=target
                        or tostring(stage.From or "")~=tostring(source.From or "") then
                        return false,"Select Accord of the Arcane as the replacement feat first."
                    end
                    local id=tostring(newChoice or "")
                    local valid=false
                    local installed,resource=pcall(Ext.StaticData.Get,
                        "ffad33d2-e725-4655-ba80-0bc91e8002b3","SpellList")
                    if installed and resource then
                        local got,raw=pcall(function() return resource.Spells end)
                        if got then
                            if type(raw)=="string" then
                                for candidate in raw:gmatch("[^,;]+") do
                                    if candidate==id then valid=true;break end
                                end
                            elseif type(raw)=="table" then
                                for _,candidate in ipairs(raw) do
                                    if tostring(candidate)==id then valid=true;break end
                                end
                            end
                        end
                    end
                    local originalCatalog={"Projectile_AcidSplash","Projectile_ArcaneBarrage","Projectile_ArcaneSpheres","Shout_BladeSurge","Shout_BladeWard","Target_ChillTouch","Projectile_Cragrain","Target_CreateorDestroyWater","Target_CreateorExtinguishFlames","Shout_DisguiseSelf","Shout_Druidcraft","Projectile_FireBolt","Target_Friends","Target_Frostbite","Target_GreenFlameBlade","Target_Guidance","Target_Light","Target_MageHand","Target_MindSliver","Projectile_PiercingTorrent","Projectile_PoisonSpray","Shout_Prestidigitation","Target_PrimalSavagery","Shout_ProduceFlame","Rush_PsionicCharge","Projectile_RayOfFrost","Target_Resistance","Target_SacredFlame","Target_ShockingGrasp","Target_SpareTheDying","Target_SparkSurge","Shout_Shillelagh","Throw_TelekineticHurl","Target_ThornWhip","Shout_Thunderclap","Target_ThunderousStrike","Target_TollTheDead","Target_TrueStrike","Projectile_Warpstone","Shout_WordOfRadiance"}
                    if not valid then
                        for _,candidate in ipairs(originalCatalog) do
                            if candidate==id then valid=true;break end
                        end
                    end
                    if not valid then return false,"Cantrip is outside the verified Accord list." end
                    local statOK,stat=pcall(Ext.Stats.Get,id)
                    local levelOK,rank=pcall(function() return stat.Level or stat.SpellLevel end)
                    if not statOK or not stat or not levelOK or tonumber(rank)~=0 then
                        return false,"Cantrip rank cannot be verified."
                    end
                    local after,already={},false
                    for _,picked in ipairs(stage.AccordChoices or {}) do
                        if picked==id then already=true else after[#after+1]=picked end
                    end
                    if not already then
                        if #after>=2 then return false,"Uncheck an Accord cantrip first." end
                        after[#after+1]=id
                    end
                    stage.AccordChoices=after
                    NavigationLog("ACCORD_ADD_SELECTION level="..tostring(level)
                        .." cantrips="..table.concat(after,","))
                    return true,tostring(#after).."/2 Accord cantrips selected"
                end
                if type(row)=="table" and row.Kind=="HB_MultifacetedAdd" then
                    if mode~="editor" then return false,"Selective Respec is not active." end
                    local section=tostring(row.Section or "")
                    local caps={Archetype=1,Trait=1,Skills=4}
                    if not caps[section] then return false,"Unknown Multifaceted selector." end
                    local feat,stage,n=nil,nil,0
                    for _,candidate in ipairs(OtherAtLevel(levelSummaries,level)) do
                        if candidate.Kind=="Feat" then
                            n=n+1;feat=candidate
                            stage=stagedOther[level] and stagedOther[level][OtherKey(candidate)]
                        end
                    end
                    if n~=1 or not stage or stage.Kind~="Feat"
                        or tostring(stage.To or "")~="be0889d2-f9aa-472d-b942-592bff0f1ef3"
                        or tostring(stage.From or "")~=tostring(feat.From or "") then
                        return false,"Stage Multifaceted as the replacement feat first."
                    end
                    local catalogs={
                        Archetype={"AT_None","AT_ArcanePrecision","AT_ChaoticFortune","AT_CombatMastery","AT_ControlledAggro","AT_DeepenedResolve","AT_EmpoweredSummons","AT_FortifiedArmour","AT_ImposingWill","AT_IronBreaker","AT_IronFists","AT_MartialBalance","AT_MartialPrecision","AT_MeasuredArcana","AT_QuickReflexes","AT_ReactiveRetribution","AT_RestorativeTouch","AT_TemperedBody","AT_TemperedMind","AT_UncheckedForce","AT_WeaveBreaker"},
                        Trait={"CT_None","CT_AdrenalineSurge","CT_BlindEmotions","CT_BloodyResults","CT_BorrowedTime","CT_BreatheDeep","CT_ConfidentlyIncorrect","CT_CriticalLoss","CT_Crybaby","CT_DelusionsintheDark","CT_Gambler","CT_GentleGiant","CT_GildedPilfer","CT_GlassCannon","CT_HandsofCalamity","CT_HastyReflexes","CT_Haymaker","CT_HealthyChills","CT_HeavyHanded","CT_Hyperfixation","CT_Ironbourne","CT_ImmovableBoulder","CT_Lefty","CT_LetMeSoloThem","CT_LoneWolf","CT_Narcoleptic","CT_NaturalMedium","CT_Overcharged","CT_OverlyDifficult","CT_Packing","CT_PlanarSkipping","CT_ReactiveLoss","CT_Reckless","CT_SlowRoller","CT_SplitFocus","CT_Stinky","CT_SunlightAversion","CT_Unhinged","CT_UnstableSource","CT_WaningImmortality","CT_Wretch"},
                        Skills={"Athletics","Acrobatics","SleightOfHand","Stealth","Arcana","History","Investigation","Nature","Religion","AnimalHandling","Insight","Medicine","Perception","Survival","Deception","Intimidation","Performance","Persuasion"}
                    }
                    local picked=tostring(newChoice or "")
                    local legal=false
                    for _,allowed in ipairs(catalogs[section]) do if allowed==picked then legal=true;break end end
                    if not legal then return false,"Multifaceted choice is outside its defined list." end
                    local all=stage.MultifacetedChoices or {Archetype={},Trait={},Skills={}}
                    local previous=all[section] or {}
                    local nextPicks,found={},false
                    for _,id in ipairs(previous) do
                        if tostring(id)==picked then found=true else nextPicks[#nextPicks+1]=id end
                    end
                    if not found then
                        if #nextPicks>=caps[section] then
                            return false,"Uncheck an existing choice before choosing a replacement."
                        end
                        nextPicks[#nextPicks+1]=picked
                    end
                    all[section]=nextPicks
                    stage.MultifacetedChoices=all
                    NavigationLog("MULTIFACETED_ADD_SELECTION level="..level
                        .." section="..section.." ids="..table.concat(nextPicks,","))
                    return true,tostring(#nextPicks).."/"..caps[section].." Multifaceted "..section.." selected"
                end
                if type(row)=="table" and row.Kind=="HB_PassiveFeatAdd" then
                    if mode~="editor" then return false,"Selective Respec is not active." end
                    local featId=tostring(row.FeatId or "")
                    local allowed=HB_PASSIVE_PAIR_ALLOWED[featId]
                    if not allowed then return false,"Unsupported two-passive feat." end
                    local original,stage,count=nil,nil,0
                    for _,entry in ipairs(OtherAtLevel(levelSummaries,level)) do
                        if entry.Kind=="Feat" then
                            count=count+1
                            original=entry
                            stage=stagedOther[level] and stagedOther[level][OtherKey(entry)]
                        end
                    end
                    if count~=1 or not stage or stage.Kind~="Feat"
                        or tostring(stage.To or "")~=featId
                        or tostring(stage.From or "")~=tostring(original.From or "") then
                        return false,"Stage this two-choice feat in the feat tab first."
                    end
                    local id=tostring(newChoice or "")
                    if not allowed[id] then return false,"Passive not in the feat's defined selector list." end
                    local remaining,already,seen={},false,{}
                    for _,picked in ipairs(stage.PassiveFeatChoices or {}) do
                        picked=tostring(picked)
                        if not allowed[picked] or seen[picked] then
                            return false,"Existing staged feat choices are invalid."
                        end
                        seen[picked]=true
                        if picked==id then already=true else remaining[#remaining+1]=picked end
                    end
                    if not already then
                        if #remaining>=2 then return false,"Unselect an existing passive first." end
                        remaining[#remaining+1]=id
                    end
                    stage.PassiveFeatChoices=remaining
                    local current=CurrentVM()
                    if current and current.PR_PopupVisible then
                        local refreshed,errorMessage=pcall(Refresh)
                        if not refreshed then NavigationLog("PASSIVE_PAIR_REFRESH_DEFERRED "..tostring(errorMessage)) end
                    end
                    NavigationLog("PASSIVE_PAIR_CLICK level="..tostring(level).." feat="..featId
                        .." selections="..table.concat(remaining,","))
                    return true,tostring(#remaining).."/2 feat passive choices selected"
                end
                if not StageOtherAt then return false, "Choice editing is not ready." end
                return StageOtherAt(level, row, newChoice)
            end,
            stagedResources, StagedOtherRows(stagedOther), function()
                if not CommitNativeLevelRespec then return false,"Selective Respec is not ready." end
                return CommitNativeLevelRespec()
            end,
            function()
                if mode~="editor" then return false,"Selective Respec editor is unavailable." end
                if not character then return false,"Character is unavailable." end
                nativeSliderPrepareSeq=nativeSliderPrepareSeq+1
                local requestId=tostring(character)..":native-slider:"..nativeSliderPrepareSeq
                nativeSliderPendingId=requestId
                local resources,passives,others={},StagedPassiveRows(stagedPassives),StagedOtherRows(stagedOther)
                for i=2,maxLevel do
                    if stagedResources[i] then resources[#resources+1]=stagedResources[i] end
                end
                -- Native level one owns ALL level-one selections. The saved
                -- higher-level snapshot may contain edits at levels >=2 only.
                for _,batch in ipairs({passives,others,resources}) do
                    for _,edit in ipairs(batch) do
                        if tonumber(edit.Level)==1 then
                            nativeSliderPendingId=nil
                            return false,"Unverified historical level-one edits cannot be combined with native respec."
                        end
                    end
                end
                -- The player may return to vanilla level one before they
                -- have resolved its conflict with a higher-level spell. Do
                -- not submit an incomplete inverse exchange merely to
                -- navigate backward; an actual unchanged/no-edit restore
                -- remains independently guarded by the server's post-Confirm
                -- native-versus-historical duplicate audit.
                local liveSwap=HB_NATIVE_L1_SLIDER and HB_NATIVE_L1_SLIDER.LiveSpellSwap
                local ownedDisplacement=nil
                if liveSwap and #others==1 and #passives==0 and #resources==0 then
                    local edit=others[1]
                    if edit.Kind=="Spell" and tonumber(edit.Level)>=2
                        and edit.From==liveSwap.To and edit.To~=liveSwap.To then
                        ownedDisplacement={From=liveSwap.From,To=liveSwap.To,
                            Replacement=edit.To}
                    end
                end
                NavigationLog("NATIVE_SLIDER_L1_PREPARE_SENT id="..requestId
                    .." higherPassives="..#passives.." higherOther="..#others
                    .." nativeDisplacement="..tostring(ownedDisplacement~=nil))
                PartialRespecChannel:SendToServer({Character=character,
                    NativeFirstLevelSlider=true,Level=maxLevel,RequestId=requestId,
                    ExperimentalExtraResourceEdits=resources,
                    ExperimentalClassPassiveEdits=passives,
                    ExperimentalOtherChoiceEdits=others,
                    NativeLevelOneSpellSwap=ownedDisplacement,
                    BuildPresetFile=buildImportFile})
                return true
            end)
        if opened then
            current.PR_PopupVisible = false
            NavigationLog("Opened Selective Respec native history view")
        else
            SetMode("choose")
            current.PR_ModeHelp = "The native Selective Respec screen could not be opened. Exit respec and retry; see HB_NativeLevelScreen_Diagnostics.txt."
            NavigationLog("RESPEC_NATIVE_ENTRY_FAILED; legacy editor suppressed")
        end
    end
    vm.PR_OpenNativePreview:SetHandler(OpenNativeLevelEditor)
    vm.PR_BackToModes:SetHandler(function()
        local current = CurrentVM()
        NavigationLog("CLICK Back; editorBusy=" .. tostring(current and current.PR_EditorBusy))
        if not current then return end
        -- Allow Back even while waiting for a server backup. An old ACK can
        -- arrive after cancellation; its request ID is ignored below.
        if mode=="partial" and partialPendingRequestId then
            NavigationLog("PARTIAL_COMMIT_CANCEL id="..tostring(partialPendingRequestId))
            PartialRespecChannel:SendToServer({Character=character,Cancelled=true,
                RequestId=partialPendingRequestId})
            ClearPartialPending()
            current.PR_EditorBusy=false
        elseif current.PR_EditorBusy then
            return
        end
        local ok, applied = pcall(SetMode, "choose")
        NavigationLog(ok and applied and "MODE choose applied" or ("MODE choose failed: " .. tostring(applied)))
    end)

    local function Refresh()
        local current = CurrentVM()
        if current then
            RefreshLevelText(current, levelSummaries, SelectedLevel(current,maxLevel),
                stagedResources, stagedPassives, cursors, feedback, stagedOther, otherCursors)
        end
    end
    RefreshLevelText(vm, levelSummaries, maxLevel, stagedResources, stagedPassives, cursors, feedback, stagedOther, otherCursors)
    vm.PR_LevelChangedCommand:SetHandler(function()
        local current = CurrentVM()
        if not current then return end
        local level = SelectedLevel(current, maxLevel)
        current.PR_SelectedLevel = level
        Refresh()
    end)
    StageResourceAt = function(level, to)
        if mode ~= "editor" then return false, "Edit Build is not active." end
        level=tonumber(level)
        to=tostring(to or "")
        local choice = level and levelSummaries[level] and levelSummaries[level].LevelChoices
        local original = choice and choice.ExtraResources
        if not level or level<=1 or type(original)~="table" or #original~=1
            or not EXTRA_RESOURCE_NAMES[tostring(original[1])] or not EXTRA_RESOURCE_NAMES[to] then
            return false, "This historical Extra Resource selection cannot be edited."
        end
        local from=tostring(original[1])
        if to~=from then
            for i, summary in ipairs(levelSummaries) do
                if i~=level then
                    local current=summary.LevelChoices and summary.LevelChoices.ExtraResources or {}
                    local picked=stagedResources[i] and stagedResources[i].To or current[1]
                    if tostring(picked)==to then
                        feedback[level]="You already selected an additional "..ExtraResourceName(to).." at character level "..i
                        Refresh()
                        return false,feedback[level]
                    end
                end
            end
        end
        stagedResources[level]=to~=from and {Level=level,From=from,To=to} or nil
        feedback[level]=to~=from and ("Staged Extra Resource: "..ExtraResourceName(to))
            or "Original Extra Resource restored."
        Refresh()
        return true,feedback[level]
    end
    local function StageResource(to)
        local active=CurrentVM()
        if not active then return end
        return StageResourceAt(SelectedLevel(active,maxLevel),to)
    end
    vm.PR_EditAction:SetHandler(function() StageResource(RESOURCE_CHOICES[1]) end)
    vm.PR_EditBonusAction:SetHandler(function() StageResource(RESOURCE_CHOICES[2]) end)
    vm.PR_EditReaction:SetHandler(function() StageResource(RESOURCE_CHOICES[3]) end)

    local function PassiveCursor()
        local current = CurrentVM()
        local level = current and SelectedLevel(current,maxLevel)
        if not current or not level then return nil end
        local target,cursor,targets = SelectedPassiveTarget(levelSummaries,level,cursors)
        if not target or #(target.Group.Options or {}) == 0 then return nil end
        return level,target,cursor,targets
    end
    vm.PR_PassiveTargetPrevious:SetHandler(function()
        local level,target,cursor,targets=PassiveCursor(); if not level then return end
        cursor.Target = (cursor.Target-2) % #targets + 1; Refresh()
    end)
    vm.PR_PassiveTargetNext:SetHandler(function()
        local level,target,cursor,targets=PassiveCursor(); if not level then return end
        cursor.Target = cursor.Target % #targets + 1; Refresh()
    end)
    vm.PR_PassiveOptionPrevious:SetHandler(function()
        local level,target,cursor=PassiveCursor(); if not level then return end
        cursor.Option = (cursor.Option-2) % #target.Group.Options + 1; Refresh()
    end)
    vm.PR_PassiveOptionNext:SetHandler(function()
        local level,target,cursor=PassiveCursor(); if not level then return end
        cursor.Option = cursor.Option % #target.Group.Options + 1; Refresh()
    end)
    vm.PR_PassiveReset:SetHandler(function()
        local level,target=PassiveCursor(); if not level then return end
        local key=PassiveEditKey(target.Group,target.From)
        if stagedPassives[level] then stagedPassives[level][key]=nil end
        feedback[level] = "Selected passive edit cleared."; Refresh()
    end)
    -- Both the familiar Edit Build arrows and the on-screen native-style
    -- historical list use the *same* staging/validation path. The original
    -- server-side replay remains entirely unchanged.
    StagePassiveAt = function(level, group, from, to)
        level = tonumber(level)
        from, to = tostring(from or ""), tostring(to or "")
        if not level or level < 1 or not group or from == "" or to == ""
            or (level==1 and (not levelSummaries[1]
                or not levelSummaries[1].LevelChoices
                or levelSummaries[1].LevelChoices.HistoryAvailable~=true
                or group.Editable==false or group.FeatOwnerVerified
                or group.LevelOneVerified~=true)) then
            return false, "That historical choice is not editable."
        end
        local key = PassiveEditKey(group, from)
        local picked, available = false, false
        for _, id in ipairs(group.Picked or {}) do
            if tostring(id) == from then picked = true end
        end
        for _, option in ipairs(group.Options or {}) do
            if tostring(option.PassiveId) == to then available = true end
        end
        if not picked or not available then
            return false, "Original or replacement choice is not in the recorded selector."
        end
        stagedPassives[level] = stagedPassives[level] or {}
        if to == from then
            stagedPassives[level][key] = nil
            feedback[level] = "Original option restored; historical swap cleared."
            Refresh()
            return true, feedback[level]
        end
        for i = 1, #levelSummaries do
            for _, otherGroup in ipairs(GroupsAtLevel(levelSummaries, i)) do
                for _, id in ipairs(otherGroup.Picked or {}) do
                    local otherKey = PassiveEditKey(otherGroup, id)
                    local changed = stagedPassives[i] and stagedPassives[i][otherKey]
                    local proposed = changed and changed.To or id
                    local freedNativeFirst=(i==1 and level>=2 and HB_NATIVE_L1_SLIDER
                        and type(HB_NATIVE_L1_SLIDER.OriginalFirstPassiveFreed)=="function"
                        and HB_NATIVE_L1_SLIDER.OriginalFirstPassiveFreed(to))
                    if tostring(proposed) == to and not freedNativeFirst
                        and not (i == level and otherKey == key) then
                        feedback[level] = "Already selected at character level " .. i .. ": " .. PassiveLabel(group, to)
                        Refresh()
                        return false, feedback[level]
                    end
                end
            end
        end
        stagedPassives[level][key] = {Level=level, SelectorId=group.SelectorId,
            PassiveList=group.PassiveList, From=from, To=to}
        feedback[level] = "Staged: " .. PassiveLabel(group,from) .. " -> " .. PassiveLabel(group,to)
        Refresh()
        return true, feedback[level]
    end
    vm.PR_PassiveStage:SetHandler(function()
        local level,target,cursor=PassiveCursor(); if not level then return end
        local option = target.Group.Options[cursor.Option]
        if option then StagePassiveAt(level,target.Group,target.From,option.PassiveId) end
    end)
    local function OtherCursor()
        local current=CurrentVM()
        if not current then return nil end
        local level=SelectedLevel(current,maxLevel)
        local row,cursor,all=SelectedOther(levelSummaries,level,otherCursors)
        if not row then return nil end
        return level,row,cursor,all
    end
    vm.PR_OtherTargetPrevious:SetHandler(function()
        local level,row,cursor,all=OtherCursor();if not level then return end
        cursor.Target=(cursor.Target-2)%#all+1;Refresh()
    end)
    vm.PR_OtherTargetNext:SetHandler(function()
        local level,row,cursor,all=OtherCursor();if not level then return end
        cursor.Target=cursor.Target%#all+1;Refresh()
    end)
    vm.PR_OtherOptionPrevious:SetHandler(function()
        local level,row,cursor=OtherCursor();if not level then return end
        cursor.Option=(cursor.Option-2)%#row.Options+1;Refresh()
    end)
    vm.PR_OtherOptionNext:SetHandler(function()
        local level,row,cursor=OtherCursor();if not level then return end
        cursor.Option=cursor.Option%#row.Options+1;Refresh()
    end)
    -- Mirror the native historical selector's basic preflight in the older
    -- Edit Build arrows. Otherwise a prohibited feat/spell can be staged in
    -- the fallback editor even though the native UI correctly refuses it.
    -- These checks are only early feedback; the SERVER always revalidates.
    -- Exact feat GUID flags from the user's supplied Feats.lsx; these are
-- additional negative safety evidence when Script Extender's runtime Feat
-- selectors/requirements accessor throws or omits its LSX member.
-- Treat unrecognized feats with unavailable runtime fields as PROTECTED.
HB_GENERIC_FEATS=(function()
    local ok,value=pcall(Ext.Require,"Shared/HB_GenericFeatContracts.lua")
    if ok and type(value)=="table" then return value end
    return {PassiveSelectors=function() return nil end,
        SpellSelectors=function() return nil end,
        Definition=function() return nil end, RequiredClass=function() return nil end,
        IsKnownFixedOnly=function() return false end}
end)()
HB_GENERIC_OPTION_IDS=(function()
    local ok,value=pcall(Ext.Require,"Shared/HB_GenericPassiveOptions.lua")
    return ok and type(value)=="table" and value or {}
end)()
local HB_SOURCE_FEAT_CONTRACTS={
    ["d215b9ad-9753-4d74-8ff9-24bf1dce53d6"]={s=true,r=false}, -- AbilityImprovement
    ["cdcbc538-883b-401c-a8ed-1373fb6d1720"]={s=true,r=false}, -- AccordoftheArcane
    ["f57bd72c-be64-4855-9e3a-bb7d7665e656"]={s=false,r=false}, -- Alchemist
    ["d674aa33-8633-4b67-8623-b6788f0d5fc4"]={s=false,r=false}, -- Alert
    ["eab25714-15d6-4e26-b809-3fad832d0484"]={s=false,r=false}, -- AnchoredFocus
    ["94a78b4c-a8f2-404f-8cdc-2d454c13cb97"]={s=false,r=false}, -- ArcaneEchoes
    ["661eee63-ff91-4f29-9f21-3a974c9d6fe5"]={s=false,r=false}, -- Athleticism
    ["f692f7b5-ffd5-4942-91a1-a71ebb2f5e7c"]={s=false,r=false}, -- BlessingsoftheMoon
    ["71b65667-0eac-4e62-b878-fa862e88ebbf"]={s=false,r=false}, -- Charger
    ["56c3c247-35cf-4ffd-86dd-7d249cc1808f"]={s=true,r=false}, -- ClassDivergence_Barbarian
    ["cec2d95b-451c-40f8-8e17-9e547d363e8e"]={s=true,r=false}, -- ClassDivergence_Bard
    ["c09815f7-282b-4ccf-bd89-a51caa1b550f"]={s=true,r=false}, -- ClassDivergence_Cleric
    ["7bc235ac-7eeb-49d3-8249-c3313d87af75"]={s=true,r=false}, -- ClassDivergence_Druid
    ["0de08fff-ab18-442f-a0b1-f53e7be04c03"]={s=true,r=false}, -- ClassDivergence_Fighter
    ["b441c722-e4d4-4702-861a-039bfd77c124"]={s=true,r=false}, -- ClassDivergence_Monk
    ["d84c7f36-8c5b-4b17-b95a-e1da725f9004"]={s=true,r=false}, -- ClassDivergence_Paladin
    ["a533fde7-ee0a-46ce-92e2-9763201a54d2"]={s=true,r=false}, -- ClassDivergence_Ranger
    ["4f744a6e-8589-4a46-89ab-a95415a73245"]={s=true,r=false}, -- ClassDivergence_Rogue
    ["28e5fed3-bd41-4b74-ab48-b8e824ad3443"]={s=true,r=false}, -- ClassDivergence_Sorcerer
    ["1e1a9a4d-38f4-4a05-b080-d32c2b872250"]={s=true,r=false}, -- ClassDivergence_Warlock
    ["93d41226-d7af-495c-b023-08a6af077962"]={s=true,r=false}, -- ClassDivergence_Wizard
    ["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]={s=true,r=false}, -- ClassDivergence_Artificer
    ["26c6990b-d9f0-41a2-8108-209789fafc18"]={s=false,r=false}, -- CombatMedic
    ["455fc2d5-1c77-40e7-a010-0b51044ae74b"]={s=false,r=false}, -- Composed
    ["17ac3605-9a8a-41f3-9504-ffc17fffa03e"]={s=false,r=false}, -- DefensiveDuelist
    ["0a3b07bf-a806-4c77-9c8f-6e7c0965f9dd"]={s=false,r=false}, -- DualWielder
    ["681d5307-f0ed-4c94-8cf0-db0c51116f56"]={s=false,r=false}, -- Dunesis
    ["60dfd716-3ba8-4611-90ee-018b59775b1d"]={s=false,r=false}, -- Durable
    ["fdf0be80-cc1e-4501-bd2e-7a1ea737362c"]={s=true,r=false}, -- ElementalAdept
    ["b13c4744-1d45-42da-b92c-e09f598ab1c3"]={s=false,r=false}, -- GalvanizedStormsoul
    ["f3370916-6b35-4c5b-af36-19ca888cb43e"]={s=false,r=false}, -- GreaterImpact
    ["e061a323-3430-4cff-88d3-5eae7a1779a4"]={s=false,r=false}, -- IntrinsicArmoury
    ["816b1554-9384-49e9-aaa0-05dd622e60f7"]={s=false,r=false}, -- Lucky
    ["010f717e-c6e2-45cf-bbf9-298a72db4cad"]={s=false,r=false}, -- MageSlayer
    ["3fe71254-d1b2-44c7-886c-927552fe5f2e"]={s=false,r=false}, -- MartialAdept
    ["019564a0-f136-4139-94ea-040f94bbaf19"]={s=false,r=false}, -- MasonryofChaos
    ["c02f22c9-9a06-4001-b917-4d5cf09be399"]={s=false,r=false}, -- MeleeExpertise
    ["be0889d2-f9aa-472d-b942-592bff0f1ef3"]={s=true,r=false}, -- Multifaceted
    ["e8d1e7f6-d841-48ff-a83c-f1aaa16597ff"]={s=false,r=false}, -- Performer
    ["ed4e367d-d136-4285-abac-077147e84cf2"]={s=false,r=false}, -- PsionicDominance
    ["b153e75c-27a2-4412-95cd-60b477121679"]={s=false,r=false}, -- ReactiveAssault
    ["d7940fdc-44c6-4d0d-8997-56eb6e606587"]={s=false,r=false}, -- Resilient
    ["c06a8f0b-fbb8-4558-aa99-6985d45dfcad"]={s=false,r=false}, -- RestrictedTerritory
    ["922c48ff-8fe5-4212-b6ee-e48122ee67ef"]={s=false,r=false}, -- SavageAssault
    ["68f1ec15-2449-4ff1-aa72-6e35a0929091"]={s=false,r=false}, -- Sentinel
    ["0ef8204b-59c9-4ea2-adfb-fc984a7d3eb1"]={s=false,r=false}, -- Sharpshooter
    ["b29807ee-5cdd-4a5b-960c-1d1457488676"]={s=false,r=false}, -- Shieldbearer
    ["daed512b-e063-4c69-8b8c-ee0d1439266f"]={s=false,r=false}, -- Spellbreak
    ["46f6c764-44e0-4e58-8a3c-eb7ea0c0d887"]={s=false,r=false}, -- TavernBrawler
    ["a6e8c0dd-5389-4f62-ba97-2908e0bbb56b"]={s=false,r=false}, -- TogetherInTorment
    ["c760fcc0-c67a-4eea-a903-f051559b421f"]={s=false,r=false}, -- Tough
    ["dcd89533-e8ab-4660-a101-53bb14a920ca"]={s=false,r=false}, -- VisageofReflection
    ["47d60615-6d46-49ef-b993-1fa90274a90e"]={s=false,r=false}, -- WarCaster
    ["03777635-ef87-4d19-a859-92b8dd69f6dc"]={s=true,r=true}, -- ArtificerArcanist
    ["ce450c0d-a9d0-44a9-af97-2f2e8e990958"]={s=false,r=true}, -- ArtificerArtillerist
    ["2cbd8b96-78f0-4b29-ac6f-c59cb6d126c0"]={s=false,r=true}, -- ArtificerBattleSynthetic
    ["8dfca7e9-16a1-419c-bb92-faae1eed1bff"]={s=false,r=true}, -- ArtificerGrenadier
    ["35e99c06-63f9-429c-8064-25bc2e22e730"]={s=true,r=true}, -- ArtificerInfusedArcsmith
    ["c531fa20-17f2-4943-89e0-adf4f7a120b4"]={s=false,r=true}, -- ArtificerStriker
    ["4ffa557b-2ad4-4a8c-abe6-1d1965c07dd3"]={s=false,r=true}, -- BarbarianBeastheart
    ["75ce4c3a-884b-4c57-bec4-3e1cd0308523"]={s=false,r=true}, -- BarbarianBerserker
    ["f9fa2010-40ff-4d31-91cc-d72b150967fb"]={s=false,r=true}, -- BarbarianFrostbreaker
    ["de609f5b-bd4a-4155-b113-3e55093fc533"]={s=false,r=true}, -- BarbarianGiantsBlood
    ["6919302f-f2b9-44f5-8562-ec4315527292"]={s=false,r=true}, -- BarbarianRosemourn
    ["ae844b62-4b26-413d-8fce-20ca687f789a"]={s=true,r=true}, -- BarbarianWildSoul
    ["694647d6-2a79-4161-9bf0-d973e1ec2558"]={s=false,r=true}, -- BardCollegeOfCaptivation
    ["010dd210-461e-4aa8-b567-42f3ae52e2bd"]={s=true,r=true}, -- BardCollegeOfLore
    ["b296fca6-a2ad-4687-ac54-a359a65aed86"]={s=false,r=true}, -- BardCollegeofMoriendi
    ["3ce91e99-57d9-4c44-b80f-80e4c4952866"]={s=false,r=true}, -- BardCollegeofNostalgia
    ["e1b012c1-051a-4202-84cd-b037fc2ac6f8"]={s=false,r=true}, -- BardCollegeOfSteel
    ["43a56c6e-54b1-4151-97fc-0cc970fde672"]={s=false,r=true}, -- BardCollegeOfValour
    ["2544f577-59ed-47ae-868c-22ab0eab59a1"]={s=true,r=true}, -- ClericDeathDomain
    ["038aa39c-d4ca-41f0-8b25-8ca7b4356bc4"]={s=true,r=true}, -- ClericForgeDomain
    ["18586891-4b5f-4f08-879f-0960e202af11"]={s=true,r=true}, -- ClericIllusoryDomain
    ["abcb215a-f411-4b10-a804-f511467b956e"]={s=true,r=true}, -- ClericLifeDomain
    ["18659104-48f2-47d7-a4d5-87e3274f3308"]={s=true,r=true}, -- ClericTempestDomain
    ["ca55540b-9bf0-461d-936f-f4660b505775"]={s=true,r=true}, -- ClericWarDomain
    ["d88b9883-f310-404a-8f33-7fbc551049e3"]={s=false,r=true}, -- DruidCircleOfTheElements
    ["d3734a53-6c64-4280-b499-f8ab4dfbce46"]={s=false,r=true}, -- DruidCircleOfTheLand
    ["f6a8994c-0351-4d3c-bba1-dee3c188f6c8"]={s=true,r=true}, -- DruidCircleOfTheMoon
    ["9c6edc2f-24ab-42a6-acdf-0879efc5f41f"]={s=false,r=true}, -- DruidCircleOfTheShadows
    ["15f43f0e-f065-4307-b50c-247005a293da"]={s=false,r=true}, -- DruidCircleOfTheSpores
    ["e139d9a4-1bd9-4dd4-8db8-7cedf707ee13"]={s=false,r=true}, -- DruidCircleOfTheStars
    ["51b7587d-966a-4f3b-b7c4-4e9fe8cf86f0"]={s=true,r=true}, -- DruidTotemist
    ["07845122-15ec-4c3a-8724-ef9c8fb72f48"]={s=false,r=true}, -- DruidCircleoftheVenom
    ["c759cc6b-f4d7-4d69-a52e-5a65b9ffc612"]={s=true,r=true}, -- FighterArcaneArcher
    ["415dc709-9944-4f49-ac97-d63081a338ac"]={s=false,r=true}, -- FighterChampion
    ["0bd9516c-195e-4012-bced-cb7528cbbc63"]={s=false,r=true}, -- FighterDraconicSentinel
    ["9715353b-13b3-4cbc-ae1d-db99b7f6cc67"]={s=true,r=true}, -- FighterEldritchKnight
    ["e39d5a46-c03a-4ee4-89f8-e522c86085a8"]={s=true,r=true}, -- FighterFrontierKnight
    ["30498f77-3440-42dc-a61a-cb05ac49b248"]={s=false,r=true}, -- FighterPalisade
    ["c9cffeb1-2cb0-44a2-a090-9db2026d549c"]={s=true,r=true}, -- MonkWayOfTheArcane
    ["c4b9ac83-eccc-4118-b851-302ceea16584"]={s=false,r=true}, -- MonkWayOfTheDrunkenFist
    ["1124cc40-5703-4516-8a5a-9ba3bdc52d45"]={s=false,r=true}, -- MonkWayOfTheGentleFist
    ["b62b79dc-a53b-481e-95af-6e3d3b8e0908"]={s=false,r=true}, -- MonkWayOfTheOpenHand
    ["924ca4a7-755d-42c3-9c5f-02fd64ea46c0"]={s=false,r=true}, -- MonkWayOfTheShadowArts
    ["8f0ee646-0114-4f46-8ff3-d2b5bcaf1ca7"]={s=false,r=true}, -- MonkWayOfTheTemperedSteel
    ["4c9def45-b180-4bf3-81e8-ec924d9a629a"]={s=false,r=true}, -- PaladinOathOfTheAncients
    ["b143df54-0b4f-48bf-9ddc-308168bc86f8"]={s=false,r=true}, -- PaladinOathOfTheCrown
    ["e38341cb-f364-468b-9862-67dcadba72db"]={s=false,r=true}, -- PaladinOathOfDevotion
    ["750c4922-f381-4f37-bf26-1d0a91a7a797"]={s=false,r=true}, -- PaladinOathOfVengeance
    ["3998987c-004f-4913-b7a7-62610e3cb45e"]={s=true,r=true}, -- PaladinOathbreaker
    ["6b4bdec0-9753-46c1-967d-0c7e7b5ef039"]={s=false,r=true}, -- PaladinMystflame
    ["47ab16a3-7f3e-4fa3-9ad2-0e884c2f8384"]={s=false,r=true}, -- PaladinTyrant
    ["d8db4bce-a761-4c74-aaf6-ce62ffd7576a"]={s=false,r=true}, -- RangerBeastmaster
    ["07e4218c-fe07-473a-914a-6e53c4e911a0"]={s=false,r=true}, -- RangerGloomstalker
    ["0d28f4d0-30e2-4948-8b9c-137778929a4a"]={s=false,r=true}, -- RangerHunter
    ["287ca7d6-c056-4366-b340-2e9acb1000a7"]={s=false,r=true}, -- RangerMireMist
    ["2fbf3785-a116-41bc-b696-a50432ec46e2"]={s=true,r=true}, -- RangerSwarmkeeper
    ["bfe6f78a-6dde-40e5-9982-2ed2a471f518"]={s=false,r=true}, -- RangerTwinfang
    ["32700827-6d27-40a2-b0a1-b176875af5a7"]={s=true,r=true}, -- RogueArcaneTrickster
    ["f1d35a6c-9c64-4431-862b-972e1004b628"]={s=false,r=true}, -- RogueAssassin
    ["34539fe0-ef9f-4ae1-a218-95f431ef67da"]={s=false,r=true}, -- RogueGauntlet
    ["a434fbc2-676c-4123-8d9a-24dd2e5d6898"]={s=false,r=true}, -- RogueHiddenToxicant
    ["719ecbac-b1db-4dcc-a845-0fd44d17152c"]={s=false,r=true}, -- RogueSwashbuckler
    ["3ae7b1ea-be32-4cd2-8a36-545e4a40a3b9"]={s=false,r=true}, -- RogueThief
    ["42a995f6-fc5e-4577-b21b-eb7fa6c773ec"]={s=false,r=true}, -- RogueVirulence
    ["ba1c505b-a3a8-483a-a061-a8b120c45c00"]={s=true,r=true}, -- SorcererDraconicBloodline
    ["335d2999-28e5-4bfa-a107-534f5824748f"]={s=false,r=true}, -- SorcererHematicMonarch
    ["35e6f8f0-01d4-4273-ad6b-994b287fabd1"]={s=false,r=true}, -- SorcererRadiantBloom
    ["4df54b62-d011-4a95-8f97-e52f823b553d"]={s=false,r=true}, -- SorcererShadeWalker
    ["9c24e1ca-bfe6-4252-a1d7-31e288e23f38"]={s=false,r=true}, -- SorcererSouloftheFrenziedTundra
    ["10a9438c-a01e-4822-a6d9-537a6ce8bb17"]={s=false,r=true}, -- SorcererVolcanist
    ["219431d8-c164-454a-b274-0fbf01a7ad2d"]={s=false,r=true}, -- SorcererWildMagic
    ["4f136e0d-6548-44e3-ad1c-fcbe28ce58b4"]={s=false,r=true}, -- WarlockPactOfTheBlade
    ["71c0b76e-3c66-45f8-80ac-98ba0f272fdb"]={s=false,r=true}, -- WarlockPactOfTheChain
    ["0d17dbdd-57d6-4779-9d76-ebbdb2459b95"]={s=false,r=true}, -- WarlockPactOfThePenumbra
    ["656cdba8-d560-42f2-8776-a7c575115fbd"]={s=false,r=true}, -- WarlockPactOfThePrimordialDemon
    ["866befae-74b3-45a0-9da4-bdec17a3a63d"]={s=false,r=true}, -- WarlockPactOfSeverance
    ["525212a2-e568-483d-994f-4c7eeee7fe94"]={s=false,r=true}, -- WarlockPactOfTheTome
    ["84240516-b152-4008-a28a-39e1a6fd4693"]={s=false,r=true}, -- WizardArcblade
    ["00ffa9e2-c8be-44b5-bc72-25293a715430"]={s=false,r=true}, -- WizardArcaneWarden
    ["ae7218f2-90bb-4f90-8acb-a9946fe85a24"]={s=false,r=true}, -- WizardElementalist
    ["2f5710ec-6ad4-4060-97a4-99b701455dac"]={s=false,r=true}, -- WizardEvoker
    ["95dce8e9-bdd9-4951-8a05-8c5480f60352"]={s=false,r=true}, -- WizardLuminalConfluence
    ["f86e70f9-7936-442c-b335-e1e77bb65d8a"]={s=false,r=true}, -- WizardNecromancy
}

-- EXPERIMENT ONLY: lift feat-specific restrictions while retaining
-- original choice/catalog checks and unrelated ability/spell guards.
local HB_UNRESTRICTED_FEAT_TEST=true

local function PreflightOtherChange(level,source,to)
        to=tostring(to or "")
        if to==tostring(source.From or "") then return nil end -- undo
        local kind=tostring(source.Kind or "")
        if kind=="Feat" and HB_UNRESTRICTED_FEAT_TEST then return nil end
        if kind=="Spell" or kind=="Cantrip" or kind=="Skill" or kind=="Expertise" then
            for otherLevel=1,maxLevel do
                -- Spell ids must not be shared with choices recorded at
                -- different historical levels. Skill/Expertise duplicates
                -- are only prohibited inside the same list and same level.
                if otherLevel==level or kind=="Spell" or kind=="Cantrip" then
                    for _,other in ipairs(OtherAtLevel(levelSummaries,otherLevel)) do
                        local sameList=(tostring(other.List or "")==tostring(source.List or ""))
                        local sameKind=(tostring(other.Kind or "")==kind)
                        local sameSlot=(otherLevel==level and OtherKey(other)==OtherKey(source))
                        if not sameSlot and sameKind and
                            ((kind=="Spell" or kind=="Cantrip") or sameList) then
                            local edit=stagedOther[otherLevel] and stagedOther[otherLevel][OtherKey(other)]
                            local effective=tostring(edit and edit.To or other.From or "")
                            -- Native L1 is authoritative for the duplicate
                            -- check, irrespective of what later-level legal
                            -- replacement the user manually chooses.
                            if otherLevel==1 and level>=2 and kind=="Spell"
                                and not edit then
                                local slider=_G.HB_NATIVE_L1_SLIDER
                                local swap=slider and slider.LiveSpellSwap
                                if swap and tostring(other.From or "")==tostring(swap.From or "") then
                                    effective=tostring(swap.To)
                                    NavigationLog("NATIVE_L1_SPELL_LIVE_PREFLIGHT level="..level
                                        .." oldL1="..tostring(swap.From)
                                        .." nativeL1="..effective.." candidate="..to)
                                end
                            elseif otherLevel>=2 and kind=="Spell" and not edit then
                                local slider=_G.HB_NATIVE_L1_SLIDER
                                local cleared=slider and slider.DisplacedSpellSlots or {}
                                if cleared[otherLevel] and cleared[otherLevel][OtherKey(other)] then
                                    effective="" -- genuinely empty, not still selected
                                end
                            end
                            if effective==to then
                                return kind.." is already recorded at character level "..tostring(otherLevel)
                            end
                        end
                    end
                end
            end
        end
        if kind=="Spell" or kind=="Cantrip" then
            if not Ext.Stats or not Ext.Stats.Get then
                return "Spell rank cannot be verified without installed spell metadata."
            end
            local function Rank(id)
                local ok,stat=pcall(Ext.Stats.Get,tostring(id or ""))
                if not ok or not stat then return nil end
                local okLevel,value=pcall(function() return stat.Level or stat.SpellLevel end)
                local rank=okLevel and tonumber(value) or nil
                if rank and rank>=0 and rank<=9 and rank==math.floor(rank) then return rank end
                return nil
            end
            local oldRank,newRank=Rank(source.From),Rank(to)
            if oldRank==nil or newRank==nil or oldRank~=newRank then
                return "Replacement spell rank is unavailable or differs from the historical choice."
            end
            if (kind=="Cantrip" and newRank~=0) or (kind=="Spell" and newRank==0) then
                return "Replacement spell does not match the recorded spell/cantrip category."
            end
        elseif kind=="Ability" then
            -- HB feat ability picks are selectable passive choices; do not
            -- reintroduce vanilla ability increment/decrement assumptions.
            -- Only compare slots belonging to the same recorded upgrade row.
            for _,other in ipairs(OtherAtLevel(levelSummaries,level)) do
                if other~=source and other.Kind=="Ability" and other.Source==source.Source
                    and other.EntryIndex==source.EntryIndex and other.SlotIndex~=source.SlotIndex then
                    local staged=stagedOther[level] and stagedOther[level][OtherKey(other)]
                    local picked=tostring(staged and staged.To or other.From or "")
                    if picked==to then
                        return "That ability is already chosen in this ability-selection group."
                    end
                end
            end
        elseif kind=="Feat" then
            if not Ext.StaticData or not Ext.StaticData.Get then
                return "Feat metadata cannot be verified for historical editing."
            end
            local ok,feat=pcall(Ext.StaticData.Get,to,"Feat")
            if not ok or not feat then return "Replacement feat metadata is unavailable." end
            local oldOK,originalFeat=pcall(Ext.StaticData.Get,tostring(source.From or ""),"Feat")
            if not oldOK or not originalFeat then
                return "Original feat metadata is unavailable for verifying retained effects."
            end
            local function HasExpressions(record,name,id)
                local source=HB_SOURCE_FEAT_CONTRACTS[tostring(id or ""):lower()]
                local sourceProtected=source and (name=="Selectors" and source.s
                    or name=="Requirements" and source.r)
                local read,value=pcall(function() return record[name] end)
                if not read or value==nil or value==false then
                    if source then return sourceProtected==true end
                    return true -- unknown source and no readable metadata
                end
                if type(value)=="string" then
                    return sourceProtected==true or value:match("%S")~=nil
                end
                if type(value)=="table" then
                    return sourceProtected==true or next(value)~=nil
                end
                return sourceProtected==true or tostring(value)~=""
            end
            local removeElementalAdept=tostring(source.From or "")==
                "fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
            local removeAccord=tostring(source.From or "")==
                "cdcbc538-883b-401c-a8ed-1373fb6d1720"
            local removePair=HB_PASSIVE_PAIR_ALLOWED[tostring(source.From or "")]~=nil
            local removeGeneric=HB_GENERIC_FEATS.PassiveSelectors(tostring(source.From or ""))~=nil
                and HB_PASSIVE_PAIR_ALLOWED[tostring(source.From or "")]==nil
            local addGeneric=HB_GENERIC_FEATS.PassiveSelectors(to)~=nil
                and HB_PASSIVE_PAIR_ALLOWED[to]==nil
            local removeMultifaceted=tostring(source.From or "")
                =="be0889d2-f9aa-472d-b942-592bff0f1ef3"
            if not removeElementalAdept and not removePair and not removeMultifaceted
                and not removeAccord and not removeGeneric
                and HasExpressions(originalFeat,"Selectors",source.From) then
                return "Original feat has secondary allocations which cannot be removed with a simple feat replacement."
            end
            local addAccord=to=="cdcbc538-883b-401c-a8ed-1373fb6d1720"
                and tostring(source.From or "")~=to
            local addElementalAdept=to=="fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
                and tostring(source.From or "")~=to
            local addMultifaceted=to=="be0889d2-f9aa-472d-b942-592bff0f1ef3"
                and tostring(source.From or "")~=to
            local addPair=HB_PASSIVE_PAIR_ALLOWED[to]~=nil
            if not addElementalAdept and not addPair and not addMultifaceted
                and not addAccord and not addGeneric
                and HasExpressions(feat,"Selectors",to) then
                return "This feat requires secondary choices, which cannot yet be replayed safely."
            end
            if HasExpressions(feat,"Requirements",to)
                and HB_GENERIC_FEATS.RequiredClass(to)==nil then
                return "This feat's prerequisites cannot yet be checked against the historical level."
            end
            local repeatable=false
            local repeatedOK,canRepeat=pcall(function() return feat.CanBeTakenMultipleTimes end)
            if repeatedOK and canRepeat==true then repeatable=true end
            if not repeatable then
                for otherLevel=1,level-1 do
                    local choices=levelSummaries[otherLevel] and levelSummaries[otherLevel].LevelChoices or {}
                    local found=false
                    for _,other in ipairs(OtherAtLevel(levelSummaries,otherLevel)) do
                        if other.Kind=="Feat" then
                            found=true
                            local edited=stagedOther[otherLevel] and stagedOther[otherLevel][OtherKey(other)]
                            local effective=tostring(edited and edited.To or other.From or "")
                            if effective==to then
                                return "That nonrepeatable feat was already selected at character level "..otherLevel
                            end
                        end
                    end
                    if not found and choices.Source and tostring(choices.Source.FeatId or "")==to then
                        return "That nonrepeatable feat was already selected at character level "..otherLevel
                    end
                end
            end
        end
        return nil
    end

    StageOtherAt = function(level, reference, to)
        if mode~="editor" then return false,"Edit Build is not active." end
        level=tonumber(level)
        to=tostring(to or "")
        if not level or level<1 or level>maxLevel then
            return false,"Invalid historical choice level."
        end
        if level==1 and (type(reference)~="table"
            or reference.LevelOneVerified~=true
            or not ({Spell=true,Cantrip=true,Skill=true,Expertise=true})[reference.Kind]) then
            return false,"Only verified starting spells, skills and expertise can be edited."
        end
        local key=type(reference)=="table" and OtherKey(reference) or nil
        if not key then return false,"Missing recorded choice." end
        local source=nil
        for _, candidate in ipairs(OtherAtLevel(levelSummaries,level)) do
            if OtherKey(candidate)==key and candidate.From==reference.From
                and candidate.List==reference.List then
                source=candidate;break
            end
        end
        if not source or not source.Editable then
            return false,"This selection has no verified replacement options."
        end
        local valid=false
        for _,option in ipairs(source.Options or {}) do
            if tostring(option.Id)==to then valid=true;break end
        end
        if not valid then return false,"That replacement is not in the recorded selection list." end
        local blocked=PreflightOtherChange(level,source,to)
        if blocked then return false,blocked end
        -- Switching away from an original verified complex feat also
        -- invalidates its own staged passive replacements. Remove those
        -- edits from the AUTHORITATIVE pending transaction; otherwise the
        -- now-hidden secondary tab can leave orphan edits at Confirm.
        if source.Kind=="Feat" and to~=tostring(source.From) then
            for _,group in ipairs(GroupsAtLevel(levelSummaries,level)) do
                if group.FeatOwnerVerified and
                    tostring(group.FeatOwnerId or "")==tostring(source.From) then
                    for _,picked in ipairs(group.Picked or {}) do
                        local key=PassiveEditKey(group,tostring(picked))
                        if stagedPassives[level] then stagedPassives[level][key]=nil end
                    end
                end
            end
        end
        stagedOther[level]=stagedOther[level] or {}
        if source.Kind=="Feat" and to~=tostring(source.From) then
            -- A historical secondary selection belongs to the ORIGINAL
            -- feat and cannot remain staged after that feat is removed.
            for _,owned in ipairs(OtherAtLevel(levelSummaries,level)) do
                if owned.Kind~="Feat" and tostring(owned.FeatOwnerId or "")==
                    tostring(source.From) then
                    stagedOther[level][OtherKey(owned)]=nil
                end
            end
        end
        if to==tostring(source.From) then
            stagedOther[level][key]=nil
        else
            stagedOther[level][key]={Level=level,Kind=source.Kind,Source=source.Source,
                List=source.List,EntryIndex=source.EntryIndex,SlotIndex=source.SlotIndex,
                From=source.From,To=to}
            if source.Kind=="Feat" and
                to=="fdf0be80-cc1e-4501-bd2e-7a1ea737362c" then
                stagedOther[level][key].ElementChoices={}
            end
            if source.Kind=="Feat" and to=="cdcbc538-883b-401c-a8ed-1373fb6d1720" then
                stagedOther[level][key].AccordChoices={}
            end
            if source.Kind=="Feat" and addMultifaceted then
                stagedOther[level][key].MultifacetedChoices={Archetype={},Trait={},Skills={}}
            end
            if source.Kind=="Feat" and HB_PASSIVE_PAIR_ALLOWED[to] then
                stagedOther[level][key].PassiveFeatChoices={}
            end
            if source.Kind=="Feat" and
                (HB_GENERIC_FEATS.PassiveSelectors(to) or HB_GENERIC_FEATS.SpellSelectors(to))
                and not HB_PASSIVE_PAIR_ALLOWED[to]
                and to~="fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
                and to~="be0889d2-f9aa-472d-b942-592bff0f1ef3" then
                stagedOther[level][key].GenericFeatChoices={}
            end
        end
        Refresh()
        return true,to==source.From and "Original selection restored." or
            ("Staged "..tostring(source.Kind).." choice: "..OtherDisplay(source,to))
    end
    vm.PR_OtherStage:SetHandler(function()
        local level,row,cursor=OtherCursor()
        if not level or not row then return end
        local option=row.Options[cursor.Option]
        if option then StageOtherAt(level,row,option.Id) end
    end)
    vm.PR_OtherClear:SetHandler(function()
        local level,row=OtherCursor();if not level then return end
        if stagedOther[level] then stagedOther[level][OtherKey(row)]=nil end
        Refresh()
    end)
    -- A compatible portable preset goes through the same guarded native
    -- historical editor, staging all validated choices atomically. No
    -- prebuilt engine objects or old spellbook/hotbar state is copied.
    PR.BuildValidated=function()
        local active=CurrentVM()
        if not active or not active.PR_BuildOpen or not buildPendingPreset then return end
        if mode~='choose' then return end
        if maxLevel<=1 then
            active.PR_BuildStatus='This character has no higher-level progression to restore. Starting-level choices must be applied through BG3.'
            buildPendingPreset=nil;buildImportFile=nil
            return
        end
        local version=buildPendingPreset.Version
        if version==2 then
            local name=tostring(buildPendingPreset.Name or 'Imported Build')
            buildPendingPreset=nil
            -- Native Confirm is the only mutation point. The client does
            -- not pretend the receiving character already owns the imported
            -- class-level choices; server stages/verifies the entire recipe.
            active.PR_BuildOpen=false
            active.PR_BuildSaveMode=false;active.PR_BuildLoadMode=false
            active.PR_BuildButtonsVisible=false
            if not SetMode('editor') then return end
            active.PR_SelectedLevel=1
            NavigationLog('BUILD_PRESET_SERVER_RECONSTRUCTION name='..name)
            Ext.OnNextTick(function()
                if mode=='editor' and OpenNativeLevelEditor then OpenNativeLevelEditor() end
            end)
            return
        end
        local planned,reason=BuildImporter.Plan(buildPendingPreset,levelSummaries)
        buildPendingPreset=nil
        if not planned then
            active.PR_BuildStatus='Cannot import build: '..tostring(reason)
            return
        end
        local other,passives,resources={},{},{}
        for _,edit in ipairs(planned.Other or {}) do
            other[edit.Level]=other[edit.Level] or {}
            other[edit.Level][OtherKey(edit)]=edit
        end
        for _,edit in ipairs(planned.Passives or {}) do
            passives[edit.Level]=passives[edit.Level] or {}
            passives[edit.Level][PassiveEditKey(edit,edit.From)]=edit
        end
        -- Importing must not merge with stale locally staged edits. These
        -- tables are freshly scoped to BuildVM and populated only here.
        for level,rows in pairs(other) do stagedOther[level]=rows end
        for level,rows in pairs(passives) do stagedPassives[level]=rows end
        for level,row in pairs(resources) do stagedResources[level]=row end
        active.PR_BuildOpen=false
        active.PR_BuildSaveMode=false;active.PR_BuildLoadMode=false
        active.PR_BuildButtonsVisible=false
        active.PR_BuildStatus=''
        if not SetMode('editor') then return end
        active.PR_SelectedLevel=1
        NavigationLog('BUILD_PRESET_STAGED edits='..tostring(planned.Count))
        Ext.OnNextTick(function()
            if mode=='editor' and OpenNativeLevelEditor then OpenNativeLevelEditor() end
        end)
    end
    -- Normal Partial Respec is never routed through the historical replay.
    vm.PR_ConfirmCommand:SetHandler(function()
        if mode ~= "partial" then return end
        local current = CurrentVM(); if not current or current.PR_EditorBusy then return end
        local firstLevel = SelectedLevel(current,maxLevel)
        if firstLevel<=1 then
            -- Native level-one respec must remain PLAYER-DRIVEN. Never execute
            -- FinishCreating automatically or the player cannot change L1.
            partialConfirmSequence=partialConfirmSequence+1
            partialPendingRequestId=tostring(character)..":"..tostring(partialConfirmSequence)
            partialPendingCharacter=character
            partialAckWaitTicks=0
            current.PR_EditorBusy=true
            current.PR_ModeHelp="Saving build before native level-one respec..."
            NavigationLog("NATIVE_FIRST_LEVEL_RESTORE_REQUEST id="..partialPendingRequestId)
            PartialRespecChannel:SendToServer({Character=character,
                NativeFirstLevelRestore=true,RequestId=partialPendingRequestId})
        else
            local lastKept=firstLevel-1
            -- IMPORTANT: the preserved-level replay is triggered by BG3's
            -- RespecCompleted event. Merely hiding this popup leaves the user
            -- on the vanilla level-one screen and never starts the replay.
            -- Wait for the server to capture the untouched character and
            -- acknowledge the chosen cutoff, then invoke the same guarded
            -- native FinishCreating path already used for Selective Respec.
            partialConfirmSequence=partialConfirmSequence+1
            partialPendingRequestId=tostring(character)..":"..tostring(partialConfirmSequence)
            partialPendingCharacter=character
            partialAckWaitTicks=0
            current.PR_EditorBusy=true
            current.PR_ModeHelp="Preparing preserved levels; waiting for character backup..."
            NavigationLog("PARTIAL_COMMIT_SENT id="..partialPendingRequestId
                .." firstLevel="..firstLevel.." lastKept="..lastKept)
            PRPrint(0,"Partial respec: rebuilding from level %d",firstLevel)
            PartialRespecChannel:SendToServer({Character=character,Level=lastKept,
                RequestId=partialPendingRequestId})
        end
    end)
    CommitNativeLevelRespec = function()
        if mode ~= "editor" then return end
        local current=CurrentVM(); if not current or current.PR_EditorBusy then return end
        local resources,passives,others={},StagedPassiveRows(stagedPassives),StagedOtherRows(stagedOther)
        for i=2,maxLevel do
            if stagedResources[i] then resources[#resources+1]=stagedResources[i] end
        end
        -- No edit is a valid Selective Respec: the original build is replayed unchanged.
        current.PR_EditorBusy = true
        current.PR_EditorHasEdits = false
        current.PR_EditorStatus = "Validating level choices and restoring the build."
        -- Historical replay always rebuilds through the original max level.
        PartialRespecChannel:SendToServer({Character=character,Level=maxLevel,
            ExperimentalExtraResourceEdits=resources,
            ExperimentalClassPassiveEdits=passives,
            ExperimentalOtherChoiceEdits=others,LevelRespecConfirm=true})
        return true
    end
    vm.PR_EditorApplyCommand:SetHandler(function() CommitNativeLevelRespec() end)
    -- Unlike Full Respec, Cancel must dismiss BG3's native respec itself.
    -- Simply hiding this overlay or sending Cancelled=true to the server
    -- would leave the player on an active (and possibly dirty) respec screen.
    -- Use the mounted game-owned VM's cancellation command, if exposed.
    vm.PR_CancelRespecCommand:SetHandler(function()
        local current=CurrentVM()
        if not current or not current.PR_PopupVisible or mode~="choose"
            or current.PR_BuildOpen or current.PR_EditorBusy
            or partialPendingRequestId or autoConfirmInProgress then
            NavigationLog("RESPEC_CANCEL_REJECT state=not-choosing-or-busy")
            return
        end
        local native
        for _,name in ipairs(VANILLA_RESPEC_WIDGET_NAMES) do
            native=FindWidget(name)
            if native then break end
        end
        if not native then
            NavigationLog("RESPEC_CANCEL_REJECT state=native-screen-not-mounted")
            current.PR_ModeHelp="BG3's respec screen is unavailable. Use the game's Cancel/Back control to exit."
            return
        end
        local ok,gameVM=pcall(function() return native.DataContext end)
        if not ok or not gameVM then
            NavigationLog("RESPEC_CANCEL_REJECT state=native-viewmodel-unavailable")
            current.PR_ModeHelp="BG3's Cancel control is unavailable here. Use the game's Cancel/Back control to exit."
            return
        end
        -- The native game-owned CharacterRespec screen really exposes these
        -- exit commands. They are already named and intercepted by our own
        -- NativeHistoricalPreview.lua, unlike the speculative candidates in
        -- the first red-button test. Do not invoke generic CancelTaskCommand,
        -- dismiss a widget directly, or fabricate a RespecCancelled event.
        local vmTyped,kind=pcall(function() return gameVM.Type end)
        if not vmTyped or tostring(kind)~="gui::DCCharacterCreation" then
            NavigationLog("RESPEC_CANCEL_REJECT state=non-native-respec-vm kind="..tostring(kind))
            current.PR_ModeHelp="BG3's original Respec screen is unavailable. Use the game's Cancel/Back control."
            return
        end
        local names={"ExitCharacterRespec","ExitCharacterCreation"}
        for _,name in ipairs(names) do
            local found,cmd=pcall(function() return gameVM[name] end)
            if found and cmd then
                local ready,allowed=pcall(function() return cmd:CanExecute(nil) end)
                if ready and allowed==true then
                    local done,err=pcall(function() cmd:Execute(nil) end)
                    if done then
                        NavigationLog("RESPEC_CANCEL_NATIVE_COMMAND name="..name
                            .." phase=dispatched-await-RespecCancelled")
                        -- Native BG3 handles the discard prompt and fires
                        -- RespecCancelled on a confirmed exit. Do not hide
                        -- our overlay or notify the server prematurely.
                        return
                    end
                    NavigationLog("RESPEC_CANCEL_COMMAND_ERROR name="..name
                        .." reason="..tostring(err))
                else
                    NavigationLog("RESPEC_CANCEL_COMMAND_UNAVAILABLE name="..name
                        .." ready="..tostring(ready).." allowed="..tostring(allowed))
                end
            else
                NavigationLog("RESPEC_CANCEL_COMMAND_MISSING name="..name
                    .." readable="..tostring(found))
            end
        end
        NavigationLog("RESPEC_CANCEL_REJECT state=no-executable-native-exit-command")
        current.PR_ModeHelp="BG3's native Respec exit command was unavailable. Use Escape or the game's Cancel/Back control."
    end)
    vm.PR_FullRespecCommand:SetHandler(function()
        NavigationLog("CLICK Full Respec (original handler)")
        local current=CurrentVM(); if current then current.PR_PopupVisible=false end
        ClearPartialPending()
        PRPrint(1,"Partial respec selected full respec")
        PartialRespecChannel:SendToServer({Character=character,Cancelled=true})
    end)
    return vm
end

--- Exposes the vanilla CurrentPlayer on the popup VM so XAML can reach the
--- face button input events. The popup uses a custom DataContext, so
--- CurrentPlayer is unreachable from XAML otherwise.
---@param vm ViewModel
local function BindCurrentPlayer(vm)
    for _, name in ipairs(VANILLA_RESPEC_WIDGET_NAMES) do
        local widget = FindWidget(name)
        if widget then
            local ok, player = pcall(function()
                local dc = widget.DataContext
                return dc and dc.CurrentPlayer
            end)
            if ok and player then
                vm.PR_CurrentPlayer = player
                return
            end
        end
    end
end

---@param character string
---@param characterLevel integer
---@param levelSummaries table<integer, table>
---@return boolean
function PR.Show(character, characterLevel, levelSummaries)
    local widget
    for _, name in ipairs(CHOICE_WIDGET_NAMES) do
        widget = FindWidget(name)
        if widget then break end
    end
    if not widget then return false end

    -- Spell-heavy builds can contain engine-owned C++ proxies that disappear
    -- during the UI transition. Keep this attempt recoverable, and log the
    -- exact point of failure rather than losing the whole callback.
    local built,createdOrError=pcall(BuildVM,character,
        math.max(1,characterLevel),levelSummaries)
    if not built then
        NavigationLog("RESPEC_POPUP_BUILD_ERROR actor="..tostring(character)
            .." reason="..tostring(createdOrError))
        return false
    end
    local assigned,assignError=pcall(function() widget.DataContext=createdOrError end)
    if not assigned then
        NavigationLog("RESPEC_POPUP_BIND_ERROR widget="..tostring(widget.Name)
            .." reason="..tostring(assignError))
        return false
    end
    NavigationLog("Popup DataContext assigned; widget=" .. tostring(widget.Name))

    if widget.Name == "PR_RespecChoice_c" then
        BindCurrentPlayer(widget.DataContext)
    end

    PRPrint(1, "Partial respec popup shown for %s (level %d)", character, characterLevel)
    return true
end

function PR.Hide()
    PR.BuildValidated=nil
    PR.RefreshBuildSelection=nil
    -- BG3 may already have dismissed CharacterRespec when its cancel event
    -- reaches us. One native-bridge exception must never prevent dismissal
    -- of our overlay or leave its retry subscriptions running.
    if _G.HB_NativeLevelBridge and _G.HB_NativeLevelBridge.Hide then
        local ok,err=pcall(_G.HB_NativeLevelBridge.Hide)
        if not ok then NavigationLog("RESPEC_BRIDGE_HIDE_ERROR "..tostring(err)) end
    end
    CancelPopupRetry()
    local vm = CurrentVM()
    HideToast()
    if vm then
        vm.PR_PopupVisible = false
    end
end

---@param classes table|nil
---@param levelCount integer|nil
---@return boolean
function PR.ShowToast(classes, levelCount)
    local vm = CurrentToastVM()
    if not vm then return false end

    CancelToastTimer()
    vm.PR_ToastTitle = "Partial Respec Complete"
    vm.PR_ToastMarkup = BuildToastMarkup(classes, levelCount)
    vm.PR_ToastVisible = true

    local levels = math.max(1, tonumber(levelCount) or 1)
    local duration = TOAST_BASE_DURATION_MS + (levels - 1) * TOAST_EXTRA_LEVEL_DURATION_MS
    local generation = toastGeneration
    toastTimerId = Ext.Timer.WaitFor(duration, function()
        if generation ~= toastGeneration then return end

        local current = CurrentToastVM()
        if current then current.PR_ToastVisible = false end
        toastTimerId = nil
    end)

    PRPrint(0, "Partial respec completion toast shown")
    return true
end

-- Native-level-one results arrive AFTER BG3 has closed the respec screen.
-- Report success and mismatch on the regular HUD toast rather than an
-- invisible respec popup. Avoid unbounded polling or per-frame UI scans.
local function NativeRestoreFailureExplanation(status)
    local raw=tostring(status and status.Text or "")
    local lower=raw:lower()
    if lower:find("post-restore historical selections differ",1,true) then
        local level=raw:match("[Ll]evel%s+(%d+)")
        return "Saved choices at level "..tostring(level or "?")
            .." did not match after restoration."
    elseif lower:find("spell ownership",1,true)
        or lower:find("non-progression spell",1,true)
        or lower:find("spellbook",1,true)
        or lower:find("overlapping spell",1,true) then
        -- Show the concrete spell/action ID when the server provided one,
        -- without leaking script traces or raw internal error messages.
        local spell=raw:match("(CProjectile_[%w_]+)")
            or raw:match("(Target_[%w_]+)")
            or raw:match("(Projectile_[%w_]+)")
            or raw:match("(Shout_[%w_]+)")
            or raw:match("(Zone_[%w_]+)")
        return "Could not verify the original progression owner of "
            ..(spell or "a spell or action").."."
    elseif lower:find("feat",1,true) or lower:find("selector",1,true)
        or lower:find("secondary",1,true) then
        return "A feat or its additional choices could not be restored safely."
    elseif lower:find("class",1,true) or lower:find("subclass",1,true) then
        return "The original class progression could not be verified."
    elseif lower:find("audit",1,true) or lower:find("verification",1,true)
        or lower:find("level does not match",1,true) then
        return "The restored character did not pass progression verification."
    end
    return "The original higher-level build could not be restored safely."
end

local function ShowNativeFirstLevelStatus(status,attempts)
    local label=tostring(status and status.Text or "Native level-one restoration completed")
    local toast=CurrentToastVM()
    if not toast then
        if attempts>0 then
            Ext.OnNextTick(function() ShowNativeFirstLevelStatus(status,attempts-1) end)
        else
            NavigationLog("NATIVE_L1_STATUS_NO_TOAST "..label)
            PRWarn(0,"Native level-one restore: %s",label)
        end
        return
    end
    CancelToastTimer()
    local successful=status and status.Success==true
    -- The native respec may have reached the intended level while the
    -- independent post-replay audit still has an unverified spell or action.
    -- This is a display-only distinction: do not change the result flag,
    -- restoration flow, or the server's fail-closed ownership checks.
    local needsVerification=not successful
        and label:find("Higher-level restoration needs verification:",1,true)==1
    toast.PR_ToastTitle=successful and "Selective Respec Complete"
        or (needsVerification and "Selective Respec Warning" or "Selective Respec Failed")
    if successful then
        toast.PR_ToastMarkup="Changes applied."
    elseif needsVerification then
        toast.PR_ToastMarkup="Ensure your build is correct before saving."
    else
        local why=NativeRestoreFailureExplanation(status)
        -- A failed replay is not transactional. Only explicitly verified
        -- level-one retention can be called Full Respec; never claim rollback.
        local recovery=(status and status.FullRespecFallback==true)
            and " Character remains at level one for Full Respec. Level up normally or reload your original save."
            or " Reload your original save before continuing."
        toast.PR_ToastMarkup=why..recovery
    end
    toast.PR_ToastVisible=true
    local generation=toastGeneration
    toastTimerId=Ext.Timer.WaitFor(successful and 10000 or 16000,function()
        if toastGeneration~=generation then return end
        local widget=CurrentToastVM()
        if widget then widget.PR_ToastVisible=false end
        toastTimerId=nil
    end)
    -- Keep the specific server reason in diagnostics, not the tiny HUD toast.
    NavigationLog("NATIVE_L1_STATUS "..label)
end

-- Never strand the player in an auto-confirm failure with no visible controls.
-- Clearing the server's pending partial snapshot also prevents accidentally
-- preserving old levels if the player later completes a different respec.
local function AutoConfirmFailed(reason)
    NavigationLog("RESPEC_AUTOCONFIRM_STOP mode="..tostring(autoConfirmMode)
        .." reason="..tostring(reason))
    if autoConfirmMode=="Partial" or autoConfirmMode=="BuildPreset" then
        if autoConfirmCharacter then
            PartialRespecChannel:SendToServer({Character=autoConfirmCharacter,
                Cancelled=true})
        end
        local vm=CurrentVM()
        if vm then
            vm.PR_PopupVisible=true
            vm.PR_EditorBusy=false
            if autoConfirmMode=="BuildPreset" then
                vm.PR_BuildOpen=true
                vm.PR_BuildLoadMode=true
                vm.PR_BuildSaveMode=false
                vm.PR_BuildBusy=false
                if type(PR.RefreshBuildSelection)=='function' then
                    PR.RefreshBuildSelection(vm)
                else
                    vm.PR_BuildCanLoad=false;vm.PR_BuildCanDelete=false
                end
                vm.PR_BuildStatus='BG3 could not confirm the build automatically: '
                    ..tostring(reason)..'. If native respec completed, reload your original save.'
            else
                vm.PR_ModeHelp="The game could not complete the initial respec automatically. "
                    .."No preserved levels were applied. Use Back or Full Respec. ("..tostring(reason)..")"
            end
        end
    end
    autoConfirmInProgress=false
    autoConfirmMode=nil
    autoConfirmCharacter=nil
end

--- Retries executing the vanilla FinishCreating command until the respec screen mounts.
---@param attemptsLeft integer
local function AutoConfirmVanillaRespec(attemptsLeft)
    if not autoConfirmInProgress then return end
    local widget
    for _, name in ipairs(VANILLA_RESPEC_WIDGET_NAMES) do
        widget = FindWidget(name)
        if widget then break end
    end

    if not widget then
        if attemptsLeft==MAX_AUTO_CONFIRM_ATTEMPTS then
            NavigationLog("RESPEC_AUTOCONFIRM_WAIT_NATIVE mode="..tostring(autoConfirmMode))
        end
        if attemptsLeft <= 0 then
            autoConfirmInProgress = false
            PRWarn(0, "Automatic respec confirmation failed: vanilla widget did not mount")
            AutoConfirmFailed("vanilla widget did not mount")
            return
        end
        Ext.OnNextTick(function()
            AutoConfirmVanillaRespec(attemptsLeft - 1)
        end)
        return
    end

    local vmOk, vm = pcall(function() return widget.DataContext end)
    local commandOk, finishRespecCommand = pcall(function()
        return vmOk and vm and vm.FinishCreating
    end)
    if not vmOk or not commandOk or not finishRespecCommand then
        if attemptsLeft==MAX_AUTO_CONFIRM_ATTEMPTS then
            NavigationLog("RESPEC_AUTOCONFIRM_WAIT_COMMAND mode="..tostring(autoConfirmMode)
                .." context="..tostring(vmOk and vm and vm.Type or "unavailable"))
        end
        if attemptsLeft <= 0 then
            autoConfirmInProgress = false
            PRWarn(0, "Automatic respec confirmation failed: FinishCreating is unavailable")
            AutoConfirmFailed("FinishCreating is unavailable")
            return
        end
        Ext.OnNextTick(function()
            AutoConfirmVanillaRespec(attemptsLeft - 1)
        end)
        return
    end

    local canExecuteOk, canExecuteRespecConfirm = pcall(function()
        return finishRespecCommand:CanExecute(nil)
    end)
    if not canExecuteOk or canExecuteRespecConfirm ~= true then
        if attemptsLeft==MAX_AUTO_CONFIRM_ATTEMPTS then
            NavigationLog("RESPEC_AUTOCONFIRM_WAIT_EXECUTABLE mode="..tostring(autoConfirmMode)
                .." ok="..tostring(canExecuteOk).." executable="..tostring(canExecuteRespecConfirm))
        end
        if attemptsLeft <= 0 then
            autoConfirmInProgress = false
            PRWarn(0, "Automatic respec confirmation failed: FinishCreating is not executable")
            AutoConfirmFailed("FinishCreating is not executable")
            return
        end
        Ext.OnNextTick(function()
            AutoConfirmVanillaRespec(attemptsLeft - 1)
        end)
        return
    end

    local executeOk, executeError = pcall(function()
        finishRespecCommand:Execute(nil)
    end)
    if not executeOk then
        if attemptsLeft <= 0 then
            autoConfirmInProgress = false
            PRWarn(0, "Automatic respec confirmation failed: %s", tostring(executeError))
            AutoConfirmFailed(tostring(executeError))
            return
        end
        Ext.OnNextTick(function()
            AutoConfirmVanillaRespec(attemptsLeft - 1)
        end)
        return
    end

    PRPrint(0, "Automatic vanilla respec confirmation requested")
    NavigationLog("RESPEC_NATIVE_CONFIRM_EXECUTED mode="..tostring(autoConfirmMode))
    autoConfirmInProgress = false
    autoConfirmMode=nil
    autoConfirmCharacter=nil
end

local function StartAutoConfirm(mode,character)
    if autoConfirmInProgress then return end
    autoConfirmMode=mode
    autoConfirmCharacter=character
    autoConfirmInProgress = true
    AutoConfirmVanillaRespec(MAX_AUTO_CONFIRM_ATTEMPTS)
end

---@param classes table|nil
---@param levelCount integer|nil
---@param attemptsLeft integer
local function ShowToastWhenMounted(classes, levelCount, attemptsLeft)
    if PR.ShowToast(classes, levelCount) then return end
    if attemptsLeft <= 0 then
        PRWarn(0, "Partial respec toast widget did not mount")
        return
    end

    Ext.OnNextTick(function()
        ShowToastWhenMounted(classes, levelCount, attemptsLeft - 1)
    end)
end

--- ImpUI declares CharacterRespec with Override, wiping our Extend widget when it loads after us.
local function WarnOnceOnBadLoadOrder()
    if loadOrderWarned then return end
    local partialIndex, impUIIndex
    for index, uuid in ipairs(Ext.Mod.GetLoadOrder()) do
        if tostring(uuid) == ModuleUUID then partialIndex = index end
        if tostring(uuid) == IMPROVED_UI_UUID then impUIIndex = index end
        if partialIndex and impUIIndex then break end
    end
    if impUIIndex and partialIndex and impUIIndex > partialIndex then
        loadOrderWarned = true
        PRWarn(0, "ImprovedUI (ImpUI) loads before Partial Respec and overrides the respec screen; place Partial Respec below ImpUI in the load order")
    end
end

---@param character string
---@param characterLevel integer
---@param levelSummaries table<integer, table>
---@param generation integer
local function ShowWhenMounted(character, characterLevel, levelSummaries, generation)
    CancelPopupRetry()
    if generation ~= popupShowGeneration then return end
    local shown,successOrError=pcall(PR.Show,character,characterLevel,levelSummaries)
    if shown and successOrError then return end
    NavigationLog("RESPEC_POPUP_FIRST_ATTEMPT actor="..tostring(character)
        .." mounted="..tostring(FindWidget("PR_RespecChoice")~=nil)
        .." native="..tostring(FindWidget("CharacterRespec")~=nil)
        .." success="..tostring(shown).." detail="..tostring(successOrError))
    WarnOnceOnBadLoadOrder()
    local ticksPassed = 0
    local failedAttempts=0
    popupRetryEventId = Ext.Events.Tick:Subscribe(function()
        if generation ~= popupShowGeneration then
            CancelPopupRetry()
            return
        end

        ticksPassed = ticksPassed + 1
        if ticksPassed < POPUP_BIND_RETRY_TICKS then return end

        ticksPassed = 0
        failedAttempts=failedAttempts+1
        local done,successOrError=pcall(PR.Show,character,characterLevel,levelSummaries)
        if done and successOrError then
            NavigationLog("RESPEC_POPUP_RETRY_OK attempt="..failedAttempts)
            CancelPopupRetry()
        elseif failedAttempts==1 or failedAttempts%30==0 then
            NavigationLog("RESPEC_POPUP_RETRY_FAILED attempt="..failedAttempts
                .." widget="..tostring(FindWidget("PR_RespecChoice")~=nil)
                .." native="..tostring(FindWidget("CharacterRespec")~=nil)
                .." result="..tostring(successOrError))
        end
        if failedAttempts>=MAX_POPUP_BIND_RETRIES then
            NavigationLog("RESPEC_POPUP_RETRY_EXHAUSTED actor="..tostring(character)
                .." attempts="..failedAttempts
                .." custom="..tostring(FindWidget("PR_RespecChoice")~=nil)
                .." native="..tostring(FindWidget("CharacterRespec")~=nil)
                .." reason=no mounted respec screen; refusing unbounded retries")
            CancelPopupRetry()
        end
    end)
end

-- Check infrequently: traversing a Noesis tree on every frame would be
-- expensive. Strictly require an attached native respec ViewModel.
local recoveryPollCounter=0
-- CharacterRespec is rarely open during gameplay. The recursive widget
-- fallback is expensive on large Noesis UI trees, so normally use the
-- shallow mounted-page check. Keep an infrequent deep fallback for UI
-- layouts where ImprovedUI mounts CharacterRespec below another container.
local MenuScope=Ext.Require("Client/MenuScope.lua")
local recoveryDeepPageMounted=false
Ext.Events.Tick:Subscribe(function()
    if not PartialRespecEnabled then return end
    if partialPendingRequestId then
        partialAckWaitTicks=partialAckWaitTicks+1
        if partialAckWaitTicks>=PARTIAL_ACK_TIMEOUT_TICKS then
            local expiredId=partialPendingRequestId
            local actor=partialPendingCharacter
            ClearPartialPending()
            NavigationLog("PARTIAL_COMMIT_TIMEOUT id="..tostring(expiredId))
            local vm=CurrentVM()
            if vm then
                vm.PR_EditorBusy=false
                vm.PR_BuildBusy=false
                vm.PR_BuildStatus='Build load timed out before confirmation. No automatic respec was started.'
                vm.PR_ModeHelp="The server did not acknowledge the backup. No automatic respec was started. You can retry or go Back."
            end
            if actor then
                PartialRespecChannel:SendToServer({Character=actor,Cancelled=true,
                    RequestId=expiredId})
            end
        end
    end
    recoveryPollCounter=recoveryPollCounter+1
    if recoveryPollCounter % 30 ~= 0 then return end
    local shallowMounted=MenuScope.IsOpen("Respec")
    if not shallowMounted and not recoveryDeepPageMounted
        and recoveryPollCounter % 180 ~= 0 then
        -- No respec UI present: skip the twice-per-second deep traversal.
        return
    end
    local ok,native=pcall(function()
        return FindWidget("CharacterRespec") or FindWidget("CharacterRespec_c")
    end)
    local mounted=false
    if ok and native then
        local valid,context=pcall(function() return native.DataContext end)
        if valid and context then
            local typed,kind=pcall(function() return context.Type end)
            mounted=typed and (kind=="gui::DCCharacterCreation" or
                tostring(kind):find("HB_HistoricalNativeCommandPilot",1,true)~=nil)
        end
    end
    recoveryDeepPageMounted=mounted
    if not mounted then
        if respecRecoveryTicks > 0 then
            NavigationLog("RESPEC_RECOVERY_RESET: native screen unmounted")
        end
        respecRecoveryTicks=0
        respecRecoveryRequested=false
        respecPopupReceivedThisScreen=false
        return
    end
    if respecPopupReceivedThisScreen or respecRecoveryRequested then return end
    -- Do not spawn the popup over an active historical editing session;
    -- allow the fallback only after the native wrapper is gone/closed.
    local activeKind=nil
    if ok and native then
        local readable,ctx=pcall(function() return native.DataContext end)
        if readable and ctx then
            local typed,kind=pcall(function() return ctx.Type end)
            if typed then activeKind=tostring(kind) end
        end
    end
    if activeKind and activeKind:find("HB_HistoricalNativeCommandPilot",1,true) then
        respecRecoveryTicks=0
        return
    end
    respecRecoveryTicks=respecRecoveryTicks+30
    if respecRecoveryTicks<RESPEC_RECOVERY_DELAY_TICKS then return end
    respecRecoveryRequested=true
    NavigationLog("RESPEC_RECOVERY_REQUEST: native screen mounted without a popup after "
        ..tostring(respecRecoveryTicks).." ticks")
    PartialRespecChannel:SendToServer({RecoverRespecMenu=true})
end)

PartialRespecChannel:SetHandler(function(message)
    if type(message) ~= "table" then
        PRWarn(0, "Partial respec UI rejected an invalid message")
        return
    end

    if message.BuildPresetResult==true then
        local active=CurrentVM()
        if active then
            active.PR_BuildBusy=false
            active.PR_BuildCanSave=true
            active.PR_BuildStatus=tostring(message.BuildPresetStatus or
                (message.BuildPresetOk and 'Build operation complete.' or 'Build operation failed.'))
            active.PR_BuildSaveLabel='Save'
        end
        if message.BuildPresetOperation=='Save' and message.BuildPresetOk and active then
            active.PR_BuildOpen=false
            active.PR_BuildSaveMode=false
            active.PR_BuildLoadMode=false
            active.PR_ModeSelectVisible=true
            active.PR_BuildButtonsVisible=true
            active.PR_BuildStatus=''
            active.PR_BuildCanDelete=false
        end
        if message.BuildPresetOperation=='CheckLoad' and message.BuildPresetOk
            and type(PR.BuildValidated)=='function' then
            local ok,err=pcall(PR.BuildValidated)
            if not ok then
                NavigationLog('BUILD_PRESET_IMPORT_FAILED '..tostring(err))
                if active then active.PR_BuildStatus='Build import failed: '..tostring(err) end
            end
        end
        return
    end
    if message.NativeFirstLevelSliderPrepared==true then
        if not nativeSliderPendingId or message.RequestId~=nativeSliderPendingId then
            NavigationLog("NATIVE_SLIDER_L1_STALE_ACK "..tostring(message.RequestId));return
        end
        nativeSliderPendingId=nil
        local bridge=_G.HB_NativeLevelBridge
        if bridge and bridge.NativeFirstLevelReady then bridge.NativeFirstLevelReady() end
        return
    end
    if message.NativeFirstLevelSliderError then
        if not nativeSliderPendingId or message.RequestId~=nativeSliderPendingId then
            NavigationLog("NATIVE_SLIDER_L1_STALE_ERROR "..tostring(message.RequestId));return
        end
        nativeSliderPendingId=nil
        local bridge=_G.HB_NativeLevelBridge
        if bridge and bridge.NativeFirstLevelRejected then
            bridge.NativeFirstLevelRejected(message.NativeFirstLevelSliderError)
        end
        return
    end
    if type(message.NativeFirstLevelStatus)=="table" then
        ShowNativeFirstLevelStatus(message.NativeFirstLevelStatus,MAX_TOAST_BIND_ATTEMPTS)
        return
    end

    if message.Visible == false then
        ClearPartialPending()
        respecPopupReceivedThisScreen=true
        popupShowGeneration = popupShowGeneration + 1
        PR.Hide()
        return
    end

    if not PartialRespecEnabled then return end

    if message.Toast == true then
        ShowToastWhenMounted(
            message.ToastClasses or {},
            message.ToastLevelCount,
            MAX_TOAST_BIND_ATTEMPTS
        )
        return
    end

    if message.ExperimentalError then
        if message.RequestId and message.RequestId~=partialPendingRequestId then
            NavigationLog("RESPEC_STALE_ERROR_IGNORED id="..tostring(message.RequestId))
            return
        end
        if partialPendingRequestId then ClearPartialPending() end
        local vm = CurrentVM()
        if vm then
            vm.PR_EditorBusy = false
            vm.PR_EditorHasEdits = true
            vm.PR_EditorStatus = "Respec could not be applied: " .. tostring(message.ExperimentalError)
            vm.PR_ModeHelp=vm.PR_EditorStatus
            -- On a rejected direct build import the user is still on the
            -- chooser's Load panel; no native Confirm has been executed.
            if vm.PR_BuildOpen and vm.PR_BuildLoadMode then
                vm.PR_BuildBusy=false
                if type(PR.RefreshBuildSelection)=='function' then
                    PR.RefreshBuildSelection(vm)
                else
                    vm.PR_BuildCanLoad=false;vm.PR_BuildCanDelete=false
                end
                vm.PR_BuildStatus='Cannot load build: '..tostring(message.ExperimentalError)
            end
        end
        local bridge=_G.HB_NativeLevelBridge
        if bridge and bridge.CommitFailed then
            local handled,errorMessage=pcall(bridge.CommitFailed,tostring(message.ExperimentalError))
            if not handled then NavigationLog("RESPEC_REJECT_BRIDGE_ERROR "..tostring(errorMessage)) end
        end
        -- A rejected native Confirm is non-destructive, but BG3 can retain
        -- the CharacterRespec widget without raising another StartRespec
        -- event after the user exits. Re-arm the existing owned-actor menu
        -- recovery watchdog, instead of leaving the hotbar with no menu.
        respecRecoveryTicks=0
        respecRecoveryRequested=false
        respecPopupReceivedThisScreen=false
        NavigationLog("RESPEC_REJECT_RECOVERY_REARMED")
        return
    end

    if message.Confirmed == true then
        local ackMode=tostring(message.AckMode or "unknown")
        if ackMode=="Partial" or ackMode=="NativeFirstLevel" or ackMode=="BuildPreset" then
            if not partialPendingRequestId or message.RequestId~=partialPendingRequestId then
                NavigationLog("PARTIAL_STALE_ACK_IGNORED id="..tostring(message.RequestId))
                return
            end
            ClearPartialPending()
        elseif partialPendingRequestId then
            NavigationLog("RESPEC_WRONG_ACK_MODE_IGNORED mode="..ackMode)
            return
        end
        NavigationLog("RESPEC_SERVER_ACCEPTED mode="..ackMode)
        popupShowGeneration = popupShowGeneration + 1
        -- A bridge.Hide exception previously aborted this handler AFTER
        -- acceptance but BEFORE FinishCreating, leaving the popup busy.
        -- Native historical cleanup is unrelated to Partial Respec: never
        -- let it abort the server-accepted vanilla confirm handoff.
        local okHide,hideError=pcall(function()
            if ackMode=="Partial" or ackMode=="NativeFirstLevel" then
                CancelPopupRetry()
                HideToast()
                local ui=CurrentVM()
                if ui then ui.PR_PopupVisible=false end
            else
                PR.Hide()
            end
        end)
        NavigationLog("RESPEC_POPUP_HIDE mode="..ackMode.." ok="..tostring(okHide)
            ..(okHide and "" or (" error="..tostring(hideError))))
        if ackMode=="NativeFirstLevel" then
            NavigationLog("NATIVE_FIRST_LEVEL_MANUAL_CONFIRM ready=true")
            -- Unlike Partial/Selective Respec, no programmatic native Confirm.
            -- The player must make their new first-level choices in BG3.
            return
        end
        local okStart,startError=pcall(StartAutoConfirm,ackMode,message.Character)
        NavigationLog("RESPEC_AUTOCONFIRM_START mode="..ackMode
            .." ok="..tostring(okStart)..(okStart and "" or (" error="..tostring(startError))))
        if not okStart then AutoConfirmFailed(startError) end
        return
    end

    respecPopupReceivedThisScreen=true
    NavigationLog("RESPEC_POPUP_RECEIVED character="..tostring(message.Character)
        .." maxLevel="..tostring(message.MaxLevel))
    popupShowGeneration = popupShowGeneration + 1
    ShowWhenMounted(
        message.Character,
        message.MaxLevel or 1,
        message.LevelSummaries or {},
        popupShowGeneration
    )
end)

if MCMLoaded then
    Ext.ModEvents.BG3MCM.MCM_Setting_Saved:Subscribe(function(payload)
        if payload
            and payload.modUUID == ModuleUUID
            and payload.settingId == "enabled"
            and payload.value == false then
            autoConfirmInProgress = false
            popupShowGeneration = popupShowGeneration + 1
            PR.Hide()
        end
    end)
end
