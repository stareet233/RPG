-- ============================================
-- Buhlal RPG Aimbot
-- ============================================

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local StarterPack      = game:GetService("StarterPack")
local Workspace        = game:GetService("Workspace")
local HttpService      = game:GetService("HttpService")
local Camera           = Workspace.CurrentCamera
local LP               = Players.LocalPlayer

-- ============================================
-- CONFIG
-- ============================================
local CFG = {
    AutoSave        = true,
    AimEnabled      = false,
    ESPEnabled      = true,
    ESPInvEnabled   = true,
    AimKey          = Enum.UserInputType.MouseButton2,
    GroundAim       = true,
    FOV             = 180,
    Smoothness      = 0.14,
    PredictStr      = 1.1,
    ProjSpeed       = 160,
    LockDist        = 35,
    MaxDist         = 200,
    InvMaxDist      = 2000,
    StickyLock      = true,
    StickyTimeout   = 2.0,
    TeamCheck       = true,
    WallCheck       = true,
    ShowFOV         = true,
    ShowESP         = true,
    ShowTrail       = true,
    ShowGndCircle   = true,
    ShowArrow       = true,
    ShowConf        = true,
    HistoryLen      = 12,
}

local function SaveConfig()
    if not CFG.AutoSave then return end
    pcall(function()
        if writefile then
            local toSave = {}
            for k,v in pairs(CFG) do 
                if typeof(v) ~= "EnumItem" then 
                    toSave[k] = v 
                end 
            end
            writefile("BuhlalRPG_Config.json", HttpService:JSONEncode(toSave))
        end
    end)
end

local function LoadConfig()
    pcall(function()
        if readfile and isfile and isfile("BuhlalRPG_Config.json") then
            local d = HttpService:JSONDecode(readfile("BuhlalRPG_Config.json"))
            for k,v in pairs(d) do 
                if CFG[k] ~= nil and typeof(CFG[k]) == typeof(v) then 
                    CFG[k] = v 
                end 
            end
        end
    end)
end
LoadConfig()

local holding = false

-- ============================================
-- AI TRACKING ENGINE
-- ============================================
local TrackData = {}

local function trackPlayer(player, hrp)
    if not TrackData[player] then
        TrackData[player] = { pos={}, time={}, smoothVel = Vector3.zero }
    end
    local d   = TrackData[player]
    local now = os.clock()
    local curPos = hrp.Position
    table.insert(d.pos, curPos)
    table.insert(d.time, now)
    while #d.pos  > CFG.HistoryLen do table.remove(d.pos,  1) end
    while #d.time > CFG.HistoryLen do table.remove(d.time, 1) end
    if #d.pos > 5 then
        local pastPos  = d.pos[1]
        local pastTime = d.time[1]
        local dt = now - pastTime
        if dt > 0.01 then
            local rawVel = (curPos - pastPos) / dt
            rawVel = Vector3.new(rawVel.X, 0, rawVel.Z)
            if rawVel.Magnitude > 100 then rawVel = rawVel.Unit * 100 end
            d.smoothVel = d.smoothVel:Lerp(rawVel, 0.08)
        end
    end
end

-- ============================================
-- RAYCAST HELPERS
-- ============================================
local function makeParams(exclude)
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.FilterDescendantsInstances = exclude
    p.IgnoreWater = true
    return p
end

local function getGroundY(hrp, predX, predZ)
    local ex = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(ex, p.Character) end
    end
    local startPos = Vector3.new(predX, hrp.Position.Y + 5, predZ)
    local res = Workspace:Raycast(startPos, Vector3.new(0, -60, 0), makeParams(ex))
    if res then return res.Position.Y end
    local res2 = Workspace:Raycast(hrp.Position, Vector3.new(0, -60, 0), makeParams(ex))
    return res2 and res2.Position.Y or (hrp.Position.Y - 3)
end

local function isVisible(hrpPos)
    if not CFG.WallCheck then return true end
    local myPos = Camera.CFrame.Position
    local ex = {}
    if LP.Character then table.insert(ex, LP.Character) end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then table.insert(ex, p.Character) end
    end
    local result = Workspace:Raycast(myPos, (hrpPos - myPos), makeParams(ex))
    return not result
end

-- ============================================
-- PREDICTION
-- ============================================
local function predictTarget(player, hrp)
    local d = TrackData[player]
    if not d then return hrp.Position, nil, 0 end
    local avgVel = d.smoothVel or Vector3.zero
    local dist   = (hrp.Position - Camera.CFrame.Position).Magnitude
    local T      = dist / math.max(CFG.ProjSpeed, 1)
    local pred = hrp.Position + avgVel * T * CFG.PredictStr
    local finalPos
    if CFG.GroundAim then
        local gy = getGroundY(hrp, pred.X, pred.Z)
        finalPos = Vector3.new(pred.X, gy, pred.Z)
    else
        finalPos = pred
    end
    local movDir = avgVel.Magnitude > 0.5 and avgVel.Unit or nil
    local conf = 1
    if avgVel.Magnitude > 0 then
        local cv = hrp.AssemblyLinearVelocity
        cv = Vector3.new(cv.X, 0, cv.Z)
        conf = math.clamp(1 - (cv - avgVel).Magnitude / 50, 0.2, 1)
    end
    return finalPos, movDir, conf
end

