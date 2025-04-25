
-- Required libraries
local game_api = require("lib")
local spells = require("spells")
local talents = require("talents")
local auras = require("auras")
local settings = require("settings")
local interrupts = require("interrupts")
local state = require("state")

-- Debug state loading
print("state type:", type(state))
print("state value:", tostring(state))
if type(state) == "table" then
    print("state.debugMode:", tostring(state.debugMode))
end

-- Interrupt setup
local interruptSpellID = interrupts.spellID
local INTERRUPT_RANGE = interrupts.range
local KICK_PERCENT = interrupts.kickAtPercent
local interruptWhitelist = interrupts.whitelist
local BASE_GCD_MS = 1500 -- Base GCD in milliseconds before haste
local MIN_GCD_SECONDS = 0.75 -- Minimum possible GCD duration
local DEFAULT_GCD_SECONDS = 1.5 -- Fallback GCD duration if calculation fails

-- Define Fury Costs
local FURY_COSTS = {
    soulCleave = 30,
    reaversGlaive = 0,
    fracture = 0,
    felblade = 0,
    felDevastation = 50,
    spiritBomb = 40,
    sigilOfFlame = 0,
    sigilOfSpite = 0,
    immolationAura = 0,
    demonSpikes = 0,
    theHunt = 0,
    fieryBrand = 0,
}

-- Constants
local RECENT_CAST_WINDOW = 1.2 -- Seconds: Window for checking recent generator casts
local LOW_FURY_THRESH = 40    -- Fury threshold below which we might prioritize generation over SC
local DELTA_TIME_APPROX = 1/60 -- Approximate time per frame/update

-- Helper function to serialize a table for printing
function SerializeTable(tbl, indent)
    indent = indent or 0
    local tblType = type(tbl)
    if tblType ~= "table" then return tostring(tbl) end
    local str = "{\n"
    local padding = string.rep("  ", indent + 1)
    local count = 0
    for k, v in pairs(tbl) do
        count = count + 1
        str = str .. padding .. "[" .. tostring(k) .. "] = "
        local vType = type(v)
        if vType == "table" then
            str = str .. SerializeTable(v, indent + 1)
        elseif vType == "string" then
            str = str .. "\"" .. tostring(v) .. "\""
        else
            str = str .. tostring(v)
        end
        str = str .. ",\n"
    end
    if count == 0 then return "{}" end
    str = str .. string.rep("  ", indent) .. "}"
    return str
end

-- Corrected CastSpell function
function CastSpell(spellId, target, range, conditions, logMessage, useCharges, maxCharges, castType)
    -- <<< STEP 1: Check Custom Conditions FIRST >>>
    local condition_result = true -- Default to true if no conditions function provided
    if conditions then
        condition_result = conditions()
        state.logDebug("minimal", "DEBUG CastSpell Received Cond Result: " .. tostring(condition_result), "castspell_cond_result")
    end
    if not condition_result then
        state.logDebug("minimal", "Skipping " .. logMessage .. ": Condition Function Returned False", "cast_skip_cond")
        return false
    end
    -- <<< END STEP 1 >>>

    -- <<< STEP 2: Check Range (with fix) >>>
    if range then
        local targetForRangeCheck = target -- Default to the passed target
        if castType == "aoe_self" then
            targetForRangeCheck = state.currentTarget
        end
        if targetForRangeCheck and targetForRangeCheck ~= "00" then
            if not IsInRange(range, targetForRangeCheck) then
                state.logDebug("minimal", "Skipping " .. logMessage .. ": Target Out of Range (" .. range .. "y)", "cast_skip_range")
                return false
            end
        end
    end
    -- <<< END STEP 2 >>>

    -- <<< STEP 3: Check API CanCast / CanCastCharge >>>
    local canCast
    if useCharges and maxCharges then
        canCast = game_api.canCastCharge(spellId, maxCharges)
    else
        canCast = game_api.canCast(spellId)
    end
    if not canCast then
        local cooldown = game_api.getCooldownRemainingTime(spellId)
        state.logDebug("minimal", "Skipping " .. logMessage .. ": Cannot Cast (API Check / CD: " .. string.format("%.1f", (cooldown or 0)/1000) .. "s)", "cast_skip_cd")
        return false
    end
    -- <<< END STEP 3 >>>

    -- <<< STEP 4: Attempt Cast >>>
    state.logDebug("minimal", "Cast " .. logMessage, "cast_attempt")
    if castType == "aoe_self" then
        game_api.castAOESpellOnSelf(spellId)
    elseif target and target ~= "00" then
        game_api.castSpellOnTarget(spellId, target)
    else
        game_api.castSpell(spellId)
    end
    -- <<< END STEP 4 >>>

    -- <<< STEP 5: Update State >>>
    state.lastSpellCast = spellId
    state.lastSpellCastTime = state.time
    if spellId == spells.sigilOfFlame then state.lastSigilOfFlameCastTime = state.time end
    if spellId == spells.fieryBrand then state.lastFieryBrandCastTime = state.time end
    if spellId == spells.demonSpikes then state.lastDemonSpikesCastTime = state.time end
    -- <<< END STEP 5 >>>

    return true
end

-- Block 4: demon_spikes
function ProcessDemonSpikes()
    state.logDebug("minimal", "Checking Demon Spikes...", "ds_check")
    local result = CastSpell(
        spells.demonSpikes,
        nil,
        nil,
        function()
            return not state.demonSpikes and game_api.canCastCharge(spells.demonSpikes, 2)
        end,
        "Demon Spikes",
        true,
        2
    )
    if not result then
        if state.demonSpikes then
            state.logDebug("minimal", "Skipping Demon Spikes: Already Active", "ds_skip_active")
        elseif not game_api.canCastCharge(spells.demonSpikes, 2) then
            state.logDebug("minimal", "Skipping Demon Spikes: Cannot Cast Charge (API Check)", "ds_skip_cant_cast")
        else
            state.logDebug("verbose", "Skipping Demon Spikes: Condition Logic Check", "ds_skip_logic")
        end
        state.logDebug("verbose", "Demon Spikes Status: Active=" .. tostring(state.demonSpikes) .. ", Charges=" .. state.demonSpikesCharges .. ", CD=" .. string.format("%.1f", state.demonSpikesCD), "ds_status")
    end
    return false
end

-- Block 5: interrupt (disrupt)
function ProcessInterrupt()
    state.logDebug("minimal", "Checking Interrupts...", "int_check_entry")
    if not state.interruptTargetGuid then
        state.logDebug("minimal", "Skipping Interrupts: No interrupt target found in state.", "int_action_no_target")
        return false
    end
    state.logDebug("minimal", "Interrupt Action: Found target in state: GUID=" .. state.interruptTargetGuid .. ", SpellID=" .. tostring(state.interruptTargetSpellID), "int_action_target_found")
    local canInterruptNow = game_api.canCast(interruptSpellID)
    state.logDebug("minimal", "Interrupt Action: Checking canCast(" .. interruptSpellID .. ") = " .. tostring(canInterruptNow), "int_action_cancast_check")
    if not canInterruptNow then
        state.logDebug("minimal", "Interrupt Action: Skipping, canCast became false.", "int_action_skip_cancast")
        state.interruptTargetGuid = nil
        state.interruptTargetSpellID = nil
        return false
    end
    local castPercent = game_api.unitCastPercentage(state.interruptTargetGuid) or 0
    state.logDebug("minimal", "Interrupt Action: Target cast percent = " .. string.format("%.2f", castPercent) .. ", Required >= " .. string.format("%.2f", KICK_PERCENT), "int_action_pct_check")
    if castPercent < KICK_PERCENT then
        state.logDebug("minimal", "Interrupt Action: Skipping, Cast percent too low.", "int_action_skip_timing")
        return false
    end
    local result = CastSpell(
        interruptSpellID,
        state.interruptTargetGuid,
        INTERRUPT_RANGE,
        function()
            return true
        end,
        "Interrupt"
    )
    if result then
        state.logDebug("minimal", ">>> ATTEMPTING INTERRUPT <<< SpellID=" .. interruptSpellID .. ", TargetGUID=" .. state.interruptTargetGuid, "int_action_CASTING")
        state.interruptTargetGuid = nil
        state.interruptTargetSpellID = nil
    else
        state.logDebug("minimal", "Interrupt Action: Skipping, Out of Range.", "int_action_skip_range")
    end
    return result
end

