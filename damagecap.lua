_addon.name = 'DamageCap'
_addon.author = 'Zerodragoon'
_addon.version = '1.0'
_addon.commands = {'damagecap', 'dc'}


require('luau')
require 'tables'
require 'sets'
require 'texts'
require 'config'
require 'resources'
require 'packets'

config = _libs.config
texts = _libs.texts
res = _libs.resources

local defaults = T{
    visible = true,
    melee = true,
    ranged = true,
    ws = true,
    position = T{ x = 100, y = 100 },
    bg = T{ alpha = 255, red = 0, green = 0, blue = 0 },
    text = T{ size = 10, font = 'Arial', alpha = 255, red = 255, green = 255, blue = 255 },
}

local settings_file = 'data/settings.xml'
local settings = config.load(settings_file, defaults)

local display = texts.new(settings)

display:draggable(true)

local weapon_ranks = {
    [1] = 1, -- Hand-to-Hand
    [2] = 2, -- Dagger
    [3] = 3, -- Sword
    [4] = 4, -- Great Sword
    [5] = 5, -- Axe
    [6] = 6, -- Great Axe
    [7] = 7, -- Scythe
    [8] = 8, -- Polearm
    [9] = 9, -- Katana
    [10] = 10, -- Great Katana
    [11] = 11, -- Club
    [12] = 12, -- Staff
    [25] = 25, -- Archery
    [26] = 26, -- Marksmanship
    [27] = 27, -- Throwing
}

function get_weapon_rank(skill_id)
    return weapon_ranks[skill_id] or 1
end

local damage_data = T{
    melee = T{
        crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
        non_crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
    },
    ranged = T{
        crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
        non_crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
    },
    ws = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
}

local enemy_data = T{
    level = 0,
    name = '',
}

local player = nil
local target = nil
local last_target_data = nil  -- Stores data from the last target before change
local target_history = T{}  -- Stores the last 50 targets
local MAX_HISTORY = 50

function get_player_attack()
    if not player or not player.vitals then return 0 end
    local str = player.vitals.str or 0
    local equipment = player.equipment
    if not equipment then return 8 + str end
    local main_weapon_id = equipment.main or 0
    local weapon_dmg = 0
    
    if main_weapon_id and main_weapon_id ~= 0 then
        local item = res.items[main_weapon_id]
        if item then weapon_dmg = item.damage or 0 end
    end

    -- Base attack: 8 + STR + weapon damage + gear attack bonus
    local attack = 8 + str + weapon_dmg
    
    -- Add gear attack (simplified - would need full gear parsing for full accuracy)
    -- For now, estimate from equipped items
    return attack
end

function get_base_damage()
    if not player or not player.vitals then return 1 end
    local str = player.vitals.str or 0
    local equipment = player.equipment
    if not equipment then return 1 end
    local main_weapon_id = equipment.main or 0
    local weapon_dmg = 0
    local skill_id = 1
    
    if main_weapon_id and main_weapon_id ~= 0 then
        local item = res.items[main_weapon_id]
        if item then 
            weapon_dmg = item.damage or 0
            skill_id = item.skill or 1
        end
    end

    local weapon_rank = get_weapon_rank(skill_id)
    local fstr = math.floor((str - weapon_rank) * 9 / 8)
    if fstr < 0 then fstr = 0 end

    local base_dmg = weapon_dmg + fstr
    -- Ensure minimum of 1 to avoid division by zero
    return math.max(base_dmg, 1)
end

function calculate_pdif(damage, base_dmg, multiplier)
    -- Guard against division by zero
    if base_dmg <= 0 or multiplier <= 0 then
        return 0
    end
    -- Damage = floor(floor(base_dmg * pdif) * multiplier)
    -- To find pdif, approximate
    local effective_dmg = damage / multiplier
    local pdif = effective_dmg / base_dmg
    -- Clamp to reasonable values
    if pdif ~= pdif or pdif == math.huge or pdif == -math.huge then
        return 0
    end
    return pdif