local function getTrail(player, hrp)
    local d = TrackData[player]
    if not d then return {} end
    local avgVel = d.smoothVel or Vector3.zero
    local pts = {}
    for i = 1, 6 do
        local t    = i * 0.18
        local pred = hrp.Position + avgVel*t*CFG.PredictStr
        local gy   = CFG.GroundAim and getGroundY(hrp, pred.X, pred.Z) or pred.Y
        table.insert(pts, Vector3.new(pred.X, gy, pred.Z))
    end
    return pts
end

-- ============================================
-- TARGET SELECTOR
-- ============================================
local lockedTarget = nil
local lockLostTime = 0

local function checkLocked(p)
    if not p or not p.Parent then return false end
    local ch = p.Character
    if not ch then return false end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return false end
    local myHRP = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if myHRP and (hrp.Position - myHRP.Position).Magnitude > CFG.MaxDist then return false end
    local sp, on = Camera:WorldToViewportPoint(hrp.Position)
    if not on or sp.Z <= 0 then return false end
    local sd = (Vector2.new(sp.X, sp.Y) - Camera.ViewportSize/2).Magnitude
    if sd > CFG.FOV then return false end
    return true
end

local function getBest()
    if not holding or not CFG.AimEnabled then
        lockedTarget = nil
        return nil, nil, nil, nil, 0, math.huge
    end
    local vpH   = Camera.ViewportSize / 2
    local myHRP = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local now   = os.clock()
    if CFG.StickyLock and lockedTarget then
        if checkLocked(lockedTarget) then
            local ch  = lockedTarget.Character
            local hrp = ch:FindFirstChild("HumanoidRootPart")
            trackPlayer(lockedTarget, hrp)
            local aim, dir, conf = predictTarget(lockedTarget, hrp)
            local sp, on = Camera:WorldToViewportPoint(aim or hrp.Position)
            local sd = on and (Vector2.new(sp.X,sp.Y) - vpH).Magnitude or math.huge
            lockLostTime = now
            return lockedTarget, hrp, aim, dir, conf, sd
        else
            local ch = lockedTarget.Character
            local hrpOk = false
            if ch then
                local hrp = ch:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local sp, on = Camera:WorldToViewportPoint(hrp.Position)
                    if on and sp.Z > 0 then
                        local sd = (Vector2.new(sp.X,sp.Y) - vpH).Magnitude
                        if sd <= CFG.FOV and now - lockLostTime < CFG.StickyTimeout then
                            hrpOk = true
                        end
                    end
                end
            end
            if not hrpOk then lockedTarget = nil end
        end
    end
    local bestP, bestHRP, bestAim, bestDir, bestConf, bestSD = nil,nil,nil,nil,0,math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LP then continue end
        if CFG.TeamCheck and LP.Team and p.Team == LP.Team then continue end
        local ch = p.Character
        if not ch then continue end
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end
        if myHRP and (hrp.Position - myHRP.Position).Magnitude > CFG.MaxDist then continue end
        local sp, on = Camera:WorldToViewportPoint(hrp.Position)
        if not on or sp.Z <= 0 then continue end
        local sd = (Vector2.new(sp.X, sp.Y) - vpH).Magnitude
        if sd > CFG.FOV then continue end
        if not isVisible(hrp.Position) then continue end
        trackPlayer(p, hrp)
        local aim, dir, conf = predictTarget(p, hrp)
        if not aim then continue end
        local dist = (hrp.Position - Camera.CFrame.Position).Magnitude
        local vel  = hrp.AssemblyLinearVelocity
        local spd  = Vector3.new(vel.X,0,vel.Z).Magnitude
        local score = (1 - sd/CFG.FOV)*70 + math.clamp(1-dist/300,0,1)*20 + math.clamp(spd/30,0,1)*10
        if score > (bestP and (1-bestSD/CFG.FOV)*70 or -1) then
            bestP=p bestHRP=hrp bestAim=aim bestDir=dir bestConf=conf bestSD=sd
        end
    end
    if bestP and CFG.StickyLock then
        lockedTarget = bestP
        lockLostTime = now
    end
    return bestP, bestHRP, bestAim, bestDir, bestConf, bestSD
end

-- ============================================
-- AIM
-- ============================================
local function aimAt(pos)
    if not pos then return end
    local cur = Camera.CFrame
    Camera.CFrame = cur:Lerp(CFrame.new(cur.Position, pos), CFG.Smoothness)
end

-- ============================================
-- MANUAL SHOOT
-- ============================================
UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.UserInputType == CFG.AimKey then holding = true end
end)

UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType == CFG.AimKey then holding = false end
end)

-- ================= ESP INVENTORY =================
local BillboardCache = {}
local nameCache = {}

local RARITY_COLORS = {
    ["Common"]    = Color3.fromRGB(255,255,255),
    ["Uncommon"]  = Color3.fromRGB(99,255,52),
    ["Rare"]      = Color3.fromRGB(51,170,255),
    ["Epic"]      = Color3.fromRGB(237,44,255),
    ["Legendary"] = Color3.fromRGB(255,150,0),
    ["Omega"]     = Color3.fromRGB(255,20,51),
}