-- Block 7: the_hunt
function ProcessTheHunt()
    state.logDebug("minimal", "Checking The Hunt...", "check_hunt_entry")
    local hunt_apl_condition = not state.reaversGlaiveProc and (state.artOfTheGlaiveStacks + state.soulFragments) < 20
    if not hunt_apl_condition then
        state.logDebug("minimal", "Skipping The Hunt: Condition Failed (!RGProc=" .. tostring(not state.reaversGlaiveProc) .. ", Stacks+Souls=" .. (state.artOfTheGlaiveStacks + state.soulFragments) .. ")", "check_hunt_skip_cond")
        state.resetLogKey("want_the_hunt_cd"); state.resetLogKey("want_the_hunt_range"); state.resetLogKey("check_hunt_met")
        return false
    end
    state.logDebug("minimal", "Check The Hunt: Condition Met. Checking Range/Cast...", "check_hunt_met")
    local result = CastSpell(
        spells.theHunt,
        state.currentTarget,
        5,
        function()
            return game_api.canCast(spells.theHunt)
        end,
        "The Hunt"
    )
    if not result then
        if not game_api.canCast(spells.theHunt) then
            state.logDebug("minimal", "Skipping The Hunt: Cannot Cast (CD: " .. string.format("%.1f", state.theHuntCD) .. ")", "want_the_hunt_cd")
        else
            state.logDebug("minimal", "Skipping The Hunt: Target Out of Range (5y).", "want_the_hunt_range")
            state.resetLogKey("want_the_hunt_cd")
        end
    end
    return result
end

-- Block 8: spirit_bomb (specific condition 1)
function ProcessSpiritBombSpecific1()
    state.logDebug("minimal", "Checking Spirit Bomb (Specific 1)...", "check_spb_specific_1_entry")
    local sb_cond1_base = state.can_spb
    local sb_cond1_inactive_approx = state.recent_inactive_souls > 2
    local sb_cond1_prev_spite = state.prevGCD1 == spells.sigilOfSpite
    local sb_cond1_prev_carver = state.prevGCD1 == spells.soulCarver
    local sb_cond1_fallout_immo = (state.enemies >= 4 and state.hasTalentFallout and state.immolationAuraCD < state.gcdDurationSeconds)
    local sb_cond1_extra_conds = sb_cond1_inactive_approx or sb_cond1_prev_spite or sb_cond1_prev_carver or sb_cond1_fallout_immo
    local spirit_bomb_condition_1 = sb_cond1_base and sb_cond1_extra_conds
    if not spirit_bomb_condition_1 then
        state.logDebug("minimal", "Skipping SPB (Specific 1): Condition Failed [Base(can_spb)=" .. tostring(sb_cond1_base) .. ", ExtraMet=" .. tostring(sb_cond1_extra_conds) .. "]", "check_spb_specific_1_skip_cond")
        state.resetLogKey("want_spb_specific_1_cd"); state.resetLogKey("skip_spb_spec1_fury"); state.resetLogKey("check_spb_specific_1_met")
        return false
    end
    state.logDebug("minimal", "Check Spirit Bomb (Specific 1): Condition Met. Checking Fury/Cast...", "check_spb_specific_1_met")
    local result = CastSpell(
        spells.spiritBomb,
        state.currentTarget,
        8,
        function()
            return state.currentPower >= FURY_COSTS.spiritBomb and game_api.canCast(spells.spiritBomb)
        end,
        "Spirit Bomb (Specific Condition 1)"
    )
    if not result then
        if state.currentPower < FURY_COSTS.spiritBomb then
            state.logDebug("minimal", "Skipping SPB (Specific 1): Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.spiritBomb .. ").", "skip_spb_spec1_fury")
            state.resetLogKey("want_spb_specific_1_cd")
        else
            state.logDebug("minimal", "Skipping SPB (Specific 1): Cannot Cast (CD: " .. string.format("%.1f", state.spiritBombCD) .. ")", "want_spb_specific_1_cd")
        end
    end
    return result
end

function ProcessImmolationAura()
    state.logDebug("minimal", "Checking Immolation Aura...", "check_immolation_entry")
    local result = CastSpell(
        spells.immolationAura, nil, nil,
        function()
            local approx_sequence_time_immo = state.gcdDurationSeconds * 4.5
            local immo_cond_part1 = (state.enemies >= 4)
            local immo_cond_part2_sub = state.double_rm_remains > (approx_sequence_time_immo + state.gcdDurationSeconds)
            local immo_cond_part2 = not state.reaversGlaiveProc or immo_cond_part2_sub
            local immolation_aura_condition = immo_cond_part1 or immo_cond_part2

            state.logDebug("minimal", "DEBUG Immo Conds: Enemies=" .. state.enemies .. ">=" .. "4=" .. tostring(immo_cond_part1) ..
                     ", RGProc=" .. tostring(state.reaversGlaiveProc) ..
                     ", RMRem=" .. string.format("%.1f", state.double_rm_remains) .. ">" .. string.format("%.1f", (approx_sequence_time_immo + state.gcdDurationSeconds)) .. "=" .. tostring(immo_cond_part2_sub) ..
                     ", Cond2=" .. tostring(immo_cond_part2) ..
                     ", FINAL=" .. tostring(immolation_aura_condition), "immo_debug_details")

            if not immolation_aura_condition then
                state.logDebug("minimal", "Skipping Immolation Aura: Condition Failed...", "check_immolation_skip_cond")
                state.resetLogKey("check_immolation_met"); state.resetLogKey("want_immolation")
                return false
            end
            state.logDebug("minimal", "Check Immolation Aura: Condition Met. Calling CastSpell...", "check_immolation_met")
            return true
        end,
        "Immolation Aura", false, nil, "self"
    )
    return result
end

-- Block 10: sigil_of_flame
function ProcessSigilOfFlame()
    state.logDebug("minimal", "Checking Sigil of Flame...", "check_sof_entry")

    local t = {}
    t.RGProc = state.reaversGlaiveProc
    t.DotRem = state.sigilOfFlameDotRemains
    t.RMRem = state.double_rm_remains
    t.PrevGCD = state.prevGCD1
    t.TimeSinceSoF = state.time - (state.lastSigilOfFlameCastTime or -99)
    t.AscFlameTalent = state.hasTalentAscendingFlame
    t.GCD = state.gcdDurationSeconds
    t.QuickSigils = state.hasTalentQuickenedSigils
    t.Toggle = game_api.getToggle(settings.RG)

    local logMsg = "DEBUG Pre-SoF GRANULAR:"
    for k, v in pairs(t) do
        logMsg = logMsg .. " " .. k .. "=" .. tostring(v) .. " (" .. type(v) .. "),"
    end
    state.logDebug("minimal", logMsg, "sof_granular_state")

    local result = CastSpell(
        spells.sigilOfFlame,
        nil, 10,
        function()
            local timeSinceLastSoFCast = state.time - (state.lastSigilOfFlameCastTime or -99)
            local manual_timer_ok = timeSinceLastSoFCast > 1.5
            local sof_cond_talent = state.hasTalentAscendingFlame
            local quickenedBonus = state.hasTalentQuickenedSigils and 1 or 0
            local sigilRefreshThreshold = 4.0 - quickenedBonus
            local currentDotRem = state.sigilOfFlameDotRemains or 999
            local dot_needs_refresh = currentDotRem < sigilRefreshThreshold
            local sof_cond_part1 = sof_cond_talent or (state.prevGCD1 ~= spells.sigilOfFlame and manual_timer_ok and dot_needs_refresh)
            local currentGcd = state.gcdDurationSeconds or DEFAULT_GCD_SECONDS
            local approx_sequence_time_sof = currentGcd * 4.5
            local currentRmRem = state.double_rm_remains or 0
            local delay_cond_rm_ok = currentRmRem > (approx_sequence_time_sof + currentGcd)
            local currentRgProc = state.reaversGlaiveProc or false
            local sof_cond_part2 = not currentRgProc or delay_cond_rm_ok
            local cast_sigil_of_flame_condition = sof_cond_part1 and sof_cond_part2
            local toggleActive = game_api.getToggle(settings.RG) or false
            local final_condition_met = toggleActive and cast_sigil_of_flame_condition

            state.logDebug("minimal", "DEBUG SoF Cond Result: Toggle=" .. tostring(toggleActive) ..
                     ", CalcCond=" .. tostring(cast_sigil_of_flame_condition) .. " (Part1="..tostring(sof_cond_part1)..", Part2="..tostring(sof_cond_part2)..")" ..
                     ", manual_timer_ok="..tostring(manual_timer_ok)..
                     ", FinalMet=" .. tostring(final_condition_met) ..
                     ", WillReturn=" .. tostring(final_condition_met), "sof_cond_return_val")

            if not final_condition_met then
                return false
            end
            return true
        end,
        "Sigil of Flame", true, 2, "aoe_self"
    )
    return result
end

