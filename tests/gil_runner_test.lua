-- Mock-driven tests for the network-free gil transaction state machine.
-- Run from the repository root: lua5.1 tests/gil_runner_test.lua
package.path = './?.lua;' .. package.path
local Runner = require('gil_runner')

local function mock(name)
    local env = {
        now = 100,
        shields = 0,
        sparks = 99999,
        used = 10,
        zone = 230,
        sent = {},
        local_packets = {},
        messages = {},
        ended = 0,
    }
    local packets = {}
    function packets.new(direction, id, fields)
        local packet = fields or {}
        packet.__id = id
        return packet
    end
    function packets.inject(packet)
        env.sent[#env.sent + 1] = packet
    end
    function packets.parse(direction, data)
        return data
    end
    local windower = {
        ffxi = {
            get_info = function() return { zone = env.zone } end,
            get_player = function() return { name = name or 'Terrasjr' } end,
            get_items = function()
                local inv = { max = 80, count = env.used }
                for i = 1, env.shields do
                    inv[i] = { id = 12385, count = 1 }
                end
                return { inventory = inv }
            end,
        },
        packets = {
            inject_incoming = function(id, data)
                env.local_packets[#env.local_packets + 1] = { id = id, data = data }
            end,
        },
    }
    local runner = Runner.new({
        windower = windower,
        packets = packets,
        clock = function() return env.now end,
        shield_cost = 2755,
        read_sparks = function(id)
            if id == 0x034 then return env.sparks end
            return nil
        end,
        validate = function()
            return {
                ['Target'] = 123,
                ['Target Index'] = 9,
                ['Menu ID'] = 995,
                ['Option Index'] = 9,
                ['_unknown1'] = 41,
                ['Zone'] = 230,
            }
        end,
        log = function(message)
            env.messages[#env.messages + 1] = message
        end,
        on_finish = function() env.ended = env.ended + 1 end,
    })
    return runner, env
end

local function count_packet(env, id, option)
    local count = 0
    for _, packet in ipairs(env.sent) do
        if packet.__id == id and (option == nil or packet['Option Index'] == option) then
            count = count + 1
        end
    end
    return count
end

local function poke(runner, env)
    env.now = runner.next_at
    runner:tick()
    assert(runner.phase == 'waiting_menu', 'expected NPC menu request')
end

local function menu(runner, id)
    return runner:on_incoming(0x034, { ['NPC'] = 123, ['NPC Index'] = 9, ['Menu ID'] = id or 995 }, false, false)
end

-- Two exact, verified purchases, with no duplicate purchase request.
do
    local r, e = mock()
    assert(r:start(2))
    poke(r, e)
    assert(r:on_incoming(0x034, { ['NPC'] = 999, ['NPC Index'] = 99, ['Menu ID'] = 995 }, false, false) == nil)
    assert(count_packet(e, 0x05B, 9) == 0)
    assert(menu(r) == true)
    assert(count_packet(e, 0x05B, 9) == 1)
    e.shields = 1
    e.used = e.used + 1
    r:tick()
    assert(r.completed == 1 and r.phase == 'cooldown')
    poke(r, e)
    assert(menu(r) == true)
    assert(count_packet(e, 0x05B, 9) == 2)
    e.shields = 2
    e.used = e.used + 1
    r:tick()
    assert(not r:is_active() and r.completed == 2 and e.ended == 1)
end

-- Missing NPC menu retries are bounded, then state releases.
do
    local r, e = mock()
    assert(r:start(1))
    for attempt = 1, 3 do
        poke(r, e)
        e.now = r.deadline
        r:tick()
    end
    assert(not r:is_active() and e.ended == 1)
    assert(count_packet(e, 0x01A) == 3)
    assert(count_packet(e, 0x05B, 9) == 0)
    assert(#e.local_packets > 0, 'should locally release stuck menus')
end

-- Ambiguous purchase timeout aborts rather than sending a second purchase.
do
    local r, e = mock()
    assert(r:start(3))
    poke(r, e)
    menu(r)
    e.now = r.deadline
    r:tick()
    assert(not r:is_active() and r.completed == 0)
    assert(count_packet(e, 0x05B, 9) == 1, 'must never retry an unconfirmed purchase')
end

-- Wrong menu ID aborts and closes only that menu, without purchasing.
do
    local r, e = mock()
    assert(r:start(1))
    poke(r, e)
    assert(menu(r, 404) == true)
    assert(not r:is_active())
    assert(count_packet(e, 0x05B, 9) == 0)
    assert(count_packet(e, 0x05B, 0) == 1)
end

-- Cancel clears state immediately, leaving a future run available.
do
    local r, e = mock()
    assert(r:start(1))
    poke(r, e)
    r:cancel()
    assert(not r:is_active() and e.ended == 1)
    assert(r:start(1))
end

-- Inventory full and invalid requests fail without poking.
do
    local r, e = mock()
    e.used = 80
    assert(not r:start(1))
    assert(count_packet(e, 0x01A) == 0)
    e.used = 10
    assert(not r:start(0) and not r:start(39) and not r:start(1.5))
    e.zone = 291
    assert(not r:start(1))
    assert(count_packet(e, 0x01A) == 0)
end

-- Client state is isolated, even when two runs start together.
do
    local a, ae = mock('Redrogue')
    local b, be = mock('Etamame')
    assert(a:start(1) and b:start(1))
    poke(a, ae)
    assert(menu(a) == true)
    assert(b:is_active() and b.completed == 0)
    assert(count_packet(be, 0x05B, 9) == 0)
end


-- The production reader uses bytes 13-16 of the 0x034 NPC menu, not
-- the currency from an old packet or a fixed purchase count.
do
    local r = mock()
    r.read_sparks = nil
    local raw = string.rep(string.char(0), 12) .. string.char(195, 10, 0, 0)
    assert(r:_sparks_from_menu(0x034, raw) == 2755)
    assert(r:_sparks_from_menu(0x032, raw) == nil)
    assert(r:_sparks_from_menu(0x034, 'short') == nil)
end

-- Bare gil mode checks a fresh NPC Sparks balance before every purchase and
-- stops normally below shield cost, without a hard-coded purchase target.
do
    local r, e = mock()
    e.sparks = 8200
    assert(r:start())
    assert(r.auto == true and r.requested == nil)
    poke(r, e)
    assert(menu(r) == true)
    assert(count_packet(e, 0x05B, 9) == 1)
    e.shields = 1
    e.used = e.used + 1
    e.sparks = 5445
    r:tick()
    assert(r.completed == 1 and r:is_active())
    poke(r, e)
    assert(menu(r) == true)
    assert(count_packet(e, 0x05B, 9) == 2)
    e.shields = 2
    e.used = e.used + 1
    e.sparks = 2690
    r:tick()
    assert(r.completed == 2 and r:is_active())
    poke(r, e)
    assert(menu(r) == true)
    assert(not r:is_active() and r.completed == 2 and e.ended == 1)
    assert(count_packet(e, 0x05B, 9) == 2,
        'unaffordable menu must not send a third purchase')
    assert(e.messages[#e.messages]:find('Cannot afford another Acheron Shield'))
end

-- Already short of Sparks: no purchase, no retry, menu cleanly released.
do
    local r, e = mock()
    e.sparks = 2754
    assert(r:start())
    poke(r, e)
    assert(menu(r) == true)
    assert(not r:is_active() and e.ended == 1)
    assert(count_packet(e, 0x05B, 9) == 0)
    assert(count_packet(e, 0x05B, 0) == 1)
end

-- Automatic mode fails closed when funds cannot be read from this menu.
do
    local r, e = mock()
    e.sparks = nil
    assert(r:start())
    poke(r, e)
    assert(menu(r) == true)
    assert(not r:is_active() and e.ended == 1)
    assert(count_packet(e, 0x05B, 9) == 0)
end

-- Fixed-count mode remains fixed, despite having more Sparks available.
do
    local r, e = mock()
    assert(r:start(1))
    assert(not r.auto and r.requested == 1)
    poke(r, e)
    assert(menu(r) == true)
    e.shields = 1
    e.used = e.used + 1
    r:tick()
    assert(r.completed == 1 and not r:is_active())
    assert(count_packet(e, 0x05B, 9) == 1)
end

-- Exact affordability is allowed, but an unaffordable fixed-count purchase
-- is stopped early when currency is available from the NPC menu.
do
    local r, e = mock()
    e.sparks = 2755
    assert(r:start())
    poke(r, e)
    assert(menu(r) == true)
    assert(count_packet(e, 0x05B, 9) == 1)
    e.shields = 1
    e.used = e.used + 1
    e.sparks = 0
    r:tick()
    poke(r, e)
    assert(menu(r) == true)
    assert(not r:is_active() and r.completed == 1)
end

print('gil_runner: all mocked transaction tests passed')