local function getRealName(t)
    if not t or not t.Name then return nil end
    local originalName = t.Name
    local lowerName = originalName:lower()
    local cleaned = lowerName
        :gsub("%d+$",""):gsub("_%d+$",""):gsub("%s*%d+%s*$","")
        :gsub("[%s_]+"," "):gsub("([^%w%s])",""):match("^%s*(.-)%s*$")
    if cleaned:find("fishing") or cleaned:find("rod") then
        if cleaned:find("ultimate") or cleaned:find("ult") then return "Ultimate Fishing Rod"
        elseif cleaned:find("advanced") then return "Advanced Fishing Rod"
        elseif cleaned:find("pro") then return "Pro Fishing Rod"
        else return "Regular Fishing Rod" end
    end
    if nameCache[originalName] then return nameCache[originalName] end
    local h = t:FindFirstChild("Handle")
    local fallbackName = cleaned
    for _, folder in ipairs({ReplicatedStorage:FindFirstChild("Items"), StarterPack}) do
        if folder then
            for _, item in ipairs(folder:GetDescendants()) do
                if item:IsA("Tool") and item:FindFirstChild("Handle") then
                    local match = true
                    if h then
                        for _, c in ipairs(h:GetChildren()) do
                            if not item.Handle:FindFirstChild(c.Name) then match=false break end
                        end
                    else match=false end
                    if match then nameCache[originalName]=item.Name return item.Name end
                end
            end
        end
    end
    nameCache[originalName]=fallbackName
    return fallbackName
end