-- Block 12: soul_cleave (specific condition)
function ProcessSoulCleaveSpecific()
    state.logDebug("minimal", "Checking Soul Cleave (Specific)...", "check_sc_specific_entry")
    local approx_sequence_time_sc_spec = state.gcdDurationSeconds * 4.5
    local sc_cond_part1 = not state.reaversGlaiveProc
    local sc_cond_part2 = state.double_rm_remains <= (state.gcdDurationSeconds + approx_sequence_time_sc_spec)
    local sc_cond_part3 = state.soulFragments < 3
    local sc_cond_part4 = (state.artOfTheGlaiveStacks + state.soulFragments) >= 20
    local soul_cleave_specific_cond = sc_cond_part1 and sc_cond_part2 and sc_cond_part3 and sc_cond_part4
    if not soul_cleave_specific_cond then
        state.logDebug("minimal", "Skipping Soul Cleave (Specific): Condition Failed (!RGProc=" .. tostring(sc_cond_part1) .. ", RMRem=" .. string.format("%.1f", state.double_rm_remains) .. ", Souls=" .. state.soulFragments .. ")", "check_sc_specific_skip_cond")
        state.resetLogKey("want_sc_specific_cant_fury"); state.resetLogKey("want_sc_specific_cant_cd"); state.resetLogKey("check_sc_specific_met")
        return false
    end
    state.logDebug("minimal", "Check Soul Cleave (Specific): Condition Met. Checking Fury/Cast...", "check_sc_specific_met")
    local result = CastSpell(
        spells.soulCleave,
        state.currentTarget,
        8,
        function()
            return state.currentPower >= FURY_COSTS.soulCleave and game_api.canCast(spells.soulCleave)
        end,
        "Soul Cleave (Specific Condition): Reason=RM Expiring/Soul Counts, Fury=" .. state.currentPower .. ", Souls=" .. state.soulFragments
    )
    if not result then
        if state.currentPower < FURY_COSTS.soulCleave then
            state.logDebug("minimal", "Skipping Soul Cleave (Specific): Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.soulCleave .. ")", "want_sc_specific_cant_fury")
        else
            state.logDebug("minimal", "Skipping Soul Cleave (Specific): Cannot Cast (CD: " .. string.format("%.1f", state.soulCleaveCD) .. ")", "want_sc_specific_cant_cd")
        end
    end
    return result
end

-- Block 13: spirit_bomb (specific condition 2)
function ProcessSpiritBombSpecific2()
    state.logDebug("minimal", "Checking Spirit Bomb (Specific 2)...", "check_spb_specific_2_entry")
    local approx_sequence_time_spb_spec = state.gcdDurationSeconds * 4.5
    local spb_cond2_part1 = not state.reaversGlaiveProc
    local spb_cond2_part2 = state.double_rm_remains <= (state.gcdDurationSeconds + approx_sequence_time_spb_spec)
    local spb_cond2_part3 = (state.artOfTheGlaiveStacks + state.soulFragments) >= 20
    local spirit_bomb_specific_cond_2 = spb_cond2_part1 and spb_cond2_part2 and spb_cond2_part3
    if not spirit_bomb_specific_cond_2 then
        state.logDebug("minimal", "Skipping SPB (Specific 2): Condition Failed (!RGProc=" .. tostring(spb_cond2_part1) .. ", RMRem=" .. string.format("%.1f", state.double_rm_remains) .. ", Stacks+Souls=" .. (state.artOfTheGlaiveStacks + state.soulFragments) .. ")", "check_spb_specific_2_skip_cond")
        state.resetLogKey("check_spb_specific_2_met"); state.resetLogKey("skip_spb_spec2_api"); state.resetLogKey("skip_spb_spec2_fury"); state.resetLogKey("skip_spb_spec2_souls")
        return false
    end
    state.logDebug("minimal", "Check Spirit Bomb (Specific 2): Condition Met. Checking Souls/Fury/Cast...", "check_spb_specific_2_met")
    if not state.can_spb then
        state.logDebug("minimal", "Skipping SPB (Specific 2): can_spb false (ActiveSouls=" .. state.soulFragments .. ").", "skip_spb_spec2_souls")
        state.resetLogKey("skip_spb_spec2_api"); state.resetLogKey("skip_spb_spec2_fury")
        return false
    end
    local result = CastSpell(
        spells.spiritBomb,
        state.currentTarget,
        8,
        function()
            return state.currentPower >= FURY_COSTS.spiritBomb and game_api.canCast(spells.spiritBomb)
        end,
        "Spirit Bomb (Specific Condition 2)"
    )
    if not result then
        if state.currentPower < FURY_COSTS.spiritBomb then
            state.logDebug("minimal", "Skipping SPB (Specific 2): Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.spiritBomb .. ").", "skip_spb_spec2_fury")
            state.resetLogKey("skip_spb_spec2_api"); state.resetLogKey("skip_spb_spec2_souls")
        else
            state.logDebug("minimal", "Skipping SPB (Specific 2): API CanCast false (CD=" .. string.format("%.1f", state.spiritBombCD) .. ").", "skip_spb_spec2_api")
            state.resetLogKey("skip_spb_spec2_fury"); state.resetLogKey("skip_spb_spec2_souls")
        end
    end
    return result
end

-- Block 14: reavers_glaive
function ProcessReaversGlaive()
    state.logDebug("minimal", "Checking Reaver's Glaive (Main)...", "check_rg_cast_entry")
    local approx_sequence_time_rg_main = state.gcdDurationSeconds * 3.5
    local rg_cond1_fury_check = false
    local keenBonus_rg = state.hasTalentKeenEngagement and 20 or 0
    local enhanceBonus_rg = state.rg_enhance_cleave and 25 or 0
    local effectiveFury_rg = state.currentPower + enhanceBonus_rg + keenBonus_rg
    if effectiveFury_rg >= FURY_COSTS.reaversGlaive then rg_cond1_fury_check = true end
    local rg_cond2_part1_thrill = not state.thrillOfFightAttackSpeedActive
    local rg_cond2_part1_rm = state.double_rm_remains <= approx_sequence_time_rg_main
    local rg_cond2_timing_or_aoe = (rg_cond2_part1_thrill or rg_cond2_part1_rm) or (state.enemies >= 4)
    local rg_cond3_not_active = not (state.rendingStrike or state.glaiveFlurry)
    local reavers_glaive_cond = state.reaversGlaiveProc and rg_cond1_fury_check and rg_cond2_timing_or_aoe and rg_cond3_not_active
    if not (game_api.getToggle(settings.RG) and reavers_glaive_cond) then
        state.logDebug("minimal", "Skipping Reaver's Glaive (Main): Condition Failed or Toggle OFF (Cond=" .. tostring(reavers_glaive_cond) .. ", Toggle=" .. tostring(game_api.getToggle(settings.RG)) .. ")", "check_rg_cast_skip_cond")
        state.resetLogKey("want_rg_main_cant_api"); state.resetLogKey("check_rg_cast_met")
        return false
    end
    state.logDebug("minimal", "Check Reaver's Glaive (Main): Condition Met. Checking Cast...", "check_rg_cast_met")
    local result = CastSpell(
        spells.reaversGlaive,
        state.currentTarget,
        8,
        function()
            return game_api.canCast(spells.reaversGlaive)
        end,
        "Reaver's Glaive (Main)"
    )
    if not result then
        state.logDebug("minimal", "Skipping Reaver's Glaive (Main): Cannot Cast (API).", "want_rg_main_cant_api")
    end
    return result
end