end

function get_multiplier()
    if not player then return 1 end
    local buffs = player.buffs
    local multi = 1
    -- Berserk: 1.5
    if table.contains(buffs, 1) then multi = multi * 1.5 end
    -- Aggressor: 1.25 (physical damage)
    if table.contains(buffs, 2) then multi = multi * 1.25 end
    -- Haste: ~1.25 (affects attack speed, not direct dmg multiplier)
    -- Warcry and other buffs add attack, not multiplier
    return multi
end

function get_attack_buffs()
    if not player then return '' end
    local buffs = player.buffs
    local buff_text = ''
    local buff_names = T{
        [1] = 'Berserk',
        [2] = 'Aggressor',
        [8] = 'Haste',
        [18] = 'Protect',
        [19] = 'Shell',
        [176] = 'Aftermath',
    }
    for _, buff_id in ipairs(buffs) do
        if buff_names[buff_id] then
            buff_text = buff_text .. buff_names[buff_id] .. ' '
        end
    end
    return buff_text ~= '' and buff_text or 'None'
end

function is_capped(damage_type_data, variance_pct)
    -- If variance is close to 5%, likely capped (randomizer range)
    -- If variance > 10%, likely uncapped (has room to grow)
    -- Capped damage has natural variance floor at ~5%
    if variance_pct <= 7 and damage_type_data.count > 3 then
        return true
    elseif variance_pct > 10 then
        return false
    end
    -- Uncertain
    return false
end

function show_help()
    windower.add_to_chat(207, '=== DamageCap Help ===')
    windower.add_to_chat(207, 'DamageCap tracks and displays damage cap status for different attack types.')
    windower.add_to_chat(207, ' ')
    windower.add_to_chat(207, 'Commands:')
    windower.add_to_chat(207, '  damagecap help/? - Shows this help message')
    windower.add_to_chat(207, '  damagecap show/hide - Toggles display visibility')
    windower.add_to_chat(207, '  damagecap melee - Toggles melee damage tracking display')
    windower.add_to_chat(207, '  damagecap ranged - Toggles ranged damage tracking display')
    windower.add_to_chat(207, '  damagecap ws - Toggles weapon skill damage tracking display')
    windower.add_to_chat(207, '  damagecap reset - Resets all damage data')
    windower.add_to_chat(207, '  damagecap history - Shows the last 50 targets fought')
    windower.add_to_chat(207, ' ')
    windower.add_to_chat(207, 'Display shows:')
    windower.add_to_chat(207, '  CAPPED - Damage variance <= 7% (likely damage capped)')
    windower.add_to_chat(207, '  Uncapped - Damage has room to grow')
    windower.add_to_chat(207, ' ')
end