local function updateInventoryESP(p)
    local bb = BillboardCache[p]
    if not bb then return end
    local char = p.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then bb.Enabled=false return end
    local lChar = LP.Character
    if lChar and lChar:FindFirstChild("HumanoidRootPart") then
        local dist=(lChar.HumanoidRootPart.Position-char.HumanoidRootPart.Position).Magnitude
        if dist>CFG.InvMaxDist then bb.Enabled=false return end
    end
    local container=bb:FindFirstChild("EspContainer")
    if not container then return end
    container:ClearAllChildren()
    local layout=Instance.new("UIListLayout",container)
    layout.HorizontalAlignment=Enum.HorizontalAlignment.Center
    layout.VerticalAlignment=Enum.VerticalAlignment.Bottom
    layout.Padding=UDim.new(0,2)
    local tools={}
    if p:FindFirstChild("Backpack") then
        for _,t in ipairs(p.Backpack:GetChildren()) do
            if t:IsA("Tool") and t.Name:lower()~="fists" then table.insert(tools,t) end
        end
    end
    if char then
        for _,t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") and t.Name:lower()~="fists" then table.insert(tools,t) end
        end
    end
    bb.Enabled=CFG.ESPInvEnabled and (#tools>0)
    for _,tool in ipairs(tools) do
        local name=getRealName(tool)
        if name then
            local lbl=Instance.new("TextLabel",container)
            lbl.Size=UDim2.new(0,180,0,14)
            lbl.BackgroundTransparency=1
            lbl.Text=name
            lbl.Font=Enum.Font.SourceSansBold
            lbl.TextSize=11
            lbl.TextStrokeTransparency=0.4
            local rarity=tool:GetAttribute("RarityName") or tool:GetAttribute("Rarity")
            lbl.TextColor3=RARITY_COLORS[rarity] or Color3.new(1,1,1)
        end
    end
end

local function createInventoryESP(p)
    if p==LP then return end
    local function setup(char)
        local root=char:WaitForChild("HumanoidRootPart",15)
        if not root then return end
        if BillboardCache[p] then BillboardCache[p]:Destroy() end
        local bb=Instance.new("BillboardGui",root)
        bb.Name="FixedUnderfootESP"
        bb.Size=UDim2.new(0,200,0,150)
        bb.StudsOffset=Vector3.new(0,-3.5,0)
        bb.AlwaysOnTop=true
        bb.MaxDistance=CFG.InvMaxDist
        local cont=Instance.new("Frame",bb)
        cont.Name="EspContainer"
        cont.Size=UDim2.new(1,0,1,0)
        cont.BackgroundTransparency=1
        BillboardCache[p]=bb
        updateInventoryESP(p)
        char.ChildAdded:Connect(function(c) if c:IsA("Tool") then task.wait(0.1) updateInventoryESP(p) end end)
        char.ChildRemoved:Connect(function(c) if c:IsA("Tool") then task.wait(0.1) updateInventoryESP(p) end end)
        local backpack=p:WaitForChild("Backpack",5)
        if backpack then
            backpack.ChildAdded:Connect(function() updateInventoryESP(p) end)
            backpack.ChildRemoved:Connect(function() updateInventoryESP(p) end)
        end
        task.spawn(function()
            while char.Parent and bb.Parent do updateInventoryESP(p) task.wait(1) end
        end)
    end
    p.CharacterAdded:Connect(setup)
    if p.Character then setup(p.Character) end
end

for _,p in ipairs(Players:GetPlayers()) do task.spawn(createInventoryESP,p) end
Players.PlayerAdded:Connect(function(p) task.spawn(createInventoryESP,p) end)

-- ============================================
-- DRAWING LAYER
-- ============================================
local function D(t) return Drawing.new(t) end

local fovC=D("Circle") fovC.Filled=false fovC.Thickness=1.5 fovC.Color=Color3.fromRGB(255,255,255) fovC.Visible=false
local pdot=D("Circle") pdot.Radius=7 pdot.Filled=true pdot.Visible=false
local aline=D("Line") aline.Thickness=1.2 aline.Visible=false
local RING={} for i=1,24 do local l=D("Line") l.Thickness=2 l.Visible=false table.insert(RING,l) end
local TRAIL={} for i=1,6 do local c=D("Circle") c.Filled=true c.Visible=false table.insert(TRAIL,c) end
local arrMain=D("Line") arrMain.Thickness=2.5 arrMain.Visible=false
local arrL=D("Line") arrL.Thickness=2 arrL.Visible=false
local arrR=D("Line") arrR.Thickness=2 arrR.Visible=false
local confBg=D("Square") confBg.Filled=true confBg.Color=Color3.fromRGB(25,25,35) confBg.Visible=false
local confFill=D("Square") confFill.Filled=true confFill.Visible=false

local ESP={}
local function getESP(p)
    if not ESP[p] then
        local e={}
        e.box=D("Square") e.box.Filled=false e.box.Thickness=1.5 e.box.Visible=false
        e.name=D("Text") e.name.Size=13 e.name.Font=2 e.name.Outline=true e.name.Visible=false
        e.hBg=D("Square") e.hBg.Filled=true e.hBg.Color=Color3.fromRGB(15,15,20) e.hBg.Visible=false
        e.hp=D("Square") e.hp.Filled=true e.hp.Visible=false
        e.dst=D("Text") e.dst.Size=11 e.dst.Font=2 e.dst.Outline=true e.dst.Visible=false
        ESP[p]=e
    end
    return ESP[p]
end
local function hideESP(e) for _,o in pairs(e) do o.Visible=false end end

local function drawRing(center,radius,col)
    for i=1,24 do
        local a1=((i-1)/24)*math.pi*2
        local a2=(i/24)*math.pi*2
        local p1=center+Vector3.new(math.cos(a1)*radius,0,math.sin(a1)*radius)
        local p2=center+Vector3.new(math.cos(a2)*radius,0,math.sin(a2)*radius)
        local s1,o1=Camera:WorldToViewportPoint(p1)
        local s2,o2=Camera:WorldToViewportPoint(p2)
        local l=RING[i]
        if o1 and o2 and s1.Z>0 and s2.Z>0 then
            l.From=Vector2.new(s1.X,s1.Y) l.To=Vector2.new(s2.X,s2.Y) l.Color=col l.Visible=true
        else l.Visible=false end
    end
end
local function hideRing() for _,l in ipairs(RING) do l.Visible=false end end

local function drawTrail(pts,conf)
    for i,t in ipairs(TRAIL) do
        local p3=pts[i]
        if p3 and CFG.ShowTrail then
            local sp,on=Camera:WorldToViewportPoint(p3)
            if on and sp.Z>0 then
                local fade=1-(i/6)
                t.Position=Vector2.new(sp.X,sp.Y)
                t.Radius=math.max(2,5*fade)
                t.Color=Color3.fromRGB(255,math.floor(130+80*conf),math.floor(50*conf))
                t.Transparency=1-fade*0.8 t.Visible=true
            else t.Visible=false end
        else t.Visible=false end
    end
end

local function drawArrow(from3,to3)
    local sf,of=Camera:WorldToViewportPoint(from3)
    local st,ot=Camera:WorldToViewportPoint(to3)
    if not(of and ot and sf.Z>0 and st.Z>0) then
        arrMain.Visible=false arrL.Visible=false arrR.Visible=false return
    end
    local p1=Vector2.new(sf.X,sf.Y) local p2=Vector2.new(st.X,st.Y)
    local dv=p2-p1
    if dv.Magnitude<10 then arrMain.Visible=false arrL.Visible=false arrR.Visible=false return end
    local n=dv.Unit local perp=Vector2.new(-n.Y,n.X)
    arrMain.From=p1 arrMain.To=p2 arrMain.Color=Color3.fromRGB(255,220,50) arrMain.Visible=true
    arrL.From=p2 arrL.To=p2-n*12+perp*6 arrL.Color=Color3.fromRGB(255,220,50) arrL.Visible=true
    arrR.From=p2 arrR.To=p2-n*12-perp*6 arrR.Color=Color3.fromRGB(255,220,50) arrR.Visible=true
end
local function hideArrow() arrMain.Visible=false arrL.Visible=false arrR.Visible=false end

-- ============================================
-- MAIN LOOP (RENDER)
-- ============================================
RunService.RenderStepped:Connect(function()
    local vpH=Camera.ViewportSize/2
    fovC.Position=vpH fovC.Radius=CFG.FOV fovC.Visible=CFG.ShowFOV
    local bP,bHRP,bAim,bDir,bConf,bSD=getBest()
    local aimSD=math.huge
    if bAim then
        local sp,on=Camera:WorldToViewportPoint(bAim)
        if on and sp.Z>0 then aimSD=(Vector2.new(sp.X,sp.Y)-vpH).Magnitude end
    end
    if CFG.AimEnabled and holding and bAim then
        if not currentAimPoint then currentAimPoint=bAim
        else currentAimPoint=currentAimPoint:Lerp(bAim,0.05) end
        aimAt(currentAimPoint)
    else currentAimPoint=nil end
    if statusLbl then
        if not CFG.AimEnabled and not CFG.ESPEnabled then
            statusLbl.Text="⏸ Disabled" statusLbl.TextColor3=Color3.fromRGB(140,140,150)
        elseif bP then
            local locked=aimSD<CFG.LockDist
            local pct=math.floor((bConf or 0)*100)
            statusLbl.Text=locked and ("🟢 Locked: "..bP.DisplayName.." | "..pct.."%")
                or ("🟡 Tracking: "..bP.DisplayName.." | "..pct.."%")
            statusLbl.TextColor3=locked and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,200,50)
        else
            statusLbl.Text="🔴 No target (Hold Right Click)"
            statusLbl.TextColor3=Color3.fromRGB(255,80,80)
        end
    end
    if CFG.AimEnabled and holding and currentAimPoint then
        local sp,on=Camera:WorldToViewportPoint(currentAimPoint)
        if on and sp.Z>0 then
            local locked=aimSD<CFG.LockDist
            local col=locked and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,100,0)
            pdot.Position=Vector2.new(sp.X,sp.Y) pdot.Color=col
            pdot.Radius=locked and 8 or 6 pdot.Visible=true
            aline.From=vpH aline.To=Vector2.new(sp.X,sp.Y) aline.Color=col aline.Visible=true
        else pdot.Visible=false aline.Visible=false end
    else pdot.Visible=false aline.Visible=false end
    if currentAimPoint and holding and CFG.ShowGndCircle and CFG.GroundAim then
        drawRing(currentAimPoint,3.5,(aimSD<CFG.LockDist) and Color3.fromRGB(0,255,100) or Color3.fromRGB(255,100,0))
    else hideRing() end
    if bHRP and bP and holding and CFG.ShowTrail then
        drawTrail(getTrail(bP,bHRP),bConf or 0)
    else for _,t in ipairs(TRAIL) do t.Visible=false end end
    if bHRP and currentAimPoint and holding and bDir and CFG.ShowArrow then
        drawArrow(bHRP.Position+Vector3.new(0,1,0),currentAimPoint+Vector3.new(0,1,0))
    else hideArrow() end
    if bConf and holding and CFG.ShowConf and bP then
        local bw=100 local bh=5
        local bx=vpH.X-bw/2 local by=vpH.Y+CFG.FOV+12
        confBg.Position=Vector2.new(bx,by) confBg.Size=Vector2.new(bw,bh) confBg.Visible=true
        confFill.Position=Vector2.new(bx,by) confFill.Size=Vector2.new(bw*bConf,bh)
        confFill.Color=Color3.fromHSV(bConf*0.33,1,1) confFill.Visible=true
    else confBg.Visible=false confFill.Visible=false end
    for _,p in ipairs(Players:GetPlayers()) do
        if p==LP then continue end
        local e=getESP(p)
        local ch=p.Character
        if not ch or not CFG.ShowESP or not CFG.ESPEnabled then hideESP(e) continue end
        local hrp=ch:FindFirstChild("HumanoidRootPart")
        local hum=ch:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum then hideESP(e) continue end
        local sp,on=Camera:WorldToViewportPoint(hrp.Position)
        if not on or sp.Z<=0 then hideESP(e) continue end
        local dist=(hrp.Position-Camera.CFrame.Position).Magnitude
        local sc=1700/dist
        local bW=sc*1.4 local bH=sc*2.8
        local bx=sp.X-bW/2 local by=sp.Y-bH/2
        local isT=(p==bP and holding)
        local col=isT and Color3.fromRGB(255,130,0) or Color3.fromRGB(60,190,255)
        e.box.Position=Vector2.new(bx,by) e.box.Size=Vector2.new(bW,bH) e.box.Color=col e.box.Visible=true
        e.name.Position=Vector2.new(sp.X,by-16) e.name.Center=true
        e.name.Text=p.DisplayName..(isT and " 🎯" or "") e.name.Color=col e.name.Visible=true
        e.dst.Position=Vector2.new(sp.X,by+bH+2) e.dst.Center=true
        e.dst.Text=math.floor(dist).."m" e.dst.Color=Color3.fromRGB(180,180,180) e.dst.Visible=true
        local r=math.clamp(hum.Health/math.max(hum.MaxHealth,1),0,1)
        e.hBg.Position=Vector2.new(bx-7,by) e.hBg.Size=Vector2.new(4,bH) e.hBg.Visible=true
        e.hp.Position=Vector2.new(bx-7,by+bH-bH*r) e.hp.Size=Vector2.new(4,bH*r)
        e.hp.Color=Color3.fromHSV(r*0.33,1,1) e.hp.Visible=true
    end
    for p in pairs(ESP) do
        if not p.Parent then
            hideESP(ESP[p])
            for _,o in pairs(ESP[p]) do pcall(function() o:Remove() end) end
            ESP[p]=nil TrackData[p]=nil
        end
    end