-- Block 16: fiery_brand
function ProcessFieryBrand()
    state.logDebug("minimal", "Checking Fiery Brand...", "check_fiery_brand_entry")
    if not (game_api.getToggle(settings.Brand) and game_api.getToggle(settings.RG)) then
        if not game_api.getToggle(settings.Brand) then
            state.logDebug("minimal", "Skipping Fiery Brand Checks: Brand Toggle OFF", "fb_brand_toggle_off")
        elseif not game_api.getToggle(settings.RG) then
            state.logDebug("minimal", "Skipping Fiery Brand Checks: RG Toggle OFF", "fb_rg_toggle_off")
        end
        state.resetLogKey("want_fiery_brand_cant"); state.resetLogKey("check_fiery_brand_met"); state.resetLogKey("check_fiery_brand_skip_cond")
        return false
    end
    local fb_cond1 = not state.hasTalentFieryDemise and not state.fieryBrandDotTicking
    local fb_cond2 = state.hasTalentDownInFlames and (state.fieryBrandCharges == 1 and state.fieryBrandCD < state.gcdDurationSeconds)
    local fb_cond3_setup = state.reaversGlaiveProc or state.theHuntCD < 5 or state.artOfTheGlaiveStacks >= 15 or state.thrillOfFightDamageRemains > 5
    local fb_cond3 = state.hasTalentFieryDemise and not state.fieryBrandDotTicking and fb_cond3_setup
    local main_fb_conditions_met = fb_cond1 or fb_cond2 or fb_cond3
    local time_since_last_fb = state.time - (state.lastFieryBrandCastTime or -99)
    local manual_timer_ok_fb = time_since_last_fb > 1.5
    local cast_fiery_brand_condition = main_fb_conditions_met and manual_timer_ok_fb
    if not cast_fiery_brand_condition then
        state.logDebug("minimal", "Skipping Fiery Brand: Condition Failed (Cond=" .. tostring(cast_fiery_brand_condition) .. ", ManualTimerOK=" .. tostring(manual_timer_ok_fb) .. ", Ticking=" .. tostring(state.fieryBrandDotTicking) .. ")", "check_fiery_brand_skip_cond")
        state.resetLogKey("want_fiery_brand_cant"); state.resetLogKey("check_fiery_brand_met")
        return false
    end
    state.logDebug("minimal", "Check Fiery Brand: Condition Met. Checking Usable...", "check_fiery_brand_met")
    local result = CastSpell(
        spells.fieryBrand,
        state.currentTarget,
        30,
        function()
            return state.hasTalentDownInFlames and game_api.canCastCharge(spells.fieryBrand, 2) or game_api.canCast(spells.fieryBrand)
        end,
        "Fiery Brand",
        state.hasTalentDownInFlames,
        2
    )
    if result then
        state.lastFieryBrandCastTime = state.time
    else
        state.logDebug("minimal", "Skipping Fiery Brand: Cannot Cast (Charges=" .. state.fieryBrandCharges .. ", CD=" .. string.format("%.1f", state.fieryBrandCD) .. ")", "want_fiery_brand_cant")
    end
    state.logDebug("verbose", "Fiery Brand Usability Check: -> " .. tostring(result), "fb_usability")
    return result
end

-- Modified ProcessSigilOfSpite
function ProcessSigilOfSpite()
    state.logDebug("minimal", "Checking Sigil of Spite...", "check_sigil_spite_entry")
    local sos_cond1 = state.thrillOfFightDamageActive
    local sos_cond2 = state.currentPower >= 80 and state.can_spb_soon
    local sos_cond3 = state.souls_before_next_rg_sequence < 20
    local cast_sigil_of_spite_condition = sos_cond1 or sos_cond2 or sos_cond3

    local result = CastSpell(
        spells.sigilOfSpite,
        nil,
        10,
        function()
            if not (game_api.getToggle(settings.RG) and cast_sigil_of_spite_condition) then
                state.logDebug("minimal", "Skipping Sigil of Spite: Condition Failed or Toggle OFF (Cond=" .. tostring(cast_sigil_of_spite_condition) .. ", Toggle=" .. tostring(game_api.getToggle(settings.RG)) .. ")", "check_sigil_spite_skip_cond")
                state.resetLogKey("want_sos_cant"); state.resetLogKey("want_sos_range"); state.resetLogKey("check_sigil_spite_met")
                return false
            end
            state.logDebug("minimal", "Check Sigil of Spite: Condition Met. Checking Cast/Range...", "check_sigil_spite_met")
            return true
        end,
        "Sigil of Spite",
        false,
        nil,
        "aoe_self"
    )

    if not result then
    end

    return result
end

-- Block 18: spirit_bomb (general use)
function ProcessSpiritBombGeneral()
    state.logDebug("minimal", "Checking Spirit Bomb (General)...", "check_spb_general_entry")
    if not state.can_spb then
        state.logDebug("minimal", "Skipping SPB (General): Condition Failed (can_spb=" .. tostring(state.can_spb) .. ", ActiveSouls=" .. state.soulFragments .. ", Thresh=" .. state.spb_threshold .. ")", "check_spb_general_skip_cond")
        state.resetLogKey("check_spb_general_met"); state.resetLogKey("skip_spb_gen_api"); state.resetLogKey("skip_spb_gen_fury")
        return false
    end
    state.logDebug("minimal", "Check Spirit Bomb (General): Condition Met. Checking Fury/Cast...", "check_spb_general_met")
    local result = CastSpell(
        spells.spiritBomb,
        state.currentTarget,
        8,
        function()
            return state.currentPower >= FURY_COSTS.spiritBomb and game_api.canCast(spells.spiritBomb)
        end,
        "Spirit Bomb (General)"
    )
    if not result then
        if state.currentPower < FURY_COSTS.spiritBomb then
            state.logDebug("minimal", "Skipping SPB (General): Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.spiritBomb .. ").", "skip_spb_gen_fury")
            state.resetLogKey("skip_spb_gen_api")
        else
            state.logDebug("minimal", "Skipping SPB (General): API CanCast false (CD=" .. string.format("%.1f", state.spiritBombCD) .. ").", "skip_spb_gen_api")
        end
    end
    return result
end

-- Block 19: felblade (SPB generator)
function ProcessFelbladeSPBGenerator()
    state.logDebug("minimal", "Checking Felblade (SPB Gen)...", "check_felblade_gen_entry")
    local felblade_gen_cond = (state.can_spb or state.can_spb_soon) and state.currentPower < FURY_COSTS.spiritBomb
    if not felblade_gen_cond then
        state.logDebug("minimal", "Skipping Felblade (SPB Gen): Condition Failed (Cond=" .. tostring(felblade_gen_cond) .. ", Fury=" .. state.currentPower .. ")", "check_felblade_gen_skip_cond")
        state.resetLogKey("want_felblade_gen_cant"); state.resetLogKey("want_felblade_gen_range"); state.resetLogKey("check_felblade_gen_met")
        return false
    end
    state.logDebug("minimal", "Check Felblade (SPB Gen): Condition Met. Checking Range/Cast...", "check_felblade_gen_met")
    local result = CastSpell(
        spells.felblade,
        state.currentTarget,
        5,
        function()
            return game_api.canCast(spells.felblade)
        end,
        "Felblade (SPB Gen)"
    )
    if not result then
        if not game_api.canCast(spells.felblade) then
            state.logDebug("minimal", "Skipping Felblade (SPB Gen): Cannot Cast (CD: " .. string.format("%.1f", state.felbladeCD) .. ")", "want_felblade_gen_cant")
        else
            state.logDebug("minimal", "Skipping Felblade (SPB Gen): Target Out of Range (5y).", "want_felblade_gen_range")
            state.resetLogKey("want_felblade_gen_cant")
        end
    end
    return result
end

-- Block 20: fracture (SPB generator)
function ProcessFractureSPBGenerator()
    state.logDebug("minimal", "Checking Fracture (SPB Gen)...", "check_fracture_gen_entry")
    local fracture_gen_cond = (state.can_spb or state.can_spb_soon or state.can_spb_one_gcd) and state.currentPower < FURY_COSTS.spiritBomb
    if not fracture_gen_cond then
        state.logDebug("minimal", "Skipping Fracture (SPB Gen): Condition Failed (Cond=" .. tostring(fracture_gen_cond) .. ", Fury=" .. state.currentPower .. ")", "check_fracture_gen_skip_cond")
        state.resetLogKey("want_fracture_gen_cant_api"); state.resetLogKey("want_fracture_gen_cant_charge"); state.resetLogKey("check_fracture_gen_met")
        return false
    end
    state.logDebug("minimal", "Check Fracture (SPB Gen): Condition Met. Checking Charges/Cast...", "check_fracture_gen_met")
    if state.fractureCharges <= 0 then
        state.logDebug("minimal", "Skipping Fracture (SPB Gen): No Charges (" .. state.fractureCharges .. ").", "want_fracture_gen_cant_charge")
        state.resetLogKey("want_fracture_gen_cant_api")
        return false
    end
    local result = CastSpell(
        spells.fracture,
        state.currentTarget,
        8,
        function()
            return game_api.canCastCharge(spells.fracture, 2)
        end,
        "Fracture (SPB Gen)",
        true,
        2
    )
    if not result then
        state.logDebug("minimal", "Skipping Fracture (SPB Gen): Cannot Cast Charge (API).", "want_fracture_gen_cant_api")
    end
    return result
end

