-- Non-blocking, per-client Acheron Shield purchase runner.
-- A request is never retried after the purchase packet is sent unless a fresh
-- inventory delta has first confirmed the previous purchase.
local Runner = {}
Runner.__index = Runner

local SHIELD_ID = 12385
local MAX_PURCHASES = 38
local MENU_TIMEOUT = 5
local ITEM_TIMEOUT = 8
local RETRY_DELAY = 2
local PURCHASE_DELAY = 2
local MAX_MENU_ATTEMPTS = 3
local CITY_ZONES = { [230] = true, [235] = true, [241] = true, [256] = true }

function Runner.new(deps)
    return setmetatable({
        windower = assert(deps.windower),
        packets = assert(deps.packets),
        validate = assert(deps.validate),
        log = assert(deps.log),
        on_finish = deps.on_finish,
        clock = deps.clock or os.time,
        active = false,
        phase = 'idle',
        completed = 0,
        requested = 0,
        attempts = 0,
        last_result = 'not started',
    }, Runner)
end

function Runner:is_active()
    return self.active
end

function Runner:_say(message, color)
    self.log('[Sparks gil] ' .. message, color or 8)
end

function Runner:_stock()
    local ok, items = pcall(self.windower.ffxi.get_items)
    if not ok or type(items) ~= 'table' or type(items.inventory) ~= 'table' then
        return nil, nil
    end

    local inv = items.inventory
    if type(inv.max) ~= 'number' or type(inv.count) ~= 'number' then
        return nil, nil
    end

    local shields = 0
    for slot = 1, inv.max do
        local item = inv[slot]
        if type(item) == 'table' and item.id == SHIELD_ID then
            shields = shields + (item.count or 1)
        end
    end
    return shields, inv.max - inv.count
end

function Runner:_local_release(menu_id)
    local inject = self.windower.packets and self.windower.packets.inject_incoming
    if not inject then
        return
    end

    -- SuperWarp's local event-release pattern. Never inject into another client.
    pcall(inject, 0x052, string.char(0, 0, 0, 0, 0, 0, 0, 0))
    if menu_id then
        local low = menu_id % 256
        local high = math.floor(menu_id / 256) % 256
        pcall(inject, 0x052, string.char(0, 0, 0, 0, 2, low, high, 0))
    end
    pcall(inject, 0x052, string.char(0, 0, 0, 0, 1, 0, 0, 0))
end

function Runner:_close_menu(menu)
    if not menu or menu.closed then
        return true
    end

    local ok, err = pcall(function()
        local response = self.packets.new('outgoing', 0x05B)
        response['Target'] = menu.npc
        response['Option Index'] = 0
        response['_unknown1'] = 16384
        response['Target Index'] = menu.index
        response['Automated Message'] = false
        response['_unknown2'] = 0
        response['Zone'] = menu.zone
        response['Menu ID'] = menu.id
        self.packets.inject(response)
    end)
    if ok then
        menu.closed = true
    end
    return ok, err
end

function Runner:_release()
    if self.menu then
        self:_close_menu(self.menu)
        self:_local_release(self.menu.id)
    elseif self.attempts > 0 then
        -- A poke may have opened a menu whose packet never arrived.
        self:_local_release(nil)
    end
end

function Runner:_finish(reason, successful)
    if not self.active then
        return
    end
    self:_release()
    self.active = false
    self.phase = 'idle'
    self.last_result = reason
    if self.on_finish then
        self.on_finish(successful == true)
    end
    self:_say(string.format('%s (%d/%d confirmed).', reason, self.completed, self.requested),
        successful and 8 or 2)
end

function Runner:cancel()
    if self.active then
        self:_finish('Stopped and released the NPC menu', false)
    else
        self:_say('Not running. Last result: ' .. self.last_result)
    end
end

function Runner:status()
    if self.active then
        self:_say(string.format('Running: %d/%d confirmed, phase=%s, menu attempts=%d.',
            self.completed, self.requested, self.phase, self.attempts))
    else
        self:_say('Idle. Last result: ' .. self.last_result)
    end
end

function Runner:start(amount)
    if self.active then
        self:_say('Already running; use //sparks status or //sparks stop.', 2)
        return false
    end

    local n = amount == nil and MAX_PURCHASES or tonumber(amount)
    if not n or n < 1 or n > MAX_PURCHASES or n ~= math.floor(n) then
        self:_say('Usage: //sparks gil [1-38]', 2)
        return false
    end

    local info = self.windower.ffxi.get_info()
    if not info or not CITY_ZONES[info.zone] then
        self:_say('Gil purchases require a city Sparks NPC.', 2)
        return false
    end

    local shields, free = self:_stock()
    if not shields or not free then
        self:_say('Unable to read main Inventory; not starting.', 2)
        return false
    end
    if free <= 0 then
        self:_say('Main Inventory is full; not starting.', 2)
        return false
    end

    self.active = true
    self.phase = 'cooldown'
    self.completed = 0
    self.requested = n
    self.attempts = 0
    self.menu = nil
    self.target = nil
    self.zone = info.zone

    -- Spread initial NPC pokes from concurrently started Windower clients.
    local name = (self.windower.ffxi.get_player() or {}).name or ''
    local hash = 0
    for i = 1, #name do
        hash = hash + name:byte(i)
    end
    local stagger = hash % 3
    self.next_at = self.clock() + stagger
    self:_say(string.format('Starting up to %d shields; first request in %ds.', n, stagger))
    return true