end)

-- ============================================
-- GUI
-- ============================================
local C={
    bg=Color3.fromRGB(16,16,22), panel=Color3.fromRGB(24,24,32),
    side=Color3.fromRGB(20,20,27), acc=Color3.fromRGB(255,100,50),
    grn=Color3.fromRGB(0,190,90), red=Color3.fromRGB(220,55,55),
    tOn=Color3.fromRGB(0,145,70), tOff=Color3.fromRGB(48,48,60),
    txt=Color3.fromRGB(238,238,244), sub=Color3.fromRGB(130,130,142),
    gold=Color3.fromRGB(255,200,50),
}

local sg=Instance.new("ScreenGui")
sg.Name="BuhlaAim" sg.ResetOnSpawn=false
pcall(function() sg.Parent=game:GetService("CoreGui") end)
if sg.Parent~=game:GetService("CoreGui") then sg.Parent=LP:WaitForChild("PlayerGui") end

local win=Instance.new("Frame")
win.Size=UDim2.new(0,400,0,440)
win.Position=UDim2.new(0.5,-200,0.5,-220)
win.BackgroundColor3=C.bg win.BorderSizePixel=0
win.Active=true win.Draggable=true win.Parent=sg
Instance.new("UICorner",win).CornerRadius=UDim.new(0,12)
Instance.new("UIStroke",win).Color=Color3.fromRGB(40,40,54)