-- Block 21: fel_devastation
function ProcessFelDevastation()
    state.logDebug("minimal", "Checking Fel Devastation...", "check_fel_dev_entry")
    local fd_cond_meta = not state.metamorphosis
    local approx_sequence_time_fd_main = state.gcdDurationSeconds * 3.5
    local fd_cond_time_check_val = approx_sequence_time_fd_main + 2
    local fd_cond_time = state.double_rm_remains > fd_cond_time_check_val
    local fd_cond_aoe = state.enemies >= 4
    local fd_cond_part2 = fd_cond_time or fd_cond_aoe
    local fd_cond_frac_time_check_val = 2 + state.gcdDurationSeconds
    local fd_cond_frac = state.fractureCharges == 1 and state.fractureCD < fd_cond_frac_time_check_val
    local fd_cond_thrill = state.single_target == 0 and state.thrillOfFightDamageActive
    local fd_cond_part3 = fd_cond_frac or fd_cond_thrill
    local cast_fel_dev_condition = fd_cond_meta and fd_cond_part2 and fd_cond_part3
    if not cast_fel_dev_condition then
        state.logDebug("minimal", "Skipping Fel Devastation: Condition Failed (Cond=" .. tostring(cast_fel_dev_condition) .. ", !Meta=" .. tostring(fd_cond_meta) .. ")", "check_fel_dev_skip_cond")
        state.resetLogKey("want_fel_dev_cant_cd"); state.resetLogKey("want_fel_dev_cant_fury"); state.resetLogKey("want_fel_dev_range"); state.resetLogKey("check_fel_dev_met")
        return false
    end
    state.logDebug("minimal", "Check Fel Devastation: Condition Met. Checking Range/Fury/Cast...", "check_fel_dev_met")
    local result = CastSpell(
        spells.felDevastation,
        state.currentTarget,
        10,
        function()
            return state.currentPower >= FURY_COSTS.felDevastation and game_api.canCast(spells.felDevastation)
        end,
        "Fel Devastation"
    )
    if not result then
        if state.currentPower < FURY_COSTS.felDevastation then
            state.logDebug("minimal", "Skipping Fel Devastation: Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.felDevastation .. ").", "want_fel_dev_cant_fury")
            state.resetLogKey("want_fel_dev_cant_cd")
        elseif not game_api.canCast(spells.felDevastation) then
            state.logDebug("minimal", "Skipping Fel Devastation: Cannot Cast (CD: " .. string.format("%.1f", state.felDevastationCD) .. ")", "want_fel_dev_cant_cd")
        else
            state.logDebug("minimal", "Skipping Fel Devastation: Target Out of Range (10y).", "want_fel_dev_range")
            state.resetLogKey("want_fel_dev_cant_cd"); state.resetLogKey("want_fel_dev_cant_fury")
        end
    end
    return result
end

-- Block 22: felblade (FD generator)
function ProcessFelbladeFDGenerator()
    state.logDebug("minimal", "Checking Felblade (FD Gen)...", "check_felblade_fd_gen_entry")
    local felblade_fd_gen_cond = state.felDevastationCD < state.gcdDurationSeconds and state.currentPower < 50
    if not felblade_fd_gen_cond then
        state.logDebug("minimal", "Skipping Felblade (FD Gen): Condition Failed (Cond=" .. tostring(felblade_fd_gen_cond) .. ", FD_CD=" .. string.format("%.1f", state.felDevastationCD) .. ", Fury=" .. state.currentPower .. ")", "check_felblade_fd_gen_skip_cond")
        state.resetLogKey("want_felblade_fd_gen_cant"); state.resetLogKey("want_felblade_fd_gen_range"); state.resetLogKey("check_felblade_fd_gen_met")
        return false
    end
    state.logDebug("minimal", "Check Felblade (FD Gen): Condition Met. Checking Range/Cast...", "check_felblade_fd_gen_met")
    local result = CastSpell(
        spells.felblade,
        state.currentTarget,
        5,
        function()
            return game_api.canCast(spells.felblade)
        end,
        "Felblade (FD Gen)"
    )
    if not result then
        if not game_api.canCast(spells.felblade) then
            state.logDebug("minimal", "Skipping Felblade (FD Gen): Cannot Cast (CD: " .. string.format("%.1f", state.felbladeCD) .. ")", "want_felblade_fd_gen_cant")
        else
            state.logDebug("minimal", "Skipping Felblade (FD Gen): Target Out of Range (5y).", "want_felblade_fd_gen_range")
            state.resetLogKey("want_felblade_fd_gen_cant")
        end
    end
    return result
end

-- Block 23: fracture (FD generator)
function ProcessFractureFDGenerator()
    state.logDebug("minimal", "Checking Fracture (FD Gen)...", "check_fracture_fd_gen_entry")
    local fracture_fd_gen_cond = state.felDevastationCD < state.gcdDurationSeconds and state.currentPower < 50
    if not fracture_fd_gen_cond then
        state.logDebug("minimal", "Skipping Fracture (FD Gen): Condition Failed (Cond=" .. tostring(fracture_fd_gen_cond) .. ", FD_CD=" .. string.format("%.1f", state.felDevastationCD) .. ", Fury=" .. state.currentPower .. ")", "check_fracture_fd_gen_skip_cond")
        state.resetLogKey("want_fracture_fd_gen_cant_api"); state.resetLogKey("want_fracture_fd_gen_cant_charge"); state.resetLogKey("check_fracture_fd_gen_met")
        return false
    end
    state.logDebug("minimal", "Check Fracture (FD Gen): Condition Met. Checking Charges/Cast...", "check_fracture_fd_gen_met")
    if state.fractureCharges <= 0 then
        state.logDebug("minimal", "Skipping Fracture (FD Gen): No Charges (" .. state.fractureCharges .. ").", "want_fracture_fd_gen_cant_charge")
        state.resetLogKey("want_fracture_fd_gen_cant_api")
        return false
    end
    local result = CastSpell(
        spells.fracture,
        state.currentTarget,
        8,
        function()
            return game_api.canCastCharge(spells.fracture, 2)
        end,
        "Fracture (FD Gen)",
        true,
        2
    )
    if not result then
        state.logDebug("minimal", "Skipping Fracture (FD Gen): Cannot Cast Charge (API).", "want_fracture_fd_gen_cant_api")
    end
    return result
end

-- Block 24: fracture (general use)
function ProcessFractureGeneral()
    state.logDebug("minimal", "Checking Fracture (General)...", "check_fracture_general_entry")
    local frac_gen_cond_cap = state.fractureCharges == 1 and state.fractureCD < state.gcdDurationSeconds
    local frac_gen_cond_meta = state.metamorphosis
    local frac_gen_cond_spb = (state.can_spb or state.can_spb_soon or state.can_spb_one_gcd)
    local frac_gen_cond_wh = (state.warbladesHungerStacks or 0) >= 5
    local fracture_general_cond = frac_gen_cond_cap or frac_gen_cond_meta or frac_gen_cond_spb or frac_gen_cond_wh
    if not fracture_general_cond then
        state.logDebug("minimal", "Skipping Fracture (General): Condition Failed (Cond=" .. tostring(fracture_general_cond) .. ", Charges=" .. state.fractureCharges .. ")", "check_fracture_general_skip_cond")
        state.resetLogKey("want_fracture_general_cant_api"); state.resetLogKey("want_fracture_general_cant_charge"); state.resetLogKey("check_fracture_general_met")
        return false
    end
    state.logDebug("minimal", "Check Fracture (General): Condition Met. Checking Charges/Cast...", "check_fracture_general_met")
    if state.fractureCharges <= 0 then
        state.logDebug("minimal", "Skipping Fracture (General): No Charges (" .. state.fractureCharges .. ").", "want_fracture_general_cant_charge")
        state.resetLogKey("want_fracture_general_cant_api")
        return false
    end
    local result = CastSpell(
        spells.fracture,
        state.currentTarget,
        8,
        function()
            return game_api.canCastCharge(spells.fracture, 2)
        end,
        "Fracture (General)",
        true,
        2
    )
    if not result then
        state.logDebug("minimal", "Skipping Fracture (General): Cannot Cast Charge (API).", "want_fracture_general_cant_api")
    end
    return result
end

-- Block 25: soul_cleave (general use)
function ProcessSoulCleaveGeneral()
    state.logDebug("minimal", "Checking Soul Cleave (General)...", "check_sc_general_entry")
    local soul_cleave_general_cond = state.soulFragments >= 1
    if not soul_cleave_general_cond then
        state.logDebug("minimal", "Skipping Soul Cleave (General): Condition Failed (Souls=" .. state.soulFragments .. ")", "check_sc_general_skip_cond")
        state.resetLogKey("want_sc_general_cant_cd"); state.resetLogKey("want_sc_general_cant_fury"); state.resetLogKey("check_sc_general_met")
        return false
    end
    state.logDebug("minimal", "Check Soul Cleave (General): Condition Met. Checking Fury/Cast...", "check_sc_general_met")
    local result = CastSpell(
        spells.soulCleave,
        state.currentTarget,
        8,
        function()
            return state.currentPower >= FURY_COSTS.soulCleave and game_api.canCast(spells.soulCleave)
        end,
        "Soul Cleave (General): Reason=Souls>=1, Fury=" .. state.currentPower .. ", Souls=" .. state.soulFragments
    )
    if not result then
        if state.currentPower < FURY_COSTS.soulCleave then
            state.logDebug("minimal", "Skipping Soul Cleave (General): Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.soulCleave .. ").", "want_sc_general_cant_fury")
            state.resetLogKey("want_sc_general_cant_cd")
        else
            state.logDebug("minimal", "Skipping Soul Cleave (General): Cannot Cast (CD: " .. string.format("%.1f", state.soulCleaveCD) .. ").", "want_sc_general_cant_cd")
        end
    end
    return result
end

-- Block 26: fracture (filler)
function ProcessFractureFiller()
    state.logDebug("minimal", "Checking Fracture (Filler)...", "check_fracture_filler_entry")
    if state.fractureCharges <= 0 then
        state.logDebug("minimal", "Skipping Fracture (Filler): Condition Failed (No Charges=" .. state.fractureCharges .. ")", "want_fracture_filler_cant_charge")
        state.resetLogKey("want_fracture_filler_cant_api"); state.resetLogKey("check_fracture_filler_met")
        return false
    end
    state.logDebug("minimal", "Check Fracture (Filler): Condition Met (Charges>0). Checking Cast...", "check_fracture_filler_met")
    local result = CastSpell(
        spells.fracture,
        state.currentTarget,
        8,
        function()
            return game_api.canCastCharge(spells.fracture, 2)
        end,
        "Fracture (Filler)",
        true,
        2
    )
    if not result then
        state.logDebug("minimal", "Skipping Fracture (Filler): Cannot Cast Charge (API).", "want_fracture_filler_cant_api")
    end
    return result
end

-- Block 27: soul_cleave (filler)
function ProcessSoulCleaveFiller()
    state.logDebug("minimal", "Checking Soul Cleave (Filler)...", "check_sc_filler_entry")
    if state.currentPower < FURY_COSTS.soulCleave then
        state.logDebug("minimal", "Skipping Soul Cleave (Filler): Condition Failed (Low Fury=" .. state.currentPower .. "/" .. FURY_COSTS.soulCleave .. ")", "want_sc_filler_cant_fury")
        state.resetLogKey("want_sc_filler_cant_cd"); state.resetLogKey("check_sc_filler_met")
        return false
    end
    state.logDebug("minimal", "Check Soul Cleave (Filler): Condition Met (Fury OK). Checking Cast...", "check_sc_filler_met")
    local result = CastSpell(
        spells.soulCleave,
        state.currentTarget,
        8,
        function()
            return game_api.canCast(spells.soulCleave)
        end,
        "Soul Cleave (Filler): Reason=No Other Action, Fury=" .. state.currentPower
    )
    if not result then
        state.logDebug("minimal", "Skipping Soul Cleave (Filler): Cannot Cast (CD: " .. string.format("%.1f", state.soulCleaveCD) .. ").", "want_sc_filler_cant_cd")
    end
    return result
end

-- Block 28: felblade (filler)
function ProcessFelbladeFiller()
    state.logDebug("minimal", "Checking Felblade (Filler)...", "check_felblade_filler_entry")
    local result = CastSpell(
        spells.felblade,
        state.currentTarget,
        5,
        function()
            return game_api.canCast(spells.felblade)
        end,
        "Felblade (Filler)"
    )
    if not result then
        if not game_api.canCast(spells.felblade) then
            state.logDebug("minimal", "Skipping Felblade (Filler): Cannot Cast (CD: " .. string.format("%.1f", state.felbladeCD) .. ").", "want_felblade_filler_cant_cd")
        else
            state.logDebug("minimal", "Skipping Felblade (Filler): Condition Failed (Out of Range - 5y).", "want_felblade_filler_range")
            state.resetLogKey("want_felblade_filler_cant_cd")
        end
    end
    return result
end

-- OnInit
function OnInit()
    state.initialize()
    local asciiArt = [[

    ]]

    local yellowColor = "\27[33m"
    local resetColor = "\27[0m"
    print(yellowColor .. asciiArt .. resetColor)

    if settings and type(settings.createSettings) == "function" then
        settings.createSettings()
    else
        state.logDebug("minimal", "Error: settings.createSettings not found, falling back!")
        settings = settings or {}
        settings.Pause = "Pause"
        settings.RG = "ReaversGlaive"
        settings.Brand = "FieryBrand"
        game_api.createToggle(settings.Pause, "Pause the rotation", false, 0)
        game_api.createToggle(settings.RG, "Enable Reaver's Glaive", true, 0)
        game_api.createToggle(settings.Brand, "Enable Fiery Brand", true, 0)
    end
    state.logDebug("minimal", "APL-based Vengeance Demon Hunter combat routine initialized")
end

-- Helper function to check if a target is in range
function IsInRange(range, unit)
    if unit == nil or unit == "00" then return false end
    local distance = game_api.distanceToUnit(unit) or 999
    return distance <= range
end

-- Helper function to check talent
function HasTalent(talentId)
    -- Implementation not provided in original; placeholder
    return game_api.hasTalent(talentId) or false
end

-- Main update function
function OnUpdate()
    state.updateCounter = state.updateCounter + 1
    local isPaused = settings.Pause and game_api.getToggle(settings.Pause)
    if isPaused then
        state.logDebug("minimal", "Paused", "pause_status")
        state.wasPaused = true
        return
    elseif state.wasPaused then
        state.logDebug("minimal", "Resumed", "pause_status")
        state.wasPaused = false
        state.resetLogKey("pause_status")
    end

    state.StateUpdate()

    if game_api.currentPlayerIsCasting() or game_api.currentPlayerIsMounted() or
       game_api.currentPlayerIsChanneling() or state.currentHpPercent <= 0 then
        return
    end

    if state.lastCombatStatus then
        if state.currentTarget ~= "00" and game_api.unitHealthPercent(state.currentTarget) > 0 then
            ProcessNextAction()
        else
            state.logDebug("verbose", "No valid target or target is dead.", "target_status")
        end
    end
end

-- Process the filler actions for the Reaver's Glaive sequence
function ProcessRGFiller()
    state.logDebug("verbose", "Processing RG Sequence Filler", "rg_filler_active")
    local rgToggleActive = game_api.getToggle(settings.RG) or false
    local felbladeInRange = IsInRange(5, state.currentTarget)
    local canCastFelblade = game_api.canCast(spells.felblade)

    if felbladeInRange and canCastFelblade then
        state.logDebug("minimal", "Cast Felblade (RG Filler)", "cast_attempt")
        game_api.castSpell(spells.felblade)
        return true
    end

    if not state.rendingStrike then
        local canCastFracture = game_api.canCastCharge(spells.fracture, 2)
        if state.fractureCharges > 0 and canCastFracture then
            state.logDebug("minimal", "Cast Fracture (RG Filler - !RS)", "cast_attempt")
            game_api.castSpell(spells.fracture)
            return true
        end
    end

    local canCastSoF = game_api.canCast(spells.sigilOfFlame)
    if rgToggleActive and canCastSoF then
        if IsInRange(10, state.currentTarget) then
            state.logDebug("minimal", "Cast Sigil of Flame (RG Filler)", "cast_attempt")
            game_api.castAOESpellOnSelf(spells.sigilOfFlame)
            state.lastSigilOfFlameCastTime = state.time
            return true
        end
    elseif not rgToggleActive then
        state.logDebug("verbose", "RG Filler: Skipped Sigil of Flame (RG Toggle OFF)", "rg_filler_skip_sof")
    end

    local canCastSoS = game_api.canCast(spells.sigilOfSpite)
    if rgToggleActive and canCastSoS then
        if IsInRange(10, state.currentTarget) then
            state.logDebug("minimal", "Cast Sigil of Spite (RG Filler)", "cast_attempt")
            game_api.castAOESpellOnSelf(spells.sigilOfSpite)
            return true
        end
    elseif not rgToggleActive then
        state.logDebug("verbose", "RG Filler: Skipped Sigil of Spite (RG Toggle OFF)", "rg_filler_skip_sos")
    end

    local canCastFD = game_api.canCast(spells.felDevastation)
    if state.currentPower >= FURY_COSTS.felDevastation and canCastFD then
        state.logDebug("minimal", "Cast Fel Devastation (RG Filler)", "cast_attempt")
        game_api.castSpell(spells.felDevastation)
        return true
    end

    state.logDebug("verbose", "RG Filler: No action taken.", "rg_filler_no_action")
    return false
end