function show_history()
    if #target_history == 0 then
        windower.add_to_chat(207, 'No target history yet.')
        return
    end
    windower.add_to_chat(207, '=== Target History (Last 50) ===')
    for i = #target_history, 1, -1 do
        local entry = target_history[i]
        local num = #target_history - i + 1
        windower.add_to_chat(207, string.format('%d. %s (Lvl %d)', num, entry.name or 'Unknown', entry.level or 0))
        
        -- Check if damage_data exists
        if not entry.damage_data then
            windower.add_to_chat(207, '   No damage data recorded')
        else
            -- Display melee damage cap status
            if entry.damage_data.melee and (entry.damage_data.melee.crit.count > 0 or entry.damage_data.melee.non_crit.count > 0) then
                windower.add_to_chat(207, '   Melee:')
                if entry.damage_data.melee.crit and entry.damage_data.melee.crit.count > 0 then
                    local var = entry.damage_data.melee.crit.max_damage - entry.damage_data.melee.crit.min_damage
                    local var_pct = entry.damage_data.melee.crit.min_damage > 0 and (var / entry.damage_data.melee.crit.min_damage * 100) or 0
                    local capped = is_capped(entry.damage_data.melee.crit, var_pct)
                    windower.add_to_chat(207, string.format('     Crit: %s | Avg: %d | Count: %d', capped and 'CAPPED' or 'Uncapped', math.floor(entry.damage_data.melee.crit.avg or 0), entry.damage_data.melee.crit.count or 0))
                end
                if entry.damage_data.melee.non_crit and entry.damage_data.melee.non_crit.count > 0 then
                    local var = entry.damage_data.melee.non_crit.max_damage - entry.damage_data.melee.non_crit.min_damage
                    local var_pct = entry.damage_data.melee.non_crit.min_damage > 0 and (var / entry.damage_data.melee.non_crit.min_damage * 100) or 0
                    local capped = is_capped(entry.damage_data.melee.non_crit, var_pct)
                    windower.add_to_chat(207, string.format('     Non-Crit: %s | Avg: %d | Count: %d', capped and 'CAPPED' or 'Uncapped', math.floor(entry.damage_data.melee.non_crit.avg or 0), entry.damage_data.melee.non_crit.count or 0))
                end
            end
            
            -- Display ranged damage cap status
            if entry.damage_data.ranged and (entry.damage_data.ranged.crit.count > 0 or entry.damage_data.ranged.non_crit.count > 0) then
                windower.add_to_chat(207, '   Ranged:')
                if entry.damage_data.ranged.crit and entry.damage_data.ranged.crit.count > 0 then
                    local var = entry.damage_data.ranged.crit.max_damage - entry.damage_data.ranged.crit.min_damage
                    local var_pct = entry.damage_data.ranged.crit.min_damage > 0 and (var / entry.damage_data.ranged.crit.min_damage * 100) or 0
                    local capped = is_capped(entry.damage_data.ranged.crit, var_pct)
                    windower.add_to_chat(207, string.format('     Crit: %s | Avg: %d | Count: %d', capped and 'CAPPED' or 'Uncapped', math.floor(entry.damage_data.ranged.crit.avg or 0), entry.damage_data.ranged.crit.count or 0))
                end
                if entry.damage_data.ranged.non_crit and entry.damage_data.ranged.non_crit.count > 0 then
                    local var = entry.damage_data.ranged.non_crit.max_damage - entry.damage_data.ranged.non_crit.min_damage
                    local var_pct = entry.damage_data.ranged.non_crit.min_damage > 0 and (var / entry.damage_data.ranged.non_crit.min_damage * 100) or 0
                    local capped = is_capped(entry.damage_data.ranged.non_crit, var_pct)
                    windower.add_to_chat(207, string.format('     Non-Crit: %s | Avg: %d | Count: %d', capped and 'CAPPED' or 'Uncapped', math.floor(entry.damage_data.ranged.non_crit.avg or 0), entry.damage_data.ranged.non_crit.count or 0))
                end
            end
            
            -- Display WS damage cap status
            if entry.damage_data.ws and entry.damage_data.ws.count > 0 then
                windower.add_to_chat(207, '   Weapon Skill:')
                local var = entry.damage_data.ws.max_damage - entry.damage_data.ws.min_damage
                local var_pct = entry.damage_data.ws.min_damage > 0 and (var / entry.damage_data.ws.min_damage * 100) or 0
                local capped = is_capped(entry.damage_data.ws, var_pct)
                windower.add_to_chat(207, string.format('     %s | Avg: %d | Count: %d', capped and 'CAPPED' or 'Uncapped', math.floor(entry.damage_data.ws.avg or 0), entry.damage_data.ws.count or 0))
            end
        end
    end
end

