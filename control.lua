local const = require("scripts/constants")
local utils = require("scripts/utils")
local highlight_entity = require("scripts/highlight")
local get_belt_type = utils.get_belt_type
local connectables = const.connectables
local lane_cycle = const.lane_cycle
local side_cycle = const.side_cycle
local e = defines.events

local function setup_globals()
    global.data = {}
    global.in_progress = {}
    global.refresh = {}
    global.belt_lines = {}
    global.hover = global.hover or {}
end

script.on_init(function()
    setup_globals()
end)

script.on_configuration_changed(function(_)
    rendering.clear("belt-visualizer")
    setup_globals()
end)

local function clear(index)
    global.in_progress[index] = nil
    global.refresh[index] = nil
    local data = global.data[index]
    if not data then return end
    data.checked = nil
    data.belt_line = nil
    for id in pairs(data.ids) do
        if rendering.is_valid(id) then
            rendering.destroy(id)
        end
    end
end

local function remove_player(event)
    local index = event.player_index
    clear(index)
    global.data[index] = nil
    global.belt_lines[index] = nil
    global.hover[index] = nil
end

script.on_event(e.on_player_left_game, remove_player)
script.on_event(e.on_player_removed, remove_player)

local function highlight(event)
    local index = event.player_index
    clear(index)
    local player = game.get_player(index) --[[@as LuaPlayer]]
    local selected = player.selected
    if not selected then return end
    local ghost = event.input_name ~= nil and event.input_name == "bv-highlight-ghost"
    local type = selected.type
    if type == "entity-ghost" then
        if ghost then
            type = selected.ghost_type
        else return end
    end
    if not connectables[type] then return end
    local data = global.data[index] or {}
    global.data[index] = data
    local unit_number = selected.unit_number --[[@as number]]
    local filter = not player.is_cursor_empty() and player.cursor_stack.valid_for_read and player.cursor_stack.name
    if data.ghost == ghost and data.filter == filter and data.origin.valid and data.origin.unit_number == unit_number then
        data.cycle = data.cycle % 3 + 1
    else
        data.cycle = 1
    end
    data.index = index
    data.ghost = ghost
    data.filter = filter
    data.origin = selected
    data.drawn_offsets = {}
    data.drawn_arcs = {}
    data.checked = {[unit_number] = utils.empty_check(type)}
    data.belt_line = {}
    data.head = selected
    data.tail = selected
    data.next_entities = {}
    local lanes = lane_cycle[data.cycle]
    for path = 1, 2 do
        data.next_entities[path] = {entity = selected, lanes = lanes, path = path}
        local sides = type == "splitter" and side_cycle.both
        for lane in pairs(lanes) do
            utils.check_entity(data, unit_number, lane, path, sides)
        end
    end
    data.ids = {}
    global.in_progress[index] = true
end

local function refresh(data)
    clear(data.index)
    local entity = data.origin
    if not entity.valid then return end
    data.next_entities = {}
    for i = 1, 2 do
        data.next_entities[i] = {entity = entity, lanes = lane_cycle[data.cycle], path = i}
    end
    data.drawn_offsets = {}
    data.drawn_arcs = {}
    data.checked = {[entity.unit_number] = utils.empty_check(entity.type)}
    data.belt_line = {}
    data.head = entity
    data.tail = entity
    data.ids = {}
    global.in_progress[data.index] = true
end

script.on_event("bv-highlight-belt", highlight)
-- script.on_event("bv-highlight-ghost", highlight)

script.on_event(e.on_selected_entity_changed, function(event)
    if not global.hover[event.player_index] then return end
    local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
    local data = global.data[event.player_index]
    local selected = player.selected --[[@as LuaEntity]]
    local is_connectable = selected and connectables[get_belt_type(selected)]
    local belt_line = data and data.belt_line
    if is_connectable and belt_line and belt_line[selected.unit_number] then
        data.origin = player.selected
        return
    end
    highlight(event)
end)

local function toggle_hover(event)
    local index = event.player_index
    clear(index)
    local player = game.get_player(index) --[[@as LuaPlayer]]
    global.hover[index] = not global.hover[index]
    player.set_shortcut_toggled("bv-toggle-hover", global.hover[index])
end

script.on_event("bv-toggle-hover", toggle_hover)
script.on_event(e.on_lua_shortcut, function(event)
    if event.prototype_name ~= "bv-toggle-hover" then return end
    toggle_hover(event)
end)

local function highlightable(data, entity)
    local checked = data.checked
    if not checked then return false end
    if checked[entity.unit_number] then return true end
    for _, input in pairs(entity.belt_neighbours.inputs) do
        if checked[input.unit_number] then return true end
    end
    for _, output in pairs(entity.belt_neighbours.outputs) do
        if checked[output.unit_number] then return true end
    end
    if entity.type == "underground-belt" then
        local neighbours = entity.neighbours
        if neighbours and checked[neighbours.unit_number] then return true end
    elseif entity.type == "linked-belt" then
        local neighbours = entity.linked_belt_neighbours
        if neighbours and checked[neighbours.unit_number] then return true end
    end
    return false
end

