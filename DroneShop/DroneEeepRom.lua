-- Compact Shop Drone (fits 4KiB EEPROM)
local c=component
local d=c.drone
local m=c.modem
local p=computer.pullSignal
local b=computer.beep
local e=computer.energy
local x,y,z=0,0,0
m.open(200)
d.setLightColor(0xFF)
m.broadcast(201,"READY")
while true do
local _,_,_,pt,_,msg=p(1)
if msg and pt==200 then
local t={}
for w in msg:gmatch("[^:]+")do t[#t+1]=w end
local cmd=t[1]
if cmd=="D"then
local cx,cy,cz,s,q=tonumber(t[2]),tonumber(t[3]),tonumber(t[4]),tonumber(t[5]),tonumber(t[6])or 1
if cx and cy and cz and s then
d.setLightColor(0xFFFF)
local dx,dy,dz=cx-x,cy+2-y,cz-z
d.move(dx,dy,dz)
x,y,z=cx,cy+2,cz
d.select(s)
if d.drop(3,q)then
m.broadcast(201,"OK")
d.setLightColor(0xFF00)
b(1000,0.1)
else
m.broadcast(201,"FAIL")
d.setLightColor(0xFF0000)
end
d.move(-x,-y,-z)
x,y,z=0,0,0
d.setLightColor(0xFF)
end
elseif cmd=="R"then
d.setLightColor(0xFFFF00)
local ok=false
for i=1,d.inventorySize()do
d.select(i)
if d.suck(3,64)then ok=true end
end
m.broadcast(201,ok and"RESTOCKED"or"EMPTY")
d.setLightColor(0xFF)
elseif cmd=="S"then
local inv="INV:"
for i=1,d.inventorySize()do
local n=d.count(i)
if n>0 then inv=inv..i.."="..n..","end
end
m.broadcast(201,inv)
m.broadcast(201,"E:"..math.floor(e()).."/"..computer.maxEnergy())
elseif cmd=="H"then
d.move(-x,-y,-z)
x,y,z=0,0,0
m.broadcast(201,"HOME")
end
end
if e()<computer.maxEnergy()*0.2 then d.setLightColor(0xFF6600)end
end