-- Process the Reaver's Glaive sequence main actions
function ProcessRGSequence()
    local gf = state.glaiveFlurry
    local rs = state.rendingStrike
    local is_st = (state.enemies == 1)
    local is_aoe = (state.enemies >= 2)
    state.logDebug("verbose", "Processing RG Sequence | ST=" .. tostring(is_st) .. " | AoE=" .. tostring(is_aoe) .. " | Fury: " .. state.currentPower .. " | GF: " .. tostring(gf) .. " | RS: " .. tostring(rs), "rg_sequence_active")

    local primarySpell = nil
    local secondarySpell = nil
    if is_st then
        primarySpell = spells.soulCleave
        secondarySpell = spells.fracture
        state.logDebug("verbose", "RG Sequence: Mode=ST, Primary=SoulCleave, Secondary=Fracture", "rg_mode_st")
    elseif is_aoe then
        primarySpell = spells.fracture
        secondarySpell = spells.soulCleave
        state.logDebug("verbose", "RG Sequence: Mode=AoE, Primary=Fracture, Secondary=SoulCleave", "rg_mode_aoe")
    else
        primarySpell = spells.soulCleave
        secondarySpell = spells.fracture
        state.logDebug("minimal", "RG Sequence: WARNING - 0 enemies detected, defaulting to ST order.", "rg_mode_warn_zero")
    end

    local callFiller = false
    local fillerReason = ""
    if primarySpell == spells.soulCleave and state.currentPower < FURY_COSTS.soulCleave then
        fillerReason = "Low Fury (" .. state.currentPower .. "/" .. FURY_COSTS.soulCleave .. ") for Primary: Soul Cleave"
        callFiller = true
    elseif primarySpell == spells.fracture and state.fractureCharges < 1 then
        fillerReason = "Low Charges (" .. state.fractureCharges .. ") for Primary: Fracture"
        callFiller = true
    end

    if callFiller then
        state.logDebug("verbose", "RG Sequence: Condition met to try filler. Reason: " .. fillerReason, "rg_filler_reason")
        local fillerActionTaken = ProcessRGFiller()
        if fillerActionTaken then
            state.resetLogKey("rg_sequence_active"); state.resetLogKey("rg_mode_st"); state.resetLogKey("rg_mode_aoe"); state.resetLogKey("rg_mode_warn_zero")
            return true
        end
        state.logDebug("verbose", "RG Sequence: Filler called but took no action.", "rg_filler_failed")
    else
        state.resetLogKey("rg_filler_reason"); state.resetLogKey("rg_filler_failed")
    end

    local function tryCast(spellId)
        if spellId == spells.soulCleave then
            local soulCleaveConditionMet = gf
            state.logDebug("verbose", "RG Sequence Try Soul Cleave: SimpleCond(GF)=" .. tostring(soulCleaveConditionMet) .. " | Fury=" .. state.currentPower .. "/" .. FURY_COSTS.soulCleave .. " | CanCastAPI=" .. tostring(game_api.canCast(spells.soulCleave)))
            if soulCleaveConditionMet and state.currentPower >= FURY_COSTS.soulCleave and game_api.canCast(spells.soulCleave) then
                state.logDebug("minimal", "Cast Soul Cleave (RG Sequence)", "cast_attempt")
                game_api.castSpell(spells.soulCleave)
                return true
            end
        elseif spellId == spells.fracture then
            local fractureConditionMet = rs
            state.logDebug("verbose", "RG Sequence Try Fracture: SimpleCond(RS)=" .. tostring(fractureConditionMet) .. " | Charges=" .. state.fractureCharges .. " | CanCastAPI=" .. tostring(game_api.canCastCharge(spells.fracture, 2)))
            if fractureConditionMet and state.fractureCharges > 0 and game_api.canCastCharge(spells.fracture, 2) then
                if not state.glaiveFlurry then
                    local currentGcdDuration = state.gcdDurationSeconds
                    if type(currentGcdDuration) ~= "number" or currentGcdDuration <= 0 then
                        state.logDebug("minimal", "WARNING: state.gcdDurationSeconds invalid in ProcessRGSequence! Defaulting to " .. DEFAULT_GCD_SECONDS .. "s", "gcd_calc_error_rg")
                        currentGcdDuration = DEFAULT_GCD_SECONDS
                    end
                    state.double_rm_expires = state.time + currentGcdDuration + 20.0
                    state.logDebug("minimal", string.format("Setting double_rm_expires to: %.2f (Time=%.2f + GCD=%.3f + 20)",
                        state.double_rm_expires, state.time, currentGcdDuration), "rm_expires_set")
                else
                    state.logDebug("verbose", "Fracture cast, but not meeting 2-stack condition (!GF=" .. tostring(not state.glaiveFlurry) .. ", RS=" .. tostring(state.rendingStrike) .. "). Not setting double_rm_expires.", "rm_expires_skip")
                    state.resetLogKey("rm_expires_set")
                end
                state.logDebug("minimal", "Cast Fracture (RG Sequence)", "cast_attempt")
                game_api.castSpell(spells.fracture)
                return true
            end
        end
        return false
    end

    if tryCast(primarySpell) then
        return true
    elseif tryCast(secondarySpell) then
        return true
    end

    state.logDebug("verbose", "RG Sequence: No primary or secondary action taken.", "rg_no_action")
    state.resetLogKey("rg_mode_st"); state.resetLogKey("rg_mode_aoe"); state.resetLogKey("rg_mode_warn_zero")
    return false
end

-- Process the rg_prep action list
function ProcessRGPrep()
    state.logDebug("minimal", ">>> Processing RG Prep Sequence <<<", "rg_prep_entry")
    local rgToggleActive = game_api.getToggle(settings.RG) or false
    local actionTaken = false

    local felbladeInRange = IsInRange(5, state.currentTarget)
    local canCastFelblade = game_api.canCast(spells.felblade)
    state.logDebug("verbose", "RG Prep Check Felblade: InRange=" .. tostring(felbladeInRange) .. ", CanCast=" .. tostring(canCastFelblade) .. ", CD=" .. string.format("%.1f", state.felbladeCD))
    if felbladeInRange and canCastFelblade then
        state.logDebug("minimal", "Cast Felblade (RG Prep)", "cast_attempt")
        game_api.castSpell(spells.felblade)
        actionTaken = true
        return actionTaken
    end

    local canCastSoF = game_api.canCast(spells.sigilOfFlame)
    state.logDebug("verbose", "RG Prep Check Sigil of Flame: CanCast=" .. tostring(canCastSoF) .. ", CD=" .. string.format("%.1f", state.sigilOfFlameCD))
    if not actionTaken and rgToggleActive and canCastSoF then
        if IsInRange(10, state.currentTarget) then
            state.logDebug("minimal", "Cast Sigil of Flame (RG Prep)", "cast_attempt")
            game_api.castAOESpellOnSelf(spells.sigilOfFlame)
            state.lastSigilOfFlameCastTime = state.time
            actionTaken = true
            return actionTaken
        end
    elseif not rgToggleActive then
        state.logDebug("verbose", "RG Prep: Skipped Sigil of Flame (RG Toggle OFF)", "rg_prep_skip_sof")
    end

    local canCastImmo = game_api.canCast(spells.immolationAura)
    state.logDebug("verbose", "RG Prep Check Immolation Aura: CanCast=" .. tostring(canCastImmo) .. ", CD=" .. string.format("%.1f", state.immolationAuraCD))
    if not actionTaken and canCastImmo then
        state.logDebug("minimal", "Cast Immolation Aura (RG Prep)", "cast_attempt")
        game_api.castSpell(spells.immolationAura)
        actionTaken = true
        return actionTaken
    end

    local canCastFracture = game_api.canCastCharge(spells.fracture, 2)
    state.logDebug("verbose", "RG Prep Check Fracture: Charges=" .. state.fractureCharges .. ", CanCast=" .. tostring(canCastFracture))
    if not actionTaken and state.fractureCharges > 0 and canCastFracture then
        state.logDebug("minimal", "Cast Fracture (RG Prep)", "cast_attempt")
        game_api.castSpell(spells.fracture)
        actionTaken = true
        return actionTaken
    end

    state.logDebug("verbose", "RG Prep: No action taken.", "rg_prep_no_action")
    return actionTaken
end