function update_display()
    if not player then
        display:text('DamageCap: Initializing...')
        display:visible(settings.visible)
        return
    end
    
    local player_attack = get_player_attack()
    local buffs = get_attack_buffs()
    local enemy_name = enemy_data.name or 'Unknown'
    local enemy_level = enemy_data.level or 0
    local text = 'Enemy: ' .. enemy_name .. ' (Lvl ' .. enemy_level .. ')\n'
    
    if settings.melee then
        for _, hit_type in ipairs({'non_crit', 'crit'}) do
            local data = damage_data.melee[hit_type]
            local var = data.max_damage - data.min_damage
            local var_pct = data.min_damage > 0 and (var / data.min_damage * 100) or 0
            local capped = is_capped(data, var_pct)
            local label = hit_type == 'crit' and 'Melee Crit' or 'Melee Non-Crit'
            text = text .. label .. ': ' .. (capped and 'CAPPED' or 'Uncapped') .. ' | Count: ' .. data.count .. ' | Avg: ' .. math.floor(data.avg) .. ' | Min: ' .. data.min_damage .. ' Max: ' .. data.max_damage .. ' (' .. string.format('%.1f%%', var_pct) .. ')\n'
        end
    end
    if settings.ranged then
        for _, hit_type in ipairs({'non_crit', 'crit'}) do
            local data = damage_data.ranged[hit_type]
            local var = data.max_damage - data.min_damage
            local var_pct = data.min_damage > 0 and (var / data.min_damage * 100) or 0
            local capped = is_capped(data, var_pct)
            local label = hit_type == 'crit' and 'Ranged Crit' or 'Ranged Non-Crit'
            text = text .. label .. ': ' .. (capped and 'CAPPED' or 'Uncapped') .. ' | Count: ' .. data.count .. ' | Avg: ' .. math.floor(data.avg) .. ' | Min: ' .. data.min_damage .. ' Max: ' .. data.max_damage .. ' (' .. string.format('%.1f%%', var_pct) .. ')\n'
        end
    end
    if settings.ws then
        local var = damage_data.ws.max_damage - damage_data.ws.min_damage
        local var_pct = damage_data.ws.min_damage > 0 and (var / damage_data.ws.min_damage * 100) or 0
        local capped = is_capped(damage_data.ws, var_pct)
        text = text .. 'WS: ' .. (capped and 'CAPPED' or 'Uncapped') .. ' | Count: ' .. damage_data.ws.count .. ' | Avg: ' .. math.floor(damage_data.ws.avg) .. ' | Min: ' .. damage_data.ws.min_damage .. ' Max: ' .. damage_data.ws.max_damage .. ' (' .. string.format('%.1f%%', var_pct) .. ')'
    end
    display:text(text)
    display:visible(settings.visible)
end

windower.register_event('load', function()
    player = windower.ffxi.get_player()
    update_display()
end)

windower.register_event('login', function()
    player = windower.ffxi.get_player()
    update_display()
end)

windower.register_event('addon command', function(command, ...)
    local args = {...}
    command = command:lower()
    if command == 'help' or command == '?' then
        show_help()
    elseif command == 'history' then
        show_history()
    elseif command == 'show' or command == 'hide' then
        settings.visible = not settings.visible
        update_display()
    elseif command == 'melee' then
        settings.melee = not settings.melee
        update_display()
    elseif command == 'ranged' then
        settings.ranged = not settings.ranged
        update_display()
    elseif command == 'ws' then
        settings.ws = not settings.ws
        update_display()
    elseif command == 'reset' then
        damage_data = T{
            melee = T{
                crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
                non_crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
            },
            ranged = T{
                crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
                non_crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
            },
            ws = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
        }
        update_display()
    end
    config.save(settings, settings_file)
end)

