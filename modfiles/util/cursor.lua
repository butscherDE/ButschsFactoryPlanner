local _cursor = {}

---@param player LuaPlayer
---@param text LocalisedString
function _cursor.create_flying_text(player, text)
    player.create_local_flying_text{text=text, create_at_cursor=true}
end


---@param player LuaPlayer
---@param blueprint_entities BlueprintEntity[]
local function set_cursor_blueprint(player, blueprint_entities)
    local script_inventory = game.create_inventory(1)
    local blank_slot = script_inventory[1]

    blank_slot.set_stack{name="blueprint"}
    blank_slot.set_blueprint_entities(blueprint_entities)
    player.clear_cursor()
    player.add_to_clipboard(blank_slot)
    player.activate_paste()
    script_inventory.destroy()
end


---@param object Machine | Beacon
---@return table items_list
local function build_module_items(object)
    local items_list, slot_index = {}, 0
    if object.class == "Beacon" or object.proto.effect_receiver.uses_module_effects then
        local inventory = defines.inventory[object.proto.prototype_category .. "_modules"]
        for module in object.module_set:iterator() do
            local inventory_list = {}
            for i = 1, module.amount do
                table.insert(inventory_list, {
                    inventory = inventory,
                    stack = slot_index
                })
                slot_index = slot_index + 1
            end

            table.insert(items_list, {
                id = {
                    name = module.proto.name,
                    quality = module.quality_proto.name
                },
                items = {
                    in_inventory = inventory_list
                }
            })
        end
    end
    return items_list
end


---@param player LuaPlayer
---@param line Line
---@param object Machine | Beacon
---@return boolean success
function _cursor.set_entity(player, line, object)
    local entity_prototype = prototypes.entity[object.proto.name]
    if entity_prototype.has_flag("not-blueprintable") or not entity_prototype.has_flag("player-creation")
            or not object.proto.built_by_item then
        _cursor.create_flying_text(player, {"fp.add_to_cursor_failed", entity_prototype.localised_name})
        return false
    end

    local items_list = build_module_items(object)

    -- Put item directly into the cursor if it's simple
    if #items_list == 0 and object.proto.prototype_category ~= "assembling_machine" then
        player.cursor_ghost = {
            name = object.proto.built_by_item.name,
            quality = object.quality_proto.name
        }
    else  -- if it's more complex, it needs a blueprint
        local blueprint_entity = {
            entity_number = 1,
            name = object.proto.name,
            position = {0, 0},
            quality = object.quality_proto.name,
            items = items_list,
            recipe = (object.class == "Machine") and line.recipe.proto.name or nil
        }
        set_cursor_blueprint(player, {blueprint_entity})
    end

    return true
end


-- Returns the best available electric pole prototype
---@return LuaEntityPrototype?
local function get_electric_pole()
    local priority = {"medium-electric-pole", "small-electric-pole", "big-electric-pole"}
    for _, name in ipairs(priority) do
        local proto = prototypes.entity[name]
        if proto and not proto.has_flag("not-blueprintable") and proto.has_flag("player-creation") then
            return proto
        end
    end
    return nil
end

-- Returns the fastest non-long-range inserter prototype available
---@return LuaEntityPrototype
local function get_fastest_inserter()
    -- Priority order: fastest to slowest for standard-range inserters in vanilla Factorio 2.0
    local priority = {"bulk-inserter", "fast-inserter", "inserter"}
    for _, name in ipairs(priority) do
        local proto = prototypes.entity[name]
        if proto and not proto.has_flag("not-blueprintable") and proto.has_flag("player-creation") then
            return proto
        end
    end

    -- Fallback: find any blueprintable short-range inserter
    local inserter_protos = prototypes.get_entity_filtered({{filter="type", type="inserter"}})
    for _, proto in pairs(inserter_protos) do
        if not proto.has_flag("not-blueprintable") and proto.has_flag("player-creation") then
            local pickup = proto.inserter_pickup_position
            if pickup then
                local px = pickup.x or pickup[1] or 0
                local py = pickup.y or pickup[2] or 0
                if (math.abs(px) + math.abs(py)) <= 1.5 then
                    return proto
                end
            end
        end
    end
    return nil
end

-- Builds a constant-combinator blueprint entity with the given item signals
---@param entity_num integer
---@param x number
---@param y number
---@param signals table[] array of {type, name, count}
---@return table blueprint_entity
local function build_combinator_entity(entity_num, x, y, signals)
    local filters = {}
    for i, sig in ipairs(signals) do
        filters[i] = {
            index = i,
            type = sig.type,
            name = sig.name,
            quality = "normal",
            comparator = "=",
            count = math.min(math.max(math.ceil(sig.count), 1), 2^31 - 1)
        }
    end

    return {
        entity_number = entity_num,
        name = "constant-combinator",
        position = {x, y},
        control_behavior = {
            sections = {
                sections = {
                    {index = 1, filters = filters}
                }
            }
        }
    }
end


---@param player LuaPlayer
---@param line Line
---@return boolean success
function _cursor.set_line_blueprint(player, line)
    -- Validation
    if line.production_ratio <= 0 then
        _cursor.create_flying_text(player, {"fp.generate_blueprint_no_production"})
        return false
    end

    local machine = line.machine
    local entity_prototype = prototypes.entity[machine.proto.name]
    if entity_prototype.has_flag("not-blueprintable") or not entity_prototype.has_flag("player-creation") then
        _cursor.create_flying_text(player, {"fp.generate_blueprint_failed", entity_prototype.localised_name})
        return false
    end

    -- Gather prototypes
    local belt_default = defaults.get(player, "belts")
    local belt_name = belt_default.proto.name
    local inserter_proto = get_fastest_inserter()
    if not inserter_proto then
        _cursor.create_flying_text(player, {"fp.generate_blueprint_failed", "inserter"})
        return false
    end

    local pole_proto = get_electric_pole()
    local pole_name = pole_proto and pole_proto.name or nil
    local timescale = util.globals.preferences(player).timescale

    -- Machine dimensions
    local mw = entity_prototype.tile_width
    local mh = entity_prototype.tile_height
    local machine_count = math.ceil(machine.amount)
    if machine_count < 1 then machine_count = 1 end

    -- Calculate lane requirements based on belt throughput
    local belt_entity = prototypes.entity[belt_name]
    -- belt_speed * 480 = full belt throughput; divide by 2 for per-lane capacity
    local lane_capacity = belt_entity.belt_speed * 480 / 2

    local lane_slots = {}  -- {name, type, throughput, lanes, throughput_per_lane}
    for _, ingredient in pairs(line.ingredients) do
        if ingredient.proto.type == "item" then
            local throughput = ingredient.amount  -- total items/s for all machines
            local lanes = math.max(1, math.ceil(throughput / lane_capacity - 1e-6))
            table.insert(lane_slots, {
                name = ingredient.proto.base_name or ingredient.proto.name,
                type = "item",
                throughput = throughput,
                lanes = lanes,
                throughput_per_lane = throughput / lanes
            })
        end
    end

    local total_lanes = 0
    for _, slot in ipairs(lane_slots) do
        total_lanes = total_lanes + slot.lanes
    end

    if total_lanes > 4 or total_lanes == 0 then
        if total_lanes > 4 then
            _cursor.create_flying_text(player, {"fp.generate_blueprint_too_many_ingredients"})
        end
        if total_lanes == 0 then
            -- No item ingredients but still generate machines + output
        end
        if total_lanes > 4 then return false end
    end

    local num_belts = (total_lanes <= 2) and 1 or 2

    -- Assign items to belt lanes
    -- Sort by lanes needed (descending) for best-fit packing
    table.sort(lane_slots, function(a, b) return a.lanes > b.lanes end)

    -- belt_items[belt_idx] = list of {name, type, throughput_per_lane}
    local belt_items = {{}, {}}
    local belt_remaining = {2, num_belts == 2 and 2 or 0}

    for _, slot in ipairs(lane_slots) do
        local remaining = slot.lanes
        for belt_idx = 1, num_belts do
            local can_add = math.min(remaining, belt_remaining[belt_idx])
            for i = 1, can_add do
                table.insert(belt_items[belt_idx], {
                    name = slot.name, type = slot.type,
                    throughput = slot.throughput_per_lane
                })
            end
            belt_remaining[belt_idx] = belt_remaining[belt_idx] - can_add
            remaining = remaining - can_add
            if remaining == 0 then break end
        end
    end

    -- Determine which belts need sideloading (2 different items on same belt)
    local function belt_needs_sideload(items)
        if #items ~= 2 then return false end
        return items[1].name ~= items[2].name
    end

    local sideload_0 = belt_needs_sideload(belt_items[1])
    local sideload_1 = belt_needs_sideload(belt_items[2])
    local both_sideload = sideload_0 and sideload_1

    -- Layout positions depend on belt configuration
    local x_belt_0, x_belt_1, x_ins, x_mc, x_out_ins, x_out_belt

    if num_belts == 1 then
        x_belt_0 = 0
        x_ins = 1
        x_mc = 2 + math.floor((mw - 1) / 2)
        x_out_ins = 2 + mw
        x_out_belt = 2 + mw + 1
    else
        -- 2 belts: shift right if both need sideloading
        local shift = both_sideload and 2 or 0
        x_belt_0 = shift
        x_belt_1 = shift + 1
        x_ins = shift + 2  -- both inserters at this x
        x_mc = shift + 3 + math.floor((mw - 1) / 2)
        x_out_ins = shift + 3 + mw
        x_out_belt = shift + 3 + mw + 1
    end

    -- Machine center x (half-tile for even width)
    local x_machine_center = (mw % 2 == 0) and (x_mc + 0.5) or x_mc

    -- Vertical layout
    local block_size = mh + 1  -- machine tiles + 1 pole gap
    local y_belt_start = 0
    local y_belt_end = (machine_count - 1) * block_size + mh - 1

    local entities = {}
    local entity_num = 0
    local function next_num()
        entity_num = entity_num + 1
        return entity_num
    end

    -- === INPUT BELTS (going north) ===
    for y = y_belt_start, y_belt_end do
        if #belt_items[1] > 0 then
            table.insert(entities, {
                entity_number = next_num(), name = belt_name,
                position = {x_belt_0, y}, direction = defines.direction.north
            })
        end
        if num_belts == 2 and #belt_items[2] > 0 then
            table.insert(entities, {
                entity_number = next_num(), name = belt_name,
                position = {x_belt_1, y}, direction = defines.direction.north
            })
        end
    end

    -- === MACHINES + INSERTERS + POLES ===
    local items_list = build_module_items(machine)
    for i = 0, machine_count - 1 do
        local block_y = i * block_size
        local y_mc = block_y + (mh - 1) / 2
        local y_ins = block_y + math.floor(mh / 2)

        if num_belts == 1 then
            -- Single inserter picks from belt_0
            table.insert(entities, {
                entity_number = next_num(), name = inserter_proto.name,
                position = {x_ins, y_ins}, direction = defines.direction.west
            })
        else
            -- Long-handed inserter for far belt (belt_0), one row above center
            local y_lh = block_y + math.max(0, math.floor(mh / 2) - 1)
            table.insert(entities, {
                entity_number = next_num(), name = "long-handed-inserter",
                position = {x_ins, y_lh}, direction = defines.direction.west
            })
            -- Fast/bulk inserter for near belt (belt_1)
            table.insert(entities, {
                entity_number = next_num(), name = inserter_proto.name,
                position = {x_ins, y_ins}, direction = defines.direction.west
            })
        end

        -- Machine
        table.insert(entities, {
            entity_number = next_num(), name = machine.proto.name,
            position = {x_machine_center, y_mc},
            quality = machine.quality_proto.name,
            recipe = line.recipe.proto.name, items = items_list
        })

        -- Output inserter
        table.insert(entities, {
            entity_number = next_num(), name = inserter_proto.name,
            position = {x_out_ins, y_ins}, direction = defines.direction.west
        })

        -- Electric pole in gap
        if pole_name and i < machine_count - 1 then
            table.insert(entities, {
                entity_number = next_num(), name = pole_name,
                position = {x_mc, block_y + mh}
            })
        end
    end

    -- Trailing pole
    if pole_name then
        table.insert(entities, {
            entity_number = next_num(), name = pole_name,
            position = {x_mc, (machine_count - 1) * block_size + mh}
        })
    end

    -- === OUTPUT BELT (going south) ===
    for y = y_belt_start, y_belt_end do
        table.insert(entities, {
            entity_number = next_num(), name = belt_name,
            position = {x_out_belt, y}, direction = defines.direction.south
        })
    end

    -- === SIDELOAD STRUCTURES + CCs AT BOTTOM ===
    -- Helper to generate a sideload merge + turn + CCs for one belt
    local function add_sideload(belt_x, items, y_start)
        -- items = {{name, type, throughput}, {name, type, throughput}}
        -- Sideload merge: > ^ < centered one column away from the belt
        -- Then a turn row connecting to the belt

        -- For belt_0 (left): sideload center is at belt_x - 1
        -- For belt_1 (right): sideload center is at belt_x + 2 (or further)
        local sl_center, turn_dir, turn_tiles

        if belt_x == x_belt_0 then
            -- Sideload to the left of belt
            sl_center = belt_x - 1
            -- Turn: sl_center east to belt_x (1 tile)
            turn_dir = defines.direction.east
            turn_tiles = {{sl_center, y_start}}
        else
            -- Sideload to the right of belt (belt_1)
            if both_sideload then
                sl_center = belt_x + 2
                -- Turn: sl_center west through intermediate tiles to belt
                turn_dir = defines.direction.west
                turn_tiles = {}
                for tx = sl_center, belt_x + 1, -1 do
                    table.insert(turn_tiles, {tx, y_start})
                end
            else
                sl_center = belt_x + 2
                turn_dir = defines.direction.west
                turn_tiles = {}
                for tx = sl_center, belt_x + 1, -1 do
                    table.insert(turn_tiles, {tx, y_start})
                end
            end
        end

        local y_sl = y_start + 1  -- sideload merge row
        local y_cc = y_start + 2  -- CC row

        -- Turn row: belts connecting sideload column to belt column
        for _, pos in ipairs(turn_tiles) do
            table.insert(entities, {
                entity_number = next_num(), name = belt_name,
                position = {pos[1], pos[2]}, direction = turn_dir
            })
        end

        -- Extend input belt to the turn row only (not sideload row, to avoid overlapping
        -- with sideload tiles when sl_center±1 == belt_x)
        table.insert(entities, {
            entity_number = next_num(), name = belt_name,
            position = {belt_x, y_start}, direction = defines.direction.north
        })

        -- Sideload merge: > ^ <
        table.insert(entities, {
            entity_number = next_num(), name = belt_name,
            position = {sl_center - 1, y_sl}, direction = defines.direction.east
        })
        table.insert(entities, {
            entity_number = next_num(), name = belt_name,
            position = {sl_center, y_sl}, direction = defines.direction.north
        })
        table.insert(entities, {
            entity_number = next_num(), name = belt_name,
            position = {sl_center + 1, y_sl}, direction = defines.direction.west
        })

        -- CCs below sideload
        table.insert(entities, build_combinator_entity(next_num(), sl_center - 1, y_cc,
            {{type=items[1].type, name=items[1].name,
              count=items[1].throughput * timescale}}))
        table.insert(entities, build_combinator_entity(next_num(), sl_center + 1, y_cc,
            {{type=items[2].type, name=items[2].name,
              count=items[2].throughput * timescale}}))

        return y_cc  -- return last y used
    end

    -- Helper to add a simple CC below a belt (no sideload)
    local function add_belt_cc(belt_x, items, y_pos)
        local signals = {}
        for _, item in ipairs(items) do
            table.insert(signals, {
                type = item.type, name = item.name,
                count = item.throughput * timescale
            })
        end
        table.insert(entities, build_combinator_entity(next_num(), belt_x, y_pos, signals))
    end

    -- Generate sideload/CC structures for input belts
    local y_bottom = y_belt_end + 1

    if num_belts == 1 then
        if #belt_items[1] == 2 and sideload_0 then
            -- Sideload directly on belt (no turn needed)
            local y_sl = y_bottom
            local y_cc = y_bottom + 1

            -- Extend belt through sideload
            table.insert(entities, {
                entity_number = next_num(), name = belt_name,
                position = {x_belt_0, y_sl}, direction = defines.direction.north
            })

            -- Sideload: > ^ <
            table.insert(entities, {
                entity_number = next_num(), name = belt_name,
                position = {x_belt_0 - 1, y_sl}, direction = defines.direction.east
            })
            table.insert(entities, {
                entity_number = next_num(), name = belt_name,
                position = {x_belt_0 + 1, y_sl}, direction = defines.direction.west
            })

            -- CCs
            table.insert(entities, build_combinator_entity(next_num(), x_belt_0 - 1, y_cc,
                {{type=belt_items[1][1].type, name=belt_items[1][1].name,
                  count=belt_items[1][1].throughput * timescale}}))
            table.insert(entities, build_combinator_entity(next_num(), x_belt_0 + 1, y_cc,
                {{type=belt_items[1][2].type, name=belt_items[1][2].name,
                  count=belt_items[1][2].throughput * timescale}}))
        elseif #belt_items[1] > 0 then
            add_belt_cc(x_belt_0, belt_items[1], y_bottom)
        end
    else
        -- 2-belt layout
        local max_y = y_bottom

        if sideload_0 then
            local y_used = add_sideload(x_belt_0, belt_items[1], y_bottom)
            max_y = math.max(max_y, y_used)
        elseif #belt_items[1] > 0 then
            add_belt_cc(x_belt_0, belt_items[1], y_bottom)
        end

        if sideload_1 then
            local y_used = add_sideload(x_belt_1, belt_items[2], y_bottom)
            max_y = math.max(max_y, y_used)
        elseif #belt_items[2] > 0 then
            add_belt_cc(x_belt_1, belt_items[2], y_bottom)
        end
    end

    -- Output product CC
    local product_signals = {}
    for _, product in pairs(line.products) do
        if product.proto.type ~= "entity" then
            local name = product.proto.base_name or product.proto.name
            table.insert(product_signals, {
                type = product.proto.type, name = name,
                count = product.amount * timescale
            })
        end
    end
    if #product_signals > 0 then
        table.insert(entities, build_combinator_entity(next_num(), x_out_belt, y_bottom, product_signals))
    end

    set_cursor_blueprint(player, entities)
    return true
end


---@param player LuaPlayer
---@param item_filters LogisticFilter[]
function _cursor.set_item_combinator(player, item_filters)
    local slot_index = 1
    for _, filter in pairs(item_filters) do
        -- make sure amounts < 1 are not excluded, and the int32 limit is not exceeded
        filter.count = math.min(math.max(filter.count, 1), 2^31 - 1)
        filter.index = slot_index
        slot_index = slot_index + 1
    end

    local blueprint_entity = {
        entity_number = 1,
        name = "constant-combinator",
        position = {0, 0},
        control_behavior = {
            sections = {
                sections = {
                    {
                        index = 1,
                        filters = item_filters
                    }
                }
            }
        }
    }

    set_cursor_blueprint(player, {blueprint_entity})
end


---@param player LuaPlayer
---@param blueprint_entity BlueprintEntity
---@param item_proto FPItemPrototype | FPFuelPrototype
---@param amount number
local function add_to_item_combinator(player, blueprint_entity, item_proto, amount)
    local timescale = util.globals.preferences(player).timescale
    local item_signals, filter_matched = {}, false
    local item_name = item_proto.base_name or item_proto.name

    do
        if not blueprint_entity then goto skip_cursor end
        if not blueprint_entity.name == "constant-combinator" then goto skip_cursor end

        local sections = blueprint_entity.control_behavior.sections
        if not (sections and sections.sections and #sections.sections == 1) then goto skip_cursor end

        local section = sections.sections[1]
        if section.group then goto skip_cursor end

        for _, filter in pairs(section.filters) do
            if item_proto.type == (filter.type or "item") and item_name == filter.name then
                filter.count = filter.count + (amount * timescale)
                filter_matched = true
            end
            table.insert(item_signals, filter)
        end

        ::skip_cursor::
    end

    if not filter_matched then
        table.insert(item_signals, {
            type = item_proto.type,
            name = item_name,
            quality = "normal",
            comparator = "=",
            count = math.ceil(amount * timescale - 1e-6)
        })
    end

    _cursor.set_item_combinator(player, item_signals)
end

---@param player LuaPlayer
---@param cursor_entity CursorEntityData
---@param item_proto FPItemPrototype
local function set_filter_on_inserter(player, cursor_entity, item_proto)
    local entity_proto = (cursor_entity.type == "entity") and cursor_entity.entity
        or prototypes.entity[cursor_entity.entity.name]

    if item_proto.type == "fluid" then
        _cursor.create_flying_text(player, {"fp.inserter_only_filters_items"})
        return
    end

    if not entity_proto.filter_count then
        _cursor.create_flying_text(player, {"fp.inserter_has_no_filters"})
        return
    end

    local new_filter = {
        index = 1,
        name = item_proto.name,
        quality = "normal",
        comparator = "="
    }

    if cursor_entity.type == "blueprint" then
        local blueprint_entity = cursor_entity.entity

        local filter_count = #blueprint_entity.filters
        if filter_count == entity_proto.filter_count then
            _cursor.create_flying_text(player, {"fp.inserter_filter_limit_reached"})
        else
            -- Silently drop any duplicates
            for _, filter in pairs(blueprint_entity.filters) do
                if filter.name == item_proto.name then return end
            end

            new_filter.index = filter_count + 1
            table.insert(blueprint_entity.filters, new_filter)
            set_cursor_blueprint(player, {blueprint_entity})
        end
    else
        set_cursor_blueprint(player, {
            {
                entity_number = 1,
                name = entity_proto.name,
                position = {0, 0},
                quality = cursor_entity.quality,
                use_filters = true,
                filters = { new_filter }
            }
        })
    end
end


---@param player LuaPlayer
---@return LuaItemPrototype
function _cursor.parse_cursor_item(player)
    if player.is_cursor_empty() then return nil end

    local cursor = player.cursor_stack  --[[@cast cursor -nil]]
    local valid_for_read, cursor_ghost = cursor.valid_for_read, player.cursor_ghost
    local prototype = (valid_for_read) and cursor.prototype or cursor_ghost.name

    return prototype
end


---@alias CursorEntityType "none" | "blueprint" | "entity"
---@alias CursorEntity BlueprintEntity | LuaEntityPrototype
---@alias CursorEntityData { type: CursorEntityType, entity: CursorEntity?, quality: string? }

---@param player LuaPlayer
---@return CursorEntityData? cursor_entity
local function parse_cursor_entity(player)
    local no_entity = {type="none", entity=nil, quality=nil}

    if player.is_cursor_empty() then return no_entity end
    local cursor = player.cursor_stack  --[[@cast cursor -nil]]

    if cursor.is_blueprint and cursor.is_blueprint_setup() then
        local entities = cursor.get_blueprint_entities()
        if not (entities and #entities == 1) then return no_entity end
        return {type="blueprint", entity=entities[1], quality=entities[1].quality}
    else
        local valid_for_read, cursor_ghost = cursor.valid_for_read, player.cursor_ghost
        local prototype = (valid_for_read) and cursor.prototype or cursor_ghost.name

        local place_result = prototype.place_result
        if not place_result then return no_entity end

        local quality = (valid_for_read) and cursor.quality.name or cursor_ghost.quality.name
        return {type="entity", entity=place_result, quality=quality}
    end
end

---@param player LuaPlayer
---@param item_proto FPItemPrototype | FPFuelPrototype
---@param amount number
function _cursor.handle_item_click(player, item_proto, amount)
    local cursor_entity = parse_cursor_entity(player)

    if cursor_entity.type == "entity" and cursor_entity.entity.type == "inserter" then
        set_filter_on_inserter(player, cursor_entity, item_proto)

    elseif cursor_entity.type == "blueprint" then
        local entity_proto = prototypes.entity[cursor_entity.entity.name]
        if entity_proto.type == "inserter" then
            set_filter_on_inserter(player, cursor_entity, item_proto)
        else
            add_to_item_combinator(player, cursor_entity.entity, item_proto, amount)
        end
    else
        add_to_item_combinator(player, nil, item_proto, amount)
    end
end

return _cursor
