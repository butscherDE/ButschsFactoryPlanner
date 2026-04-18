---@diagnostic disable

local migration = {}

function migration.player_table(player_table)
    for district in player_table.realm:iterator() do
        for factory in district:iterator() do
            local function iterate_floor(floor)
                if floor.extra_products == nil then
                    floor.extra_products = {}
                end
                for line in floor:iterator() do
                    if line.class == "Floor" then
                        iterate_floor(line)
                    end
                end
            end
            iterate_floor(factory.top_floor)
        end
    end
end

function migration.packed_factory(packed_factory)
    local function iterate_floor(packed_floor)
        if packed_floor.extra_products == nil then
            packed_floor.extra_products = {}
        end
        for _, packed_line in pairs(packed_floor.lines) do
            if packed_line.class == "Floor" then
                iterate_floor(packed_line)
            end
        end
    end
    iterate_floor(packed_factory.top_floor)
end

return migration