local tb=Instance.new("Frame")
tb.Size=UDim2.new(1,0,0,44) tb.BackgroundColor3=C.side tb.BorderSizePixel=0 tb.Parent=win
Instance.new("UICorner",tb).CornerRadius=UDim.new(0,12)
Instance.new("Frame",tb).Size=UDim2.new(1,0,0.5,0)
local tbFix=tb:FindFirstChildOfClass("Frame")
tbFix.Position=UDim2.new(0,0,0.5,0) tbFix.BackgroundColor3=C.side tbFix.BorderSizePixel=0

local tlTitle=Instance.new("TextLabel")
tlTitle.Size=UDim2.new(1,-50,1,0) tlTitle.Position=UDim2.new(0,14,0,0)
tlTitle.BackgroundTransparency=1 tlTitle.Text="🎯  Buhlal RPG"
tlTitle.TextColor3=C.txt tlTitle.TextSize=15 tlTitle.Font=Enum.Font.GothamBold
tlTitle.TextXAlignment=Enum.TextXAlignment.Left tlTitle.Parent=tb

local xB=Instance.new("TextButton")
xB.Size=UDim2.new(0,28,0,28) xB.Position=UDim2.new(1,-36,0,8)
xB.BackgroundColor3=C.red xB.Text="✕" xB.TextColor3=C.txt xB.TextSize=13
xB.Font=Enum.Font.GothamBold xB.Parent=tb
Instance.new("UICorner",xB).CornerRadius=UDim.new(0,6)

local drg,ds,sp0=false,nil,nil
tb.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then drg=true ds=i.Position sp0=win.Position end
end)
UserInputService.InputChanged:Connect(function(i)
    if drg and i.UserInputType==Enum.UserInputType.MouseMovement then
        local d=i.Position-ds
        win.Position=UDim2.new(sp0.X.Scale,sp0.X.Offset+d.X,sp0.Y.Scale,sp0.Y.Offset+d.Y)
    end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then drg=false end
end)

local sideW=105
local tabBar=Instance.new("Frame")
tabBar.Size=UDim2.new(0,sideW,1,-44) tabBar.Position=UDim2.new(0,0,0,44)
tabBar.BackgroundColor3=C.side tabBar.BorderSizePixel=0 tabBar.Parent=win
Instance.new("UICorner",tabBar).CornerRadius=UDim.new(0,12)
local tabFix=Instance.new("Frame",tabBar)
tabFix.Size=UDim2.new(0.5,0,1,0) tabFix.Position=UDim2.new(0.5,0,0,0)
tabFix.BackgroundColor3=C.side tabFix.BorderSizePixel=0
local tabList=Instance.new("Frame",tabBar)
tabList.Size=UDim2.new(1,0,1,0) tabList.BackgroundTransparency=1
local UIL=Instance.new("UIListLayout",tabList)
UIL.Padding=UDim.new(0,4) UIL.HorizontalAlignment=Enum.HorizontalAlignment.Center
UIL.SortOrder=Enum.SortOrder.LayoutOrder
local sp=Instance.new("Frame",tabList) sp.Size=UDim2.new(1,0,0,6) sp.BackgroundTransparency=1

local content=Instance.new("Frame")
content.Size=UDim2.new(1,-sideW,1,-84) content.Position=UDim2.new(0,sideW,0,44)
content.BackgroundTransparency=1 content.Parent=win

local sBar=Instance.new("Frame")
sBar.Size=UDim2.new(1,-sideW,0,40) sBar.Position=UDim2.new(0,sideW,1,-40)
sBar.BackgroundColor3=C.panel sBar.BorderSizePixel=0 sBar.Parent=win
Instance.new("UICorner",sBar).CornerRadius=UDim.new(0,10)
Instance.new("Frame",sBar).Size=UDim2.new(1,0,0,10)
sBar:FindFirstChildOfClass("Frame").BackgroundColor3=C.panel sBar:FindFirstChildOfClass("Frame").BorderSizePixel=0
statusLbl=Instance.new("TextLabel")
statusLbl.Size=UDim2.new(1,-12,1,0) statusLbl.Position=UDim2.new(0,10,0,0)
statusLbl.BackgroundTransparency=1 statusLbl.Text="⏸ Idle"
statusLbl.TextColor3=C.sub statusLbl.TextSize=12 statusLbl.Font=Enum.Font.GothamBold
statusLbl.TextXAlignment=Enum.TextXAlignment.Left statusLbl.Parent=sBar

local curTab=nil
local allTabs={}
local allPages={}

local function newTab(label,icon)
    local btn=Instance.new("TextButton")
    btn.Size=UDim2.new(0.9,0,0,34) btn.BackgroundColor3=C.bg btn.Text="" btn.Parent=tabList
    Instance.new("UICorner",btn).CornerRadius=UDim.new(0,8)
    local btxt=Instance.new("TextLabel")
    btxt.Size=UDim2.new(1,-6,1,0) btxt.Position=UDim2.new(0,6,0,0)
    btxt.BackgroundTransparency=1 btxt.Text=icon.." "..label
    btxt.TextColor3=C.sub btxt.TextSize=12 btxt.Font=Enum.Font.GothamBold
    btxt.TextXAlignment=Enum.TextXAlignment.Left btxt.Parent=btn
    local page=Instance.new("ScrollingFrame")
    page.Size=UDim2.new(1,0,1,0) page.BackgroundTransparency=1
    page.BorderSizePixel=0 page.ScrollBarThickness=3
    page.ScrollBarImageColor3=C.acc page.Visible=false page.Parent=content
    local layout=Instance.new("UIListLayout",page)
    layout.Padding=UDim.new(0,7)
    layout.HorizontalAlignment=Enum.HorizontalAlignment.Center
    layout.SortOrder=Enum.SortOrder.LayoutOrder
    local pad=Instance.new("UIPadding",page)
    pad.PaddingTop=UDim.new(0,8) pad.PaddingBottom=UDim.new(0,8)
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        page.CanvasSize=UDim2.new(0,0,0,layout.AbsoluteContentSize.Y+16)
    end)
    btn.MouseButton1Click:Connect(function()
        if curTab then
            curTab.btn.BackgroundColor3=C.bg
            curTab.lbl.TextColor3=C.sub
            curTab.pg.Visible=false
        end
        btn.BackgroundColor3=C.panel btxt.TextColor3=C.acc page.Visible=true
        curTab={btn=btn,lbl=btxt,pg=page}
    end)
    table.insert(allTabs,btn) table.insert(allPages,page)
    return page
end

local function togRow(page,label,init,cb)
    local row=Instance.new("Frame")
    row.Size=UDim2.new(0.93,0,0,36) row.BackgroundColor3=C.panel row.Parent=page
    Instance.new("UICorner",row).CornerRadius=UDim.new(0,8)
    local l=Instance.new("TextLabel")
    l.Size=UDim2.new(0.62,0,1,0) l.Position=UDim2.new(0,10,0,0)
    l.BackgroundTransparency=1 l.Text=label l.TextColor3=C.txt l.TextSize=12
    l.Font=Enum.Font.GothamMedium l.TextXAlignment=Enum.TextXAlignment.Left l.Parent=row
    local b=Instance.new("TextButton")
    b.Size=UDim2.new(0,48,0,22) b.Position=UDim2.new(1,-56,0.5,-11)
    b.BackgroundColor3=init and C.tOn or C.tOff
    b.Text=init and "ON" or "OFF" b.TextColor3=C.txt b.TextSize=10
    b.Font=Enum.Font.GothamBold b.Parent=row
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,5)
    local s=init
    b.MouseButton1Click:Connect(function()
        s=not s b.BackgroundColor3=s and C.tOn or C.tOff b.Text=s and "ON" or "OFF" cb(s)
    end)
end

local function sldRow(page,label,mn,mx,init,fmt,cb)
    local row=Instance.new("Frame")
    row.Size=UDim2.new(0.93,0,0,48) row.BackgroundColor3=C.panel row.Parent=page
    Instance.new("UICorner",row).CornerRadius=UDim.new(0,8)
    local l=Instance.new("TextLabel")
    l.Size=UDim2.new(0.58,0,0,22) l.Position=UDim2.new(0,10,0,2)
    l.BackgroundTransparency=1 l.Text=label l.TextColor3=C.txt l.TextSize=11
    l.Font=Enum.Font.GothamMedium l.TextXAlignment=Enum.TextXAlignment.Left l.Parent=row
    local vl=Instance.new("TextLabel")
    vl.Size=UDim2.new(0.36,0,0,22) vl.Position=UDim2.new(0.6,0,0,2)
    vl.BackgroundTransparency=1 vl.Text=string.format(fmt,init) vl.TextColor3=C.acc
    vl.TextSize=11 vl.Font=Enum.Font.GothamBold
    vl.TextXAlignment=Enum.TextXAlignment.Right vl.Parent=row
    local tr=Instance.new("Frame")
    tr.Size=UDim2.new(0.9,0,0,4) tr.Position=UDim2.new(0.05,0,0,30)
    tr.BackgroundColor3=C.tOff tr.BorderSizePixel=0 tr.Parent=row
    Instance.new("UICorner",tr).CornerRadius=UDim.new(1,0)
    local ratio=(init-mn)/(mx-mn)
    local fi=Instance.new("Frame")
    fi.Size=UDim2.new(ratio,0,1,0) fi.BackgroundColor3=C.acc fi.BorderSizePixel=0 fi.Parent=tr
    Instance.new("UICorner",fi).CornerRadius=UDim.new(1,0)
    local th=Instance.new("TextButton")
    th.Size=UDim2.new(0,12,0,12) th.AnchorPoint=Vector2.new(0.5,0.5)
    th.Position=UDim2.new(ratio,0,0.5,0) th.BackgroundColor3=C.txt
    th.Text="" th.BorderSizePixel=0 th.Parent=tr
    Instance.new("UICorner",th).CornerRadius=UDim.new(1,0)
    local sld=false
    th.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then sld=true end end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then sld=false end end)
    UserInputService.InputChanged:Connect(function(i)
        if not sld or i.UserInputType~=Enum.UserInputType.MouseMovement then return end
        local ta=tr.AbsolutePosition local ts=tr.AbsoluteSize
        local r=math.clamp((i.Position.X-ta.X)/ts.X,0,1)
        local v=math.floor((mn+(mx-mn)*r)*100+0.5)/100
        fi.Size=UDim2.new(r,0,1,0) th.Position=UDim2.new(r,0,0.5,0)
        vl.Text=string.format(fmt,v) cb(v)
    end)
end

-- ============================================
-- TABS INITIALIZATION
-- ============================================
local pCombat=newTab("Combat","🔫")
local pAI=newTab("AI","🧠")
local pTarget=newTab("Target","🎯")
local pVisual=newTab("Visuals","👁")
local pConfig=newTab("Config","⚙")

-- Combat Page
togRow(pCombat,"Enable Aimbot",CFG.AimEnabled,function(v) CFG.AimEnabled=v SaveConfig() end)
togRow(pCombat,"Ground Aim (RPG)",CFG.GroundAim,function(v) CFG.GroundAim=v SaveConfig() end)
sldRow(pCombat,"Projectile Speed",10,500,CFG.ProjSpeed,"%.0f",function(v) CFG.ProjSpeed=v SaveConfig() end)
sldRow(pCombat,"Lock Distance (px)",5,100,CFG.LockDist,"%.0f",function(v) CFG.LockDist=v SaveConfig() end)

-- AI Page
sldRow(pAI,"Prediction Strength",0,3,CFG.PredictStr,"%.2f",function(v) CFG.PredictStr=v SaveConfig() end)
sldRow(pAI,"Camera Smoothness",0.01,1,CFG.Smoothness,"%.2f",function(v) CFG.Smoothness=v SaveConfig() end)

-- Target Page
togRow(pTarget,"Wall Check",CFG.WallCheck,function(v) CFG.WallCheck=v SaveConfig() end)
togRow(pTarget,"Team Check",CFG.TeamCheck,function(v) CFG.TeamCheck=v SaveConfig() end)
togRow(pTarget,"Sticky Lock",CFG.StickyLock,function(v) CFG.StickyLock=v if not v then lockedTarget=nil end SaveConfig() end)
sldRow(pTarget,"FOV Radius",20,500,CFG.FOV,"%.0f",function(v) CFG.FOV=v SaveConfig() end)
sldRow(pTarget,"Max Distance (m)",10,800,CFG.MaxDist,"%.0f",function(v) CFG.MaxDist=v SaveConfig() end)

-- Visuals Page
togRow(pVisual,"Enable ESP",CFG.ESPEnabled,function(v) CFG.ESPEnabled=v SaveConfig() end)
togRow(pVisual,"Inventory ESP",CFG.ESPInvEnabled,function(v)
    CFG.ESPInvEnabled=v
    for _,p in ipairs(Players:GetPlayers()) do if p~=LP then task.spawn(updateInventoryESP,p) end end
    SaveConfig()
end)
togRow(pVisual,"Show FOV Circle",CFG.ShowFOV,function(v) CFG.ShowFOV=v SaveConfig() end)
togRow(pVisual,"Ground Hit Ring",CFG.ShowGndCircle,function(v) CFG.ShowGndCircle=v SaveConfig() end)
togRow(pVisual,"Movement Trail",CFG.ShowTrail,function(v) CFG.ShowTrail=v SaveConfig() end)
togRow(pVisual,"Direction Arrow",CFG.ShowArrow,function(v) CFG.ShowArrow=v SaveConfig() end)
togRow(pVisual,"Confidence Bar",CFG.ShowConf,function(v) CFG.ShowConf=v SaveConfig() end)

-- Config Page
togRow(pConfig,"Auto Save Config",CFG.AutoSave,function(v) CFG.AutoSave=v SaveConfig() end)

-- BOOTSTRAP TABS
allTabs[1].BackgroundColor3=C.panel
allTabs[1]:FindFirstChildOfClass("TextLabel").TextColor3=C.acc
allPages[1].Visible=true
curTab={btn=allTabs[1],lbl=allTabs[1]:FindFirstChildOfClass("TextLabel"),pg=allPages[1]}

xB.MouseButton1Click:Connect(function()
    CFG.AimEnabled=false CFG.ESPEnabled=false CFG.ESPInvEnabled=false
    fovC:Remove() pdot:Remove() aline:Remove()
    arrMain:Remove() arrL:Remove() arrR:Remove()
    confBg:Remove() confFill:Remove()
    for _,l in ipairs(RING) do pcall(function() l:Remove() end) end
    for _,t in ipairs(TRAIL) do pcall(function() t:Remove() end) end
    for _,e in pairs(ESP) do for _,o in pairs(e) do pcall(function() o:Remove() end) end end
    for _,bb in pairs(BillboardCache) do pcall(function() bb:Destroy() end) end
    sg:Destroy()
end)