local function on_entity_modified(event)
    local entity = event.entity or event.created_entity or event.destination
    for _, data in pairs(global.data) do
        if highlightable(data, entity) then
            if not global.refresh[data.index] then
                global.refresh[data.index] = event.tick + 60
            end
        end
    end
end

local filter = {{filter = "transport-belt-connectable"}}

script.on_event(e.on_built_entity, on_entity_modified, filter)
script.on_event(e.on_robot_built_entity, on_entity_modified, filter)
script.on_event(e.on_entity_cloned, on_entity_modified, filter)
script.on_event(e.script_raised_built, on_entity_modified, filter)
script.on_event(e.script_raised_revive, on_entity_modified, filter)
script.on_event(e.on_player_mined_entity, on_entity_modified, filter)
script.on_event(e.on_robot_mined_entity, on_entity_modified, filter)
script.on_event(e.script_raised_destroy, on_entity_modified, filter)
script.on_event(e.on_entity_died, on_entity_modified, filter)

script.on_event(e.on_player_rotated_entity, function(event)
    if not connectables[event.entity.type] then return end
    on_entity_modified(event)
    local entity = event.entity
    local neighbours = entity.type == "underground-belt" and entity.neighbours or entity.type == "linked-belt" and entity.linked_belt_neighbour
    if neighbours then on_entity_modified{entity = neighbours, tick = event.tick} end
end)

---@param t table
---@param case any
local function switch(t, case, ...)
    if t[case] then
        return t[case](...)
    end
end

---@type table<string, fun(entity: LuaEntity): LuaEntity?>
local next_connectable = {
    ["transport-belt"] = function(entity)
        return entity.belt_neighbours.outputs[1]
    end,
    ["underground-belt"] = function(entity)
        if entity.belt_to_ground_type == "input" then
            return entity.neighbours
        else
            return entity.belt_neighbours.outputs[1]
        end
    end,
    ["linked-belt"] = function(entity)
        if entity.linked_belt_type == "input" then
            return entity.linked_belt_neighbour
        else
            return entity.belt_neighbours.outputs[1]
        end
    end,
}

---@type table<string, fun(entity: LuaEntity): LuaEntity?>
local previous_connectable = {
    ["transport-belt"] = function(entity)
        return entity.belt_neighbours.inputs[1]
    end,
    ["underground-belt"] = function(entity)
        if entity.belt_to_ground_type == "output" then
            return entity.neighbours
        else
            return entity.belt_neighbours.inputs[1]
        end
    end,
    ["linked-belt"] = function(entity)
        if entity.linked_belt_type == "output" then
            return entity.linked_belt_neighbour
        else
            return entity.belt_neighbours.inputs[1]
        end
    end,
}

local function cache_belt_line(data, max_highlights)
    local head, tail = data.head, data.tail
    if not (head or tail) then return end
    local belt_line = data.belt_line
    if head then
        local belt_type = get_belt_type(head)
        local c = 0
        while c < max_highlights do
            head = switch(next_connectable, belt_type, head)
            if not head then break end
            belt_type = get_belt_type(head)
            if belt_type == "splitter" then
                head = nil
                break
            end
            local limit = 1
            if belt_type == "underground-belt" and head.belt_to_ground_type == "output" then
                limit = 0
            elseif belt_type == "linked-belt" and head.linked_belt_type == "output" then
                limit = 0
            end
            if #head.belt_neighbours.inputs <= limit then
                belt_line[head.unit_number] = true
            else
                head = nil
                break
            end
            c = c + 1
        end
        data.head = head
    end
    if tail then
        local c = 0
        while c < max_highlights do
            if not tail then break end
            belt_type = get_belt_type(tail)
            if belt_type == "splitter" then
                tail = nil
                break
            end
            belt_line[tail.unit_number] = true
            local limit = 1
            if belt_type == "underground-belt" and tail.belt_to_ground_type == "output" then
                limit = 0
            elseif belt_type == "linked-belt" and tail.linked_belt_type == "output" then
                limit = 0
            end
            if #tail.belt_neighbours.inputs <= limit then
                tail = switch(previous_connectable, belt_type, tail)
            else
                tail = nil
                break
            end
            c = c + 1
        end
        data.tail = tail
    end
end

script.on_event(e.on_tick, function(event)
    for index, tick in pairs(global.refresh) do
        if tick == event.tick then
            refresh(global.data[index])
            global.refresh[index] = nil
        end
    end
    local player_count = table_size(global.in_progress)
    local max_highlights = settings.global["bv-highlight-maximum"].value / player_count
    for index in pairs(global.in_progress) do
        local data = global.data[index]
        cache_belt_line(data, max_highlights)
        local c = 0
        while c < max_highlights do
            local i, next_data = next(data.next_entities)
            if not i then break end
            local entity = next_data.entity
            if entity.valid then
                highlight_entity[get_belt_type(entity)](data, next_data.entity, next_data.lanes, next_data.path)
                c = c + 1
            end
            table.remove(data.next_entities, i) -- optimize to insert last element in hole?
        end
        if not next(data.next_entities) then global.in_progress[data.index] = nil end
    end
end)