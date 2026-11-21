-- Mock packet and inventory tests for city Unity Prize Powder purchasing.
-- Run from repository root: lua5.1 tests/powder_runner_test.lua
package.path = './?.lua;' .. package.path
local Runner = require('powder_runner')

local specs = {
    [230] = { name = 'Urbiolaine', menu = 3529 },
    [235] = { name = 'Igsli', menu = 598 },
    [241] = { name = 'Yonolala', menu = 879 },
    [256] = { name = 'Nunaarl Bthtrogg', menu = 5149 },
}
local function u32(n)
    return string.char(n % 256, math.floor(n/256)%256,
        math.floor(n/65536)%256, math.floor(n/16777216)%256)
end
local function menu_packet(e, overrides)
    local packet = {
        ['NPC'] = 900,
        ['NPC Index'] = 44,
        ['Menu ID'] = specs[e.zone].menu,
        ['Menu Parameters'] = u32(0) .. u32(7) .. u32(e.accolades)
            .. u32(e.allowance) .. string.rep(string.char(0),16),
    }
    for k,v in pairs(overrides or {}) do packet[k] = v end
    return packet
end
local function mock(zone)
    local e = {
        now = 100, zone = zone or 235, accolades = 80000,
        allowance = 50000, used = 10, powder = 0,
        sends = {}, releases = {}, logs = {}, finished = 0,
    }
    local packets = {
        new = function(direction, id, fields)
            local p = fields or {}
            p.__id = id
            return p
        end,
        parse = function(direction, data) return data end,
        inject = function(packet) e.sends[#e.sends+1] = packet end,
    }
    local window = {
        ffxi = {
            get_info = function() return {zone=e.zone} end,
            get_player = function() return {name='Terrasjr'} end,
            get_mob_array = function()
                return {
                    [44] = {id=900, index=44, name=specs[e.zone].name, distance=4},
                    [45] = {id=901, index=45, name='Isakoth', distance=2},
                }
            end,
            get_items = function()
                local inv = {max=80, count=e.used}
                if e.powder > 0 then inv[1] = {id=5945, count=e.powder} end
                return {inventory=inv}
            end,
        },
        packets = {
            inject_incoming = function(id, data) e.releases[#e.releases+1]=id end
        }
    }
    local r=Runner.new({
        windower=window, packets=packets,
        log=function(message) e.logs[#e.logs+1]=message end,
        clock=function() return e.now end,
        on_finish=function() e.finished=e.finished+1 end,
    })
    return r,e
end
local function count(e, id, option)
    local n=0
    for _,p in ipairs(e.sends) do
        if p.__id==id and (option==nil or p['Option Index']==option) then n=n+1 end
    end
    return n
end
local function poke(r,e)
    e.now=r.next_at
    r:tick()
    assert(r.phase=='waiting_menu')
    assert(e.sends[#e.sends].__id==0x01A)
end
local function menu(r,e,overrides)
    return r:on_incoming(0x034,menu_packet(e,overrides),false,false)
end
local function send_steps(r)
    assert(r.phase=='waiting_item_menu')
    assert(r:on_incoming(0x05C,{},false,false)==true)
    assert(r.phase=='waiting_quantity_menu')
    assert(r:on_incoming(0x05C,{},false,false)==true)
    assert(r.phase=='waiting_delivery')
end

-- All four cities use the nearest correct Unity NPC, not their Sparks NPC.
for zone in pairs(specs) do
    local r,e=mock(zone)
    assert(r:start(1))
    poke(r,e)
    assert(e.sends[#e.sends]['Target']==900)
    assert(r:on_incoming(0x034,{['NPC']=901,['NPC Index']=45},false,false)==nil)
    assert(menu(r,e)==true)
    assert(e.sends[#e.sends]['Option Index']==10)
    send_steps(r)
    assert(e.sends[#e.sends]['Option Index']==8192+12*32+4)
    assert(e.sends[#e.sends]['_unknown1']==0)
    e.powder=1
    e.used=e.used+1
    r:tick()
    assert(not r:is_active() and r.total==1)
    assert(e.finished==1 and count(e,0x05B,0)==1)
end

-- Live balances and weekly allowance determine batch size.
do
    local r,e=mock()
    e.accolades=1000
    e.allowance=250
    assert(r:start())
    poke(r,e)
    menu(r,e)
    assert(r.batch==25)
    send_steps(r)
    assert(e.sends[#e.sends]['Option Index']==8192+12*32+4)
    assert(e.sends[#e.sends]['_unknown1']==3)
    e.powder=25
    e.used=e.used+1
    e.accolades=750
    e.allowance=0
    r:tick()
    assert(r.total==25 and r:is_active())
    poke(r,e)
    menu(r,e)
    assert(not r:is_active() and r.total==25)
    assert(count(e,0x05B,0)==2)
end

-- Full batch of 99 encodes quantity across option and unknown1.
do
    local r,e=mock()
    assert(r:start())
    poke(r,e)
    menu(r,e)
    assert(r.batch==99)
    send_steps(r)
    assert(e.sends[#e.sends]['Option Index']==3*8192+12*32+4)
    assert(e.sends[#e.sends]['_unknown1']==12)
end

-- Insufficient funds/weekly allowance and bad metadata exit before sending.
do
    local r,e=mock()
    e.accolades=9
    assert(r:start())
    poke(r,e)
    menu(r,e)
    assert(not r:is_active())
    assert(count(e,0x05B,10)==0)
end
do
    local r,e=mock()
    assert(r:start())
    poke(r,e)
    menu(r,e,{['Menu Parameters']='short'})
    assert(not r:is_active())
    assert(count(e,0x05B,10)==0)
end
do
    local r,e=mock()
    assert(r:start())
    poke(r,e)
    menu(r,e,{['Menu ID']=1234})
    assert(not r:is_active())
    assert(count(e,0x05B,10)==0)
end

-- Lost menu is retried at most three times, and releases the client.
do
    local r,e=mock()
    assert(r:start())
    for i=1,3 do
        poke(r,e)
        e.now=r.deadline
        r:tick()
    end
    assert(not r:is_active())
    assert(count(e,0x01A)==3 and #e.releases>0)
end

-- A lost response after making a quantity request must never retry a purchase.
do
    local r,e=mock()
    assert(r:start(99))
    poke(r,e)
    menu(r,e)
    send_steps(r)
    local sent=count(e,0x05B)
    e.now=r.deadline
    r:tick()
    assert(not r:is_active())
    assert(count(e,0x05B)==sent+1) -- only a cleanup/exit response
    assert(count(e,0x05B,3*8192+12*32+4)==1)
end

-- Do not initiate while full or outside eligible zones.
do
    local r,e=mock()
    e.used=80
    assert(not r:start())
    assert(count(e,0x01A)==0)
    e.used=10
    assert(not r:start(-1))
    assert(not r:start(1.5))
    e.zone=291
    assert(not r:start())
end

print('powder_runner: all mocked Unity transaction tests passed')