windower.register_event('action', function(act)
    -- Update enemy data
    if act.actor_id == windower.ffxi.get_player().id then
        -- Player is attacking
        if act.targets and #act.targets > 0 then
            local tar = windower.ffxi.get_mob_by_id(act.targets[1].id)
            if tar then
                enemy_data.level = tar.level
                enemy_data.name = tar.name
            end
        end
    end
    
    local base_dmg = get_base_damage()
    local multiplier = get_multiplier()
    
    if act.category == 1 then -- Melee
        for _, target in ipairs(act.targets) do
            for _, action in ipairs(target.actions) do
                local hit_type
                if action.message == 1 then
                    hit_type = 'non_crit'
                elseif action.message == 67 then
                    hit_type = 'crit'
                end
                if hit_type then
                    local damage = action.param
                    local data = damage_data.melee[hit_type]
                    data.max_damage = math.max(data.max_damage, damage)
                    if damage > 0 then
                        data.min_damage = math.min(data.min_damage, damage)
                        data.count = data.count + 1
                        data.sum = data.sum + damage
                        data.avg = data.sum / data.count
                        data.pdif = calculate_pdif(data.avg, base_dmg, multiplier)
                    end
                end
            end
        end
    elseif act.category == 2 then -- Ranged
        for _, target in ipairs(act.targets) do
            for _, action in ipairs(target.actions) do
                local hit_type
                if action.message == 352 then
                    hit_type = 'non_crit'
                elseif action.message == 353 then
                    hit_type = 'crit'
                end
                
                if hit_type then
                    local damage = action.param
                    local data = damage_data.ranged[hit_type]
                    data.max_damage = math.max(data.max_damage, damage)
                    if damage > 0 then
                        data.min_damage = math.min(data.min_damage, damage)
                        data.count = data.count + 1
                        data.sum = data.sum + damage
                        data.avg = data.sum / data.count
                        data.pdif = calculate_pdif(data.avg, base_dmg, multiplier)
                    end
                end
            end
        end
    elseif act.category == 3 then -- WS
        for _, target in ipairs(act.targets) do
            for _, action in ipairs(target.actions) do
                if action.message == 185 or action.message == 197 then -- WS hit
                    local damage = action.param
                    damage_data.ws.max_damage = math.max(damage_data.ws.max_damage, damage)
                    if damage > 0 then
                        damage_data.ws.min_damage = math.min(damage_data.ws.min_damage, damage)
                        damage_data.ws.count = damage_data.ws.count + 1
                        damage_data.ws.sum = damage_data.ws.sum + damage
                        damage_data.ws.avg = damage_data.ws.sum / damage_data.ws.count
                        damage_data.ws.pdif = calculate_pdif(damage_data.ws.avg, base_dmg, multiplier)
                    end
                end
            end
        end
    end
    update_display()
end)

windower.register_event('target change', function(new_target)
    -- Check if the mob ID has actually changed
    if target and target == new_target then
        return
    end
    
    -- Deep copy function
    local function deep_copy(obj)
        local copy = T{}
        for k, v in pairs(obj) do
            if type(v) == 'table' then
                copy[k] = deep_copy(v)
            else
                copy[k] = v
            end
        end
        return copy
    end
    
    -- Check if current target had any damage data, and if so, save it to history
    if last_target_data then
        -- Check if any damage was actually recorded
        local has_damage = last_target_data.damage_data.melee.crit.count > 0 or 
                          last_target_data.damage_data.melee.non_crit.count > 0 or
                          last_target_data.damage_data.ranged.crit.count > 0 or
                          last_target_data.damage_data.ranged.non_crit.count > 0 or
                          last_target_data.damage_data.ws.count > 0
        
        if has_damage then
            table.insert(target_history, last_target_data)
            
            -- Keep only the last MAX_HISTORY entries
            if #target_history > MAX_HISTORY then
                table.remove(target_history, 1)
            end
        end
    end
    
    -- Switch to new target
    target = new_target
    if target then
        local tar = windower.ffxi.get_mob_by_id(target)
        if tar then
            enemy_data.level = tar.level
            enemy_data.name = tar.name
        end
    end
    
    -- Save current target info and prepare for next fight
    last_target_data = T{
        name = enemy_data.name,
        level = enemy_data.level,
        damage_data = deep_copy(damage_data)
    }
    
    -- Reset damage data for new target
    damage_data = T{
        melee = T{
            crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
            non_crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
        },
        ranged = T{
            crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
            non_crit = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
        },
        ws = T{ capped = false, pdif = 0, max_damage = 0, min_damage = 99999, count = 0, sum = 0, avg = 0 },
    }
    
    update_display()
end)