end

function Runner:_poke(now)
    local info = self.windower.ffxi.get_info()
    if not info or info.zone ~= self.zone then
        self:_finish('Zone changed; stopping', false)
        return
    end
    local shields, free = self:_stock()
    if not shields or not free then
        self:_finish('Inventory data unavailable; stopping', false)
        return
    end
    if free <= 0 then
        self:_finish('Inventory full; stopping', true)
        return
    end

    local ok, target = pcall(self.validate)
    if not ok or not target or not target['Target'] or not target['Target Index'] then
        self:_finish('Sparks NPC is missing, out of range, or invalid', false)
        return
    end

    self.target = target
    self.before = shields
    self.menu = nil
    self.attempts = self.attempts + 1
    self.phase = 'waiting_menu'
    self.deadline = now + MENU_TIMEOUT

    local injected, err = pcall(function()
        local poke = self.packets.new('outgoing', 0x01A, {
            ['Target'] = target['Target'],
            ['Target Index'] = target['Target Index'],
            ['Category'] = 0,
            ['Param'] = 0,
            ['_unknown1'] = 0,
        })
        self.packets.inject(poke)
    end)
    if not injected then
        self:_finish('NPC poke failed: ' .. tostring(err), false)
    end
end

function Runner:on_incoming(id, data, injected, blocked)
    if not self.active or self.phase ~= 'waiting_menu'
        or (id ~= 0x034 and id ~= 0x032) or injected or blocked then
        return nil
    end

    local ok, packet = pcall(self.packets.parse, 'incoming', data)
    if not ok or type(packet) ~= 'table' then
        return nil
    end

    -- Never consume or respond to a menu from a different NPC.
    if packet['NPC'] ~= self.target['Target']
        or packet['NPC Index'] ~= self.target['Target Index'] then
        return nil
    end

    local menu_id = packet['Menu ID']
    self.menu = {
        npc = self.target['Target'],
        index = self.target['Target Index'],
        zone = self.target['Zone'],
        id = menu_id,
    }

    if menu_id ~= self.target['Menu ID'] then
        self:_finish('Unexpected NPC menu ID; no purchase sent', false)
        return true
    end

    -- One purchase request only. A timeout *after this point* is ambiguous:
    -- never resend without a confirmed Inventory delta.
    self.phase = 'waiting_item'
    self.deadline = self.clock() + ITEM_TIMEOUT
    local sent, err = pcall(function()
        local request = self.packets.new('outgoing', 0x05B)
        request['Target'] = self.target['Target']
        request['Option Index'] = self.target['Option Index']
        request['_unknown1'] = self.target['_unknown1']
        request['Target Index'] = self.target['Target Index']
        request['Automated Message'] = true
        request['_unknown2'] = 0
        request['Zone'] = self.target['Zone']
        request['Menu ID'] = menu_id
        self.packets.inject(request)
    end)

    if not sent then
        self:_finish('Could not send purchase request: ' .. tostring(err), false)
        return true
    end

    local closed, close_err = self:_close_menu(self.menu)
    self:_local_release(menu_id)
    if not closed then
        self:_finish('Purchase sent but menu close failed: ' .. tostring(close_err), false)
    end
    return true
end

function Runner:tick()
    if not self.active then
        return
    end
    local now = self.clock()
    local info = self.windower.ffxi.get_info()
    if not info or info.zone ~= self.zone then
        self:_finish('Zone changed; stopping', false)
        return
    end

    if self.phase == 'cooldown' then
        if now >= self.next_at then
            self:_poke(now)
        end
    elseif self.phase == 'waiting_menu' and now >= self.deadline then
        self:_release()
        if self.attempts >= MAX_MENU_ATTEMPTS then
            self:_finish('NPC menu timed out after bounded retries', false)
        else
            self:_say(string.format('NPC menu timeout; retrying poke (%d/%d).',
                self.attempts, MAX_MENU_ATTEMPTS), 2)
            self.phase = 'cooldown'
            self.next_at = now + RETRY_DELAY
        end
    elseif self.phase == 'waiting_item' then
        local shields = self:_stock()
        if shields == nil then
            self:_finish('Cannot verify purchase: Inventory unavailable', false)
        elseif shields == self.before + 1 then
            self.completed = self.completed + 1
            self.menu = nil
            self.attempts = 0
            if self.completed % 5 == 0 or self.completed == self.requested then
                self:_say(string.format('Confirmed %d/%d shields.', self.completed, self.requested))
            end
            if self.completed >= self.requested then
                self:_finish('Done', true)
            else
                self.phase = 'cooldown'
                self.next_at = now + PURCHASE_DELAY
            end
        elseif shields ~= self.before then
            self:_finish('Unexpected Inventory change; purchase result uncertain', false)
        elseif now >= self.deadline then
            self:_finish('Purchase unconfirmed after timeout; refusing to retry it', false)
        end
    end
end

return Runner