-- Process the rg_overflow action list
function ProcessRGOverflow()
    state.logDebug("minimal", ">>> Processing RG Overflow Sequence <<<", "rg_overflow_entry")
    local rgToggleActive = game_api.getToggle(settings.RG) or false
    local actionTaken = false

    state.trigger_overflow = 1
    state.logDebug("verbose", "RG Overflow: Set trigger_overflow=1")

    if state.rg_enhance_cleave == false then
        state.logDebug("verbose", "RG Overflow: Set rg_enhance_cleave=true (Unconditional in this list)", "rg_overflow_enhance_set")
    end
    state.rg_enhance_cleave = true

    local keenBonus = state.hasTalentKeenEngagement and 20 or 0
    local enhanceBonus = state.rg_enhance_cleave and 25 or 0
    local effectiveFury = state.currentPower + enhanceBonus + keenBonus
    local rgOverflowCond = (effectiveFury >= FURY_COSTS.reaversGlaive) and not state.rendingStrike and not state.glaiveFlurry

    state.logDebug("verbose", "RG Overflow Check RG Cast: Condition=" .. tostring(rgOverflowCond) .. " (EffFury=" .. effectiveFury .. "/" .. FURY_COSTS.reaversGlaive .. ", !RS=" .. tostring(not state.rendingStrike) .. ", !GF=" .. tostring(not state.glaiveFlurry) .. ")")

    if rgToggleActive and rgOverflowCond then
        if game_api.canCast(spells.reaversGlaive) then
            state.logDebug("minimal", "Cast Reaver's Glaive (RG Overflow)", "cast_attempt")
            game_api.castSpell(spells.reaversGlaive)
            actionTaken = true
        else
            state.logDebug("verbose", "RG Overflow: Wanted Reaver's Glaive, but cannot cast.", "rg_overflow_want_rg")
        end
    elseif not rgToggleActive then
        state.logDebug("verbose", "RG Overflow: Skipped Reaver's Glaive (RG Toggle OFF)", "rg_overflow_skip_rg")
    end

    if actionTaken then return true end

    if not rgOverflowCond then
        state.logDebug("verbose", "RG Overflow: Fury condition for RG failed, calling rg_prep.", "rg_overflow_call_prep")
        local prepActionTaken = ProcessRGPrep()
        if prepActionTaken then actionTaken = true end
    end

    return actionTaken
end

function ProcessNextAction()
    if not state.notOnGCD then
        state.logDebug("verbose", "Skipping Action: On GCD or Casting/Channeling.", "action_skip_gcd")
        return false
    end
    state.resetLogKey("action_skip_gcd")

    if not state.currentTarget or state.currentTarget == "00" then
        state.logDebug("minimal", "Skipping Action: No target selected.", "action_skip_no_target")
        return false
    end
    state.resetLogKey("action_skip_no_target")

    local rgToggleActive = game_api.getToggle(settings.RG) or false
    local brandToggleActive = game_api.getToggle(settings.Brand) or false

    local currentGcdDuration = state.gcdDurationSeconds
    if type(currentGcdDuration) ~= "number" or currentGcdDuration <= 0 then
        state.logDebug("minimal", "WARNING: state.gcdDurationSeconds invalid in ProcessNextAction! Defaulting to " .. DEFAULT_GCD_SECONDS .. "s", "gcd_calc_error_proc")
        currentGcdDuration = DEFAULT_GCD_SECONDS
    end

    if ProcessDemonSpikes() then return true end
    if ProcessInterrupt() then return true end

    state.logDebug("minimal", "Checking RG Sequence...", "rg_sequence_check_entry")
    local wasLastCastRG = (state.prevGCD1 == spells.reaversGlaive)
    local rg_condition_met = state.glaiveFlurry or state.rendingStrike or wasLastCastRG
    if rg_condition_met then
        state.logDebug("minimal", "Entering Reaver's Glaive sequence (rg_sequence). GF=" .. tostring(state.glaiveFlurry) .. ", RS=" .. tostring(state.rendingStrike) .. ", LastRG=" .. tostring(wasLastCastRG), "rg_sequence_check")
        local rgActionTaken = ProcessRGSequence()
        if rgActionTaken then return true end
        state.logDebug("minimal", "RG Sequence returned false (no action taken), continuing checks...", "rg_sequence_continue")
    else
        state.logDebug("minimal", "Skipping RG Sequence: Condition Not Met (GF=" .. tostring(state.glaiveFlurry) .. ", RS=" .. tostring(state.rendingStrike) .. ", LastRG=" .. tostring(wasLastCastRG) .. ")", "rg_sequence_skip_cond")
        state.resetLogKey("rg_sequence_check"); state.resetLogKey("rg_sequence_active"); state.resetLogKey("rg_filler_active"); state.resetLogKey("rg_filler_reason"); state.resetLogKey("rg_filler_failed"); state.resetLogKey("rg_no_action"); state.resetLogKey("rg_sequence_continue")
    end

    if ProcessTheHunt() then return true end
    if ProcessSpiritBombSpecific1() then return true end
    if ProcessImmolationAura() then return true end
    if ProcessSigilOfFlame() then return true end

    state.logDebug("minimal", "Checking RG Overflow Call...", "check_rg_overflow_entry")
    local approx_rg_sequence_time = (currentGcdDuration * 3) + 0.5
    local cond_rg_proc = state.reaversGlaiveProc
    local cond_targets = not (state.enemies >= 4)
    local cond_rm_debuff = state.reaversMarkActive
    local cond_rm_time_min = state.double_rm_remains > approx_rg_sequence_time
    local cond_thrill_check = (not state.thrillOfFightDamageActive) or (state.thrillOfFightDamageRemains < approx_rg_sequence_time)
    local cond_rm_time_double = state.double_rm_remains > (approx_rg_sequence_time * 2)
    local cond_hunt_check = (state.souls_before_next_rg_sequence >= 20) or (state.double_rm_remains > (approx_rg_sequence_time + state.theHuntCD))
    local overflow_cond = cond_rg_proc and cond_targets and cond_rm_debuff and cond_rm_time_min and cond_thrill_check and cond_rm_time_double and cond_hunt_check
    if overflow_cond then
        state.logDebug("minimal", "Entering RG Overflow sequence (Refined Check)", "rg_overflow_check")
        local overflowActionTaken = ProcessRGOverflow()
        if overflowActionTaken then return overflowActionTaken end
        state.logDebug("minimal", "RG Overflow returned false (no action taken), continuing...", "rg_overflow_continue")
    else
        state.logDebug("minimal", "Skipping RG Overflow Sequence Call: Condition Failed (Cond=" .. tostring(overflow_cond) .. ", RGProc=" .. tostring(cond_rg_proc) .. ", RMRem=" .. string.format("%.1f", state.double_rm_remains) .. ", ThrillOK=" .. tostring(cond_thrill_check) .. ")", "rg_overflow_skip_cond")
        state.resetLogKey("rg_overflow_check"); state.resetLogKey("rg_overflow_entry"); state.resetLogKey("rg_overflow_continue")
    end

    if ProcessSoulCleaveSpecific() then return true end
    if ProcessSpiritBombSpecific2() then return true end
    if ProcessReaversGlaive() then return true end

    -- #15: APL Action: call_action_list,name=rg_prep
    state.logDebug("minimal", "Checking RG Prep Call...", "check_rg_prep_call_entry")
    local rg_cond1_fury_check = false
    local keenBonus_rg = state.hasTalentKeenEngagement and 20 or 0
    local enhanceBonus_rg = state.rg_enhance_cleave and 25 or 0
    local effectiveFury_rg = state.currentPower + enhanceBonus_rg + keenBonus_rg
    if effectiveFury_rg >= FURY_COSTS.reaversGlaive then rg_cond1_fury_check = true end
    local rg_cond2_not_active = not (state.rendingStrike or state.glaiveFlurry)
    local rg_cond3_rm_check = state.double_rm_remains > (currentGcdDuration + approx_rg_sequence_time)
    local rg_call_prep_condition = cond_rg_proc and rg_cond1_fury_check and rg_cond2_not_active and rg_cond3_rm_check
    if rg_call_prep_condition then
        state.logDebug("minimal", "Entering RG Prep sequence (call_action_list,rg_prep)", "rg_prep_call_check")
        local prepActionTaken = ProcessRGPrep()
        if prepActionTaken then return true end
        state.logDebug("minimal", "RG Prep returned false (no action taken), continuing...", "rg_prep_continue")
    else
        state.logDebug("minimal", "Skipping RG Prep Sequence Call: Condition Failed (Cond=" .. tostring(rg_call_prep_condition) .. ", RGProc=" .. tostring(cond_rg_proc) .. ", EffFury=" .. effectiveFury_rg .. ", !RS=" .. tostring(not state.rendingStrike) .. ", !GF=" .. tostring(not state.glaiveFlurry) .. ", RMRem=" .. string.format("%.1f", state.double_rm_remains) .. ")", "rg_prep_call_skip_cond")
        state.resetLogKey("rg_prep_call_check"); state.resetLogKey("rg_prep_entry"); state.resetLogKey("rg_prep_continue")
    end

    if ProcessFieryBrand() then return true end
    if ProcessSigilOfSpite() then return true end
    if ProcessSpiritBombGeneral() then return true end
    if ProcessFelbladeSPBGenerator() then return true end
    if ProcessFractureSPBGenerator() then return true end
    if ProcessFelDevastation() then return true end
    if ProcessFelbladeFDGenerator() then return true end
    if ProcessFractureFDGenerator() then return true end
    if ProcessFractureGeneral() then return true end
    if ProcessSoulCleaveGeneral() then return true end
    if ProcessFractureFiller() then return true end
    if ProcessSoulCleaveFiller() then return true end
    if ProcessFelbladeFiller() then return true end

    state.logDebug("minimal", "No actions taken in ProcessNextAction.", "no_action_taken")
    return false
end