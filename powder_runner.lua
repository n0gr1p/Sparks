-- Unity Prize Powder purchases for city Unity Concord NPCs.
-- Separate from the Sparks gil runner: Unity exchanges require a three-step
-- event dialogue, not Sparks' single 0x05B purchase.
--
-- Interaction steps based on Windower UnityNPC:
-- NPC 0x034 -> 0x05B option 10 -> 0x05C -> 0x05B option (12*32+3)
-- -> 0x05C -> 0x05B quantity option -> Inventory confirmation.
-- An unconfirmed state-changing request is NEVER resent.
local Runner = {}
Runner.__index = Runner

local POWDER_ID = 5945
local ITEM_INDEX = 12
local COST = 10
local STACK_SIZE = 99
local MAX_MENU_ATTEMPTS = 3
local MENU_TIMEOUT = 5
local STEP_TIMEOUT = 5
local DELIVERY_TIMEOUT = 10
local RETRY_DELAY = 2
local PURCHASE_DELAY = 2

-- Unity NPCs and their active member event IDs (not Sparks NPCs).
-- In Windurst Woods either Unity NPC may be used.
local UNITY_ZONES = {
    [230] = { menu = 3529, names = { ['Urbiolaine'] = true } },
    [235] = { menu = 598, names = { ['Igsli'] = true } },
    [241] = { menu = 879, names = { ['Teldro-Kesdrodo'] = true, ['Yonolala'] = true } },
    [256] = { menu = 5149, names = { ['Nunaarl Bthtrogg'] = true } },
}

local function uint32_le(data, first)
    if type(data) ~= 'string' or #data < first + 3 then
        return nil
    end
    local a, b, c, d = string.byte(data, first, first + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

function Runner.new(deps)
    return setmetatable({
        windower = assert(deps.windower),
        packets = assert(deps.packets),
        log = assert(deps.log),
        clock = deps.clock or os.time,
        on_finish = deps.on_finish,
        active = false,
        phase = 'idle',
        total = 0,
        requested = nil,
        last_result = 'not started',
    }, Runner)
end

function Runner:is_active()
    return self.active
end

function Runner:_say(message, color)
    self.log('[Sparks powder] ' .. message, color or 8)
end

function Runner:_stock()
    local ok, data = pcall(self.windower.ffxi.get_items)
    if not ok or type(data) ~= 'table' or type(data.inventory) ~= 'table' then
        return nil
    end
    local inv = data.inventory
    if type(inv.max) ~= 'number' or type(inv.count) ~= 'number' then
        return nil
    end

    local count = 0
    local room = math.max(0, inv.max - inv.count) * STACK_SIZE
    for slot = 1, inv.max do
        local entry = inv[slot]
        if type(entry) == 'table' and entry.id == POWDER_ID then
            local stack = entry.count or 1
            if stack < 1 or stack > STACK_SIZE then
                return nil
            end
            count = count + stack
            room = room + STACK_SIZE - stack
        end
    end
    return count, room
end

function Runner:_find_npc()
    local info = self.windower.ffxi.get_info()
    local zone = info and info.zone
    local spec = UNITY_ZONES[zone]
    if not spec then return nil end

    local closest
    for key, mob in pairs(self.windower.ffxi.get_mob_array() or {}) do
        if mob and spec.names[mob.name] and type(mob.distance) == 'number'
            and mob.distance < 36 and mob.id then
            local idx = mob.index or key
            if type(idx) == 'number' and (not closest or mob.distance < closest.distance) then
                closest = { id = mob.id, index = idx, distance = mob.distance,
                    zone = zone, expected_menu = spec.menu, name = mob.name }
            end
        end
    end
    return closest
end

function Runner:_local_release(menu_id)
    local inject = self.windower.packets and self.windower.packets.inject_incoming
    if not inject then return end

    pcall(inject, 0x052, string.char(0, 0, 0, 0, 0, 0, 0, 0))
    if menu_id then
        local lo, hi = menu_id % 256, math.floor(menu_id / 256) % 256
        pcall(inject, 0x052, string.char(0, 0, 0, 0, 2, lo, hi, 0))
    end
    pcall(inject, 0x052, string.char(0, 0, 0, 0, 1, 0, 0, 0))
end

function Runner:_respond(option, unknown1, automated)
    local target = self.target
    local response = self.packets.new('outgoing', 0x05B, {
        ['Target'] = target.id,
        ['Target Index'] = target.index,
        ['Zone'] = target.zone,
        ['Menu ID'] = self.menu_id,
        ['Option Index'] = option,
        ['_unknown1'] = unknown1 or 0,
        ['Automated Message'] = automated == true,
        ['_unknown2'] = 0,
    })
    self.packets.inject(response)
end

function Runner:_release()
    if self.menu_id and not self.menu_closed and self.target then
        local ok = pcall(self._respond, self, 0, 16384, false)
        if ok then self.menu_closed = true end
    end
    if self.menu_id or self.attempts > 0 then
        self:_local_release(self.menu_id)
    end
end

function Runner:_finish(reason, successful)
    if not self.active then return end
    self:_release()
    self.active = false
    self.phase = 'idle'
    self.last_result = reason
    if self.on_finish then self.on_finish(successful == true) end
    self:_say(reason .. ' (' .. tostring(self.total) .. ' Prize Powder confirmed).',
        successful and 8 or 2)
end

function Runner:cancel()
    if self.active then
        self:_finish('Cancelled; releasing Unity NPC menu', false)
    else
        self:_say('Not running. Last result: ' .. self.last_result)
    end
end

function Runner:status()
    if self.active then
        local limit = self.requested and ('/' .. self.requested) or ''
        self:_say(string.format('Running: %d%s powder confirmed, phase=%s, attempts=%d.',
            self.total, limit, self.phase, self.attempts))
    else
        self:_say('Idle. Last result: ' .. self.last_result)
    end
end

-- Return nil unless the Unity NPC provided the expected 0x034 member menu
-- with valid 32-byte event parameters. Read from the event's third and fourth
-- arguments, the accolades and remaining weekly exchange allowance.
function Runner:_read_funds(id, packet)
    if id ~= 0x034 or type(packet) ~= 'table' then return nil end
    local params = packet['Menu Parameters']
    if type(params) ~= 'string' or #params < 16 then return nil end
    local accolades = uint32_le(params, 9)
    local allowance = uint32_le(params, 13)
    -- Treat missing/bogus data as unknown, not as zero or available funds.
    if not accolades or not allowance or accolades > 1000000 or allowance > 1000000 then
        return nil
    end
    return math.min(accolades, allowance), accolades, allowance
end

function Runner:start(requested)
    if self.active then
        self:_say('Already running. Use //sparks status or //sparks stop.', 2)
        return false
    end
    local number
    if requested ~= nil then
        number = tonumber(requested)
        if not number or number < 1 or number > 10000 or number ~= math.floor(number) then
            self:_say('Usage: //sparks powder [1-10000]; no amount buys until points/allowance/space runs out.', 2)
            return false
        end
    end

    local info = self.windower.ffxi.get_info()
    if not info or not UNITY_ZONES[info.zone] then
        self:_say('Visit a Unity Concord NPC in Bastok Markets, Windurst Woods, Western Adoulin or Southern San d\'Oria.', 2)
        return false
    end

    local count, room = self:_stock()
    if count == nil then
        self:_say('Cannot read Inventory; refusing to buy.', 2)
        return false
    end
    if room <= 0 then
        self:_say('No room in Inventory or existing Prize Powder stacks.', 2)
        return false
    end

    self.active = true
    self.phase = 'cooldown'
    self.zone = info.zone
    self.total = 0
    self.requested = number
    self.attempts = 0
    self.menu_id = nil
    self.menu_closed = false
    self.target = nil
    self.last_result = 'active'

    local name = (self.windower.ffxi.get_player() or {}).name or ''
    local hash = 0
    for i = 1, #name do hash = hash + name:byte(i) end
    local stagger = hash % 4
    self.next_at = self.clock() + stagger
    self:_say(number and ('Buying up to ' .. number .. ' powder.')
        or 'Buying until remaining Unity accolades/weekly allowance or Inventory space is exhausted.')
    return true
end

function Runner:_poke(now)
    local count, room = self:_stock()
    if count == nil then
        self:_finish('Inventory unavailable', false)
        return
    end
    if room == 0 then
        self:_finish('Inventory capacity reached', true)
        return
    end
    if self.requested and self.total >= self.requested then
        self:_finish('Requested quantity completed', true)
        return
    end

    local target = self:_find_npc()
    if not target then
        self:_finish('No Unity Concord NPC within six yalms in the current city', false)
        return
    end

    self.target = target
    self.menu_id = nil
    self.menu_closed = false
    self.before = count
    self.attempts = self.attempts + 1
    self.phase = 'waiting_menu'
    self.deadline = now + MENU_TIMEOUT

    local ok, err = pcall(function()
        self.packets.inject(self.packets.new('outgoing', 0x01A, {
            ['Target'] = target.id,
            ['Target Index'] = target.index,
            ['Category'] = 0,
            ['Param'] = 0,
            ['_unknown1'] = 0,
        }))
    end)
    if not ok then
        self:_finish('Cannot contact Unity NPC: ' .. tostring(err), false)
    end
end

function Runner:on_incoming(id, data, injected, blocked)
    if not self.active or injected or blocked then return nil end

    if self.phase == 'waiting_menu' and (id == 0x034 or id == 0x032) then
        local ok, packet = pcall(self.packets.parse, 'incoming', data)
        if not ok or type(packet) ~= 'table' then return nil end
        if packet['NPC'] ~= self.target.id or packet['NPC Index'] ~= self.target.index then
            return nil
        end

        self.menu_id = packet['Menu ID']
        if self.menu_id ~= self.target.expected_menu then
            self:_finish('Unexpected Unity NPC menu; purchase not attempted', false)
            return true
        end

        local available, accolades, allowance = self:_read_funds(id, packet)
        if not available then
            self:_finish('Could not verify Unity accolades and weekly allowance from NPC; no purchase sent', false)
            return true
        end

        local _, room = self:_stock()
        if not room then
            self:_finish('Inventory unavailable while checking Unity menu', false)
            return true
        end
        local remaining = self.requested and (self.requested - self.total) or STACK_SIZE
        local qty = math.min(STACK_SIZE, math.floor(available / COST), room, remaining)
        if qty < 1 then
            self:_finish(string.format('No more Prize Powder affordable/allowed (accolades=%d, weekly remaining=%d, room=%d)',
                accolades, allowance, room), true)
            return true
        end

        self.batch = qty
        self.phase = 'waiting_item_menu'
        self.deadline = self.clock() + STEP_TIMEOUT
        local sent, err = pcall(self._respond, self, 10, 0, true)
        if not sent then
            self:_finish('Failed to enter Unity item shop: ' .. tostring(err), false)
        end
        return true
    end

    if id == 0x05C and self.phase == 'waiting_item_menu' then
        self.phase = 'waiting_quantity_menu'
        self.deadline = self.clock() + STEP_TIMEOUT
        local sent, err = pcall(self._respond, self, ITEM_INDEX * 32 + 3, 0, true)
        if not sent then
            self:_finish('Failed to select Prize Powder: ' .. tostring(err), false)
        end
        return true
    end

    if id == 0x05C and self.phase == 'waiting_quantity_menu' then
        self.phase = 'waiting_delivery'
        self.deadline = self.clock() + DELIVERY_TIMEOUT

        -- Unity count encoding (Windower UnityNPC's CountMenu):
        -- low three bits of quantity occupy option bits 13+, high bits in uk1.
        -- Prize Powder is item index 12, type 4 (normal item).
        local option = (self.batch % 8) * 8192 + ITEM_INDEX * 32 + 4
        local unknown1 = math.floor(self.batch / 8)
        local sent, err = pcall(self._respond, self, option, unknown1, true)
        if not sent then
            self:_finish('Prize Powder request uncertain: ' .. tostring(err), false)
        end
        return true
    end

    -- If the game skipped or cancelled this event, stop. Do not resend any
    -- quantity option even if the client did not show its item immediately.
    if id == 0x052 and self.phase ~= 'waiting_delivery' then
        if type(data) == 'string' and data:byte(5) == 2 then
            self:_finish('Unity event interrupted; no automatic retry', false)
        end
    end
    return nil
end

function Runner:tick()
    if not self.active then return end
    local now = self.clock()
    local info = self.windower.ffxi.get_info()
    if not info or info.zone ~= self.zone then
        self:_finish('Zone changed; stopping', false)
        return
    end

    if self.phase == 'cooldown' then
        if now >= self.next_at then self:_poke(now) end
    elseif self.phase == 'waiting_menu' and now >= self.deadline then
        self:_release()
        if self.attempts >= MAX_MENU_ATTEMPTS then
            self:_finish('Unity NPC did not open menu after bounded retries', false)
        else
            self:_say(string.format('No menu response, retrying contact (%d/%d).',
                self.attempts, MAX_MENU_ATTEMPTS), 2)
            self.phase = 'cooldown'
            self.menu_id = nil
            self.next_at = now + RETRY_DELAY
        end
    elseif (self.phase == 'waiting_item_menu' or self.phase == 'waiting_quantity_menu')
        and now >= self.deadline then
        self:_finish('Unity event step timed out; stopping without a blind retry', false)
    elseif self.phase == 'waiting_delivery' then
        local count = self:_stock()
        if count == nil then
            self:_finish('Cannot verify Prize Powder: Inventory unavailable', false)
        elseif count == self.before + self.batch then
            self.total = self.total + self.batch
            self:_release()
            self.menu_id = nil
            self.menu_closed = true
            self.attempts = 0
            self:_say(string.format('Confirmed %d Prize Powder purchased.', self.total))
            if self.requested and self.total >= self.requested then
                self:_finish('Requested quantity completed', true)
            else
                self.phase = 'cooldown'
                self.next_at = now + PURCHASE_DELAY
            end
        elseif count ~= self.before then
            self:_finish('Partial/unexpected Inventory change; purchase result uncertain', false)
        elseif now >= self.deadline then
            self:_finish('Purchase not confirmed; refusing to resend it', false)
        end
    end
end

return Runner
