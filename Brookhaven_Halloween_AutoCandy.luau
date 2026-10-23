-- Brookhaven Halloween 2026 · Candy Corn
-- Uses Brookhaven's normal proximity collector; does not invoke the collection remote directly.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local env = getgenv()
local previous = env.__BrookhavenCandyState
if previous and previous.cleanup then
    pcall(previous.cleanup)
end

local state = {
    alive = true,
    auto = false,
    autoRespawn = true,
    antiSit = true,
    antiFall = true,
    freeze = false,
    generation = 0,
    connections = {},
    characterConnections = {},
    anchoredRoots = {},
    lastSafeCFrame = nil,
    recovering = false,
    ui = nil,
    uiConnections = {},
    currentStatus = "Готов к запуску",
    lastCandyResetAt = -100,
}
env.__BrookhavenCandyState = state

local player = Players.LocalPlayer
local updateUI

local function connect(list, connection)
    table.insert(list, connection)
    return connection
end

local function disconnectAll(list)
    for _, connection in ipairs(list) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(list)
end

local function parts()
    local character = player.Character
    if not character then return nil, nil, nil end
    return character, character:FindFirstChild("HumanoidRootPart"), character:FindFirstChildOfClass("Humanoid")
end

local function say(message)
    if not state.alive then return end
    state.currentStatus = message
    if updateUI then pcall(updateUI, message) end
    print("[Candy Corn] " .. message)
end

local function getEventData()
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local client = modules and modules:FindFirstChild("Client")
    local dataFolder = client and client:FindFirstChild("Data")
    local moduleInstance = dataFolder and dataFolder:FindFirstChild("ReplicatedDataController")
    if not moduleInstance then return nil end

    local requireModule = require
    local ok, controller = pcall(requireModule, moduleInstance :: ModuleScript)
    if not ok or not controller or not controller.clientReplica then return nil end
    local data = controller.clientReplica.Data
    local events = data and data.LiveOpsEventData
    return events and events.Halloween2026 or nil
end

local function weekFolder(eventData)
    local hunt = workspace:FindFirstChild("CandyCornHunt")
    if not hunt or not eventData or typeof(eventData.HuntWeek) ~= "number" then return nil, nil end

    local week = eventData.HuntWeek
    local folder = hunt:FindFirstChild("Week" .. tostring(week))
    local activeWeek = hunt:GetAttribute("ActiveWeek")
    if not folder or (typeof(activeWeek) == "number" and activeWeek ~= week) then
        return nil, nil
    end
    return folder, week
end

local function isCollected(eventData, name)
    local collected = eventData and eventData.HuntCollected
    return collected ~= nil and collected[name] == true
end

local function countCollected(eventData, folder)
    local count = 0
    for _, candy in ipairs(CollectionService:GetTagged("CandyCorn26")) do
        if candy:IsDescendantOf(folder) and isCollected(eventData, candy.Name) then
            count += 1
        end
    end
    return count
end

-- Returns true only after the server actually refreshes the replicated hunt.
-- "rescan" means another collectible appeared before the reset.
local function useOfficialRespawn(folder, week, runId, considered)
    if not state.autoRespawn or not state.alive or not state.auto
        or state.generation ~= runId then return false end

    local data = getEventData()
    local activeFolder, activeWeek = weekFolder(data)
    if not data or not folder or activeFolder ~= folder or activeWeek ~= week then
        say("Не удалось подтвердить активную неделю; сброс отменён")
        return false
    end

    local tagged = 0
    local collectedBefore = {}
    for _, candy in ipairs(CollectionService:GetTagged("CandyCorn26")) do
        if candy:IsA("BasePart") and candy:IsDescendantOf(folder) then
            tagged += 1
            if isCollected(data, candy.Name) then
                collectedBefore[candy.Name] = true
            elseif not considered or not considered[candy.Name] then
                say("Появились новые доступные конфеты · пересканирую маршрут")
                return "rescan"
            end
        end
    end
    if tagged == 0 then
        say("Конфеты не загружены в мире; автосброс отменён")
        return false
    end

    -- Never spin the reset remote if progress is not refreshed by the server.
    local sinceLastReset = os.clock() - (state.lastCandyResetAt or -100)
    if sinceLastReset < 3 then task.wait(3 - sinceLastReset) end
    if not state.alive or not state.auto or not state.autoRespawn
        or state.generation ~= runId then return false end

    data = getEventData()
    activeFolder, activeWeek = weekFolder(data)
    if not data or activeFolder ~= folder or activeWeek ~= week then return false end
    for _, candy in ipairs(CollectionService:GetTagged("CandyCorn26")) do
        if candy:IsA("BasePart") and candy:IsDescendantOf(folder)
            and not isCollected(data, candy.Name)
            and (not considered or not considered[candy.Name]) then
            say("Найдены новые конфеты · продолжаю сбор")
            return "rescan"
        end
    end

    -- 58/60 is allowed here: every known candidate has been attempted.
    state.lastCandyResetAt = os.clock()
    say("Доступные конфеты закончились · вызываю сброс (независимо от счётчика)")
    local ok, response = pcall(function()
        return ReplicatedStorage.Remotes.Halloween2026_ResetCandyCornHunt:InvokeServer()
    end)
    if not ok or response == false then
        say("Сброс не принят сервером: " .. tostring(response))
        return false
    end

    local deadline = os.clock() + 10
    repeat
        task.wait(0.25)
        if not state.alive or not state.auto or not state.autoRespawn
            or state.generation ~= runId then return false end

        local updated = getEventData()
        local nextFolder, nextWeek = weekFolder(updated)
        if nextFolder ~= folder or nextWeek ~= week then
            say("Активная неделя изменилась · остановлено")
            return false
        end

        -- Previously collected candies must become uncollected; otherwise
        -- the 2 already-missing candies at 58/60 look like a false success.
        if updated and type(updated.HuntCollected) == "table" then
            for candyName in pairs(collectedBefore) do
                if not isCollected(updated, candyName) then
                    say("Сервер обновил прогресс · начинаю новый сбор")
                    return true
                end
            end
        end
    until os.clock() >= deadline

    say("Вызов сброса выполнен, но прогресс не изменился; проверь ограничение сервера")
    return false
end

local function updateStat()
    if updateUI then pcall(updateUI) end
end

local function setAnchored(root, enabled)
    if not root then return end
    if enabled then
        if state.anchoredRoots[root] == nil then
            state.anchoredRoots[root] = root.Anchored
        end
        root.Anchored = true
    else
        local original = state.anchoredRoots[root]
        if original ~= nil then
            root.Anchored = original
            state.anchoredRoots[root] = nil
        end
    end
end

local function watchCharacter(character)
    disconnectAll(state.characterConnections)
    local root = character:WaitForChild("HumanoidRootPart", 10)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not state.alive or not root or not humanoid then return end

    if not state.lastSafeCFrame then
        state.lastSafeCFrame = root.CFrame
    end

    connect(state.characterConnections, humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
        if state.alive and state.antiSit and humanoid.Parent and humanoid.Sit then
            humanoid.Sit = false
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
    end))

    if state.freeze then setAnchored(root, true) end
end

local function recoverIfFallen(root, humanoid)
    if not state.antiFall or state.recovering or root.Position.Y > -30 then return end
    local safe = state.lastSafeCFrame
    if not safe then return end

    state.recovering = true
    root.Anchored = false
    root.CFrame = safe + Vector3.new(0, 4, 0)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    if humanoid then
        pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end
    say("Персонаж восстановлен после падения")
    task.delay(1.2, function()
        state.recovering = false
        local _, currentRoot = parts()
        if state.freeze and currentRoot then setAnchored(currentRoot, true) end
    end)
end

local function hasGroundSupport(item)
    if not item or not item:IsA("BasePart") then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { item, player.Character }
    local origin = item.Position + Vector3.new(0, 4, 0)
    local hit = workspace:Raycast(origin, Vector3.new(0, -24, 0), params)
    if not hit or hit.Normal.Y < 0.45 then return false end
    return item.Position.Y - hit.Position.Y <= 8
end

local function collectPass(runId)
    local data = getEventData()
    local folder, week = weekFolder(data)
    if not data or not folder then
        say("Не удалось прочитать активную неделю события")
        return
    end

    local character, root = parts()
    if not character or not root then
        say("Персонаж ещё загружается")
        return
    end

    local startCFrame = state.lastSafeCFrame or root.CFrame
    local candies = {}
    local considered = {}
    for _, item in ipairs(CollectionService:GetTagged("CandyCorn26")) do
        if item:IsA("BasePart") and item:IsDescendantOf(folder) and not isCollected(data, item.Name) then
            considered[item.Name] = true
            table.insert(candies, item)
        end
    end

    local skippedUnsafe = 0
    for i = #candies, 1, -1 do
        local item = candies[i]
        if item.Position.Y <= -30 and not hasGroundSupport(item) then
            say("Пропускаю " .. item.Name .. ": под ней нет безопасной поверхности")
            table.remove(candies, i)
            skippedUnsafe += 1
        end
    end

    if #candies == 0 then
        if skippedUnsafe > 0 then
            say("Остались только небезопасные точки; проверяю сброс конфет")
        else
            say("В неделе " .. week .. " больше нет доступных конфет")
        end
        return "empty", folder, week, considered
    end
    local total = #candies
    local visited = 0
    say("Неделя " .. week .. ": найдено " .. total .. " ещё не собранных")

    local planned = #candies
    local completed = true
    for _ = 1, planned do
        if not state.alive or not state.auto or state.freeze or runId ~= state.generation then
            completed = false
            break
        end

        local beforeData = getEventData()
        for i = #candies, 1, -1 do
            local item = candies[i]
            if not item.Parent or isCollected(beforeData, item.Name) then
                table.remove(candies, i)
            end
        end
        if #candies == 0 then break end

        local _, routeRoot = parts()
        if not routeRoot then
            completed = false
            break
        end
        table.sort(candies, function(a, b)
            local da = (a.Position - routeRoot.Position).Magnitude
            local db = (b.Position - routeRoot.Position).Magnitude
            if da == db then return a.Name < b.Name end
            return da < db
        end)
        local candy = table.remove(candies, 1)
        local latest = getEventData()
        local currentFolder, currentWeek = weekFolder(latest)
        if currentWeek ~= week or currentFolder ~= folder then
            say("Неделя события изменилась; остановлено")
            completed = false
            break
        end

        -- Read live replicated progress again immediately before each teleport.
        if candy.Parent and not isCollected(latest, candy.Name) then
            local _, currentRoot, humanoid = parts()
            if not currentRoot then
                say("Персонаж не готов; остановлено")
                completed = false
                break
            end

            if humanoid and state.antiSit and humanoid.Sit then humanoid.Sit = false end

            local safe = state.lastSafeCFrame or currentRoot.CFrame
            currentRoot.Anchored = false
            currentRoot.CFrame = CFrame.new(candy.Position + Vector3.new(0, 2.5, 0)) * currentRoot.CFrame.Rotation
            currentRoot.AssemblyLinearVelocity = Vector3.zero
            currentRoot.AssemblyAngularVelocity = Vector3.zero
            visited += 1
            say("Проверяю " .. visited .. "/" .. total .. ": " .. candy.Name)

            local confirmed = false
            local deadline = os.clock() + 0.85
            repeat
                task.wait(0.1)
                if not state.alive or not state.auto or runId ~= state.generation then break end
                latest = getEventData()
                confirmed = isCollected(latest, candy.Name)
            until confirmed or os.clock() >= deadline

            if not confirmed and state.alive and state.auto and runId == state.generation then
                latest = getEventData()
                if candy.Parent and not isCollected(latest, candy.Name) then
                    currentRoot = select(2, parts())
                    if currentRoot then
                        currentRoot.CFrame =
                            CFrame.new(candy.Position + Vector3.new(0, 1.8, 0)) * currentRoot.CFrame.Rotation
                        currentRoot.AssemblyLinearVelocity = Vector3.zero
                        local retryDeadline = os.clock() + 0.85
                        repeat
                            task.wait(0.1)
                            if not state.alive or not state.auto or runId ~= state.generation then break end
                            latest = getEventData()
                            confirmed = isCollected(latest, candy.Name)
                        until confirmed or os.clock() >= retryDeadline
                    end
                end
            end

            if confirmed then
                say("Засчитано: " .. candy.Name)
            else
                say("Сервер пока не подтвердил: " .. candy.Name)
            end
            updateStat()

            if not state.alive or not state.auto or runId ~= state.generation then
                local _, returnRoot = parts()
                if returnRoot then returnRoot.CFrame = safe end
                completed = false
                break
            end
            task.wait(0.05)
        end
    end

    if state.alive and state.auto and not state.freeze and completed
        and runId == state.generation then
        local _, returnRoot = parts()
        if returnRoot and not state.freeze then
            returnRoot.CFrame = startCFrame
            returnRoot.AssemblyLinearVelocity = Vector3.zero
        end
        updateStat()

        local finalData = getEventData()
        local finalFolder, finalWeek = weekFolder(finalData)
        if not finalData or finalFolder ~= folder or finalWeek ~= week then
            say("Данные недели изменились · сброс отменён")
            return "stopped", folder, week
        end
        local remaining = 0
        if finalData and finalFolder then
            for _, item in ipairs(CollectionService:GetTagged("CandyCorn26")) do
                if item:IsDescendantOf(finalFolder) and not isCollected(finalData, item.Name) then
                    remaining += 1
                end
            end
        end

        say("Обход завершён · осталось " .. remaining)
        -- Every available target was visited. Even if progress is 58/60,
        -- no new candidates remain on this pass, so try the reset remote.
        return "empty", finalFolder, week, considered
    end
    return "stopped", folder, week
end

function state.cleanup()
    if not state.alive then return end
    state.alive = false
    state.auto = false
    state.generation += 1

    disconnectAll(state.characterConnections)
    disconnectAll(state.connections)
    disconnectAll(state.uiConnections)

    for root, originalAnchored in pairs(state.anchoredRoots) do
        if root and root.Parent then
            pcall(function() root.Anchored = originalAnchored end)
        end
    end
    table.clear(state.anchoredRoots)

    if state.ui then
        local ui = state.ui
        for _, effect in ipairs(ui.tweens) do
            pcall(function() effect:Cancel() end)
        end
        if ui.progressTween then pcall(function() ui.progressTween:Cancel() end) end
        if ui.pulseTween then pcall(function() ui.pulseTween:Cancel() end) end
        if ui.buttonTween then pcall(function() ui.buttonTween:Cancel() end) end
        pcall(function() ui.gui:Destroy() end)
        state.ui = nil
    end
end

-- One-button, native Roblox interface. No GUI library or external HTTP request.
local function setAuto(enabled)
    if not state.alive then return end
    enabled = enabled == true
    if state.auto == enabled then return end
    if enabled and state.freeze then
        say("Сначала сними закрепление персонажа")
        return
    end

    state.auto = enabled
    state.generation += 1
    if not enabled then
        say("Сбор остановлен")
        return
    end

    say("Запускаю сбор конфет...")
    local runId = state.generation
    task.spawn(function()
        local ok, err = pcall(function()
            while state.alive and state.auto and runId == state.generation do
                local result, folder, week, considered = collectPass(runId)
                if result ~= "empty" or not state.auto then break end
                local resetResult = useOfficialRespawn(folder, week, runId, considered)
                if resetResult == "rescan" then
                    task.wait(0.25)
                elseif resetResult ~= true then
                    break
                end
            end
        end)
        if not ok and state.alive then
            say("Ошибка сбора: " .. tostring(err))
        end
        if state.alive and runId == state.generation then
            state.auto = false
            if updateUI then pcall(updateUI) end
        end
    end)
end

local function createUI()
    local parent = player:WaitForChild("PlayerGui")
    if type(gethui) == "function" then
        local ok, hidden = pcall(gethui)
        if ok and hidden then parent = hidden end
    end

    local function make(class, holder, props)
        local obj = Instance.new(class)
        for property, value in pairs(props) do
            obj[property] = value
        end
        obj.Parent = holder
        return obj
    end

    local function rounded(holder, radius)
        make("UICorner", holder, { CornerRadius = UDim.new(0, radius) })
    end

    local charcoal = Color3.fromRGB(15, 17, 23)
    local accent = Color3.fromRGB(255, 169, 101)
    local white = Color3.fromRGB(247, 246, 250)
    local muted = Color3.fromRGB(146, 147, 161)
    local tweenOut = TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

    local gui = make("ScreenGui", parent, {
        Name = "AtomickCandyMinimal",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9000,
    })

    local dock = make("Frame", gui, {
        Name = "Dock",
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.68, 24),
        Size = UDim2.fromOffset(336, 226),
    })
    local scale = make("UIScale", dock, { Scale = 1 })

    local shadow = make("Frame", dock, {
        Name = "Shadow",
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.57,
        Position = UDim2.fromOffset(0, 12),
        Size = UDim2.fromScale(1, 1),
        BorderSizePixel = 0,
        ZIndex = 1,
    })
    rounded(shadow, 24)

    local panel = make("Frame", dock, {
        Name = "Panel",
        BackgroundColor3 = charcoal,
        BackgroundTransparency = 0.02,
        Size = UDim2.fromScale(1, 1),
        BorderSizePixel = 0,
        ClipsDescendants = true,
        ZIndex = 2,
    })
    rounded(panel, 22)
    make("UIGradient", panel, {
        Rotation = 35,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(27, 27, 38)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 16, 22)),
        }),
    })
    local panelOutline = make("UIStroke", panel, {
        Color = Color3.fromRGB(101, 84, 92),
        Thickness = 1,
        Transparency = 0.55,
    })

    local accentLine = make("Frame", panel, {
        BackgroundColor3 = accent,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(20, 0),
        Size = UDim2.fromOffset(60, 3),
        ZIndex = 3,
    })
    rounded(accentLine, 3)
    make("UIGradient", accentLine, {
        Color = ColorSequence.new(
            Color3.fromRGB(255, 205, 119),
            Color3.fromRGB(255, 106, 92)
        ),
    })

    -- The title is also a drag handle (touch + mouse).
    local dragHandle = make("Frame", panel, {
        Name = "DragHandle",
        BackgroundTransparency = 1,
        Active = true,
        Position = UDim2.fromOffset(18, 13),
        Size = UDim2.fromOffset(300, 41),
        ZIndex = 4,
    })
    make("TextLabel", dragHandle, {
        BackgroundTransparency = 1,
        Text = "ATOMICK",
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromOffset(140, 22),
        ZIndex = 5,
    })
    make("TextLabel", dragHandle, {
        BackgroundTransparency = 1,
        Text = "HALLOWEEN  /  2026",
        Font = Enum.Font.GothamMedium,
        TextSize = 9,
        TextColor3 = muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(1, 22),
        Size = UDim2.fromOffset(170, 13),
        ZIndex = 5,
    })

    local pill = make("Frame", dragHandle, {
        BackgroundColor3 = Color3.fromRGB(39, 39, 49),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(219, 3),
        Size = UDim2.fromOffset(79, 25),
        ZIndex = 5,
    })
    rounded(pill, 13)
    local light = make("Frame", pill, {
        BackgroundColor3 = accent,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 9),
        Size = UDim2.fromOffset(7, 7),
        ZIndex = 6,
    })
    rounded(light, 7)
    local pillText = make("TextLabel", pill, {
        BackgroundTransparency = 1,
        Text = "READY",
        TextColor3 = Color3.fromRGB(210, 204, 209),
        TextSize = 9,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(25, 3),
        Size = UDim2.fromOffset(51, 19),
        ZIndex = 6,
    })

    local progressNumber = make("TextLabel", panel, {
        BackgroundTransparency = 1,
        Text = "— / —",
        Font = Enum.Font.GothamBold,
        TextSize = 32,
        TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(21, 65),
        Size = UDim2.fromOffset(244, 40),
        ZIndex = 4,
    })
    local progressName = make("TextLabel", panel, {
        BackgroundTransparency = 1,
        Text = "CANDY CORN  ·  EVENT",
        Font = Enum.Font.GothamMedium,
        TextSize = 10,
        TextColor3 = muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(22, 104),
        Size = UDim2.fromOffset(290, 14),
        ZIndex = 4,
    })

    local track = make("Frame", panel, {
        BackgroundColor3 = Color3.fromRGB(48, 48, 60),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(20, 126),
        Size = UDim2.fromOffset(296, 5),
        ZIndex = 4,
    })
    rounded(track, 5)
    local fill = make("Frame", track, {
        BackgroundColor3 = accent,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1),
        ZIndex = 5,
    })
    rounded(fill, 5)
    make("UIGradient", fill, {
        Color = ColorSequence.new(
            Color3.fromRGB(255, 200, 114),
            Color3.fromRGB(255, 111, 84)
        ),
    })

    -- Only one GuiButton exists in the entire interface.
    local button = make("TextButton", panel, {
        Name = "StartStop",
        Text = "▶   НАЧАТЬ СБОР",
        TextColor3 = Color3.fromRGB(32, 22, 22),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        AutoButtonColor = false,
        BackgroundColor3 = Color3.fromRGB(255, 157, 98),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(20, 148),
        Size = UDim2.fromOffset(296, 49),
        ZIndex = 4,
    })
    rounded(button, 13)
    local buttonStroke = make("UIStroke", button, {
        Color = Color3.fromRGB(255, 216, 156),
        Thickness = 1,
        Transparency = 0.5,
    })
    local buttonGradient = make("UIGradient", button, {
        Rotation = 0,
        Color = ColorSequence.new(
            Color3.fromRGB(255, 194, 114),
            Color3.fromRGB(255, 123, 86)
        ),
    })
    local buttonScale = make("UIScale", button, { Scale = 1 })

    local status = make("TextLabel", panel, {
        BackgroundTransparency = 1,
        Text = "Готов к запуску",
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = muted,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.fromOffset(20, 200),
        Size = UDim2.fromOffset(296, 18),
        ZIndex = 4,
    })

    local ui = {
        gui = gui,
        dock = dock,
        scale = scale,
        panelOutline = panelOutline,
        number = progressNumber,
        progressName = progressName,
        fill = fill,
        button = button,
        buttonStroke = buttonStroke,
        buttonGradient = buttonGradient,
        buttonScale = buttonScale,
        pill = pill,
        pillText = pillText,
        light = light,
        status = status,
        tweens = {},
        lastProgress = -1,
        running = false,
    }
    state.ui = ui

    local function animateButton(value)
        if ui.buttonTween then ui.buttonTween:Cancel() end
        ui.buttonTween = TweenService:Create(buttonScale, tweenOut, { Scale = value })
        ui.buttonTween:Play()
    end

    connect(state.uiConnections, button.MouseEnter:Connect(function()
        animateButton(1.025)
    end))
    connect(state.uiConnections, button.MouseLeave:Connect(function()
        animateButton(1)
    end))
    connect(state.uiConnections, button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            animateButton(0.975)
        end
    end))
    connect(state.uiConnections, button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            animateButton(1)
        end
    end))
    connect(state.uiConnections, button.Activated:Connect(function()
        setAuto(not state.auto)
    end))

    local dragging = false
    local dragStart
    local dockStart
    connect(state.uiConnections, dragHandle.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        dragStart = input.Position
        dockStart = dock.Position
        connect(state.uiConnections, input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end))
    end))
    connect(state.uiConnections, UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - dragStart
        dock.Position = UDim2.new(
            dockStart.X.Scale, dockStart.X.Offset + delta.X,
            dockStart.Y.Scale, dockStart.Y.Offset + delta.Y
        )
    end))

    local entrance = TweenService:Create(dock, TweenInfo.new(
        0.58, Enum.EasingStyle.Quint, Enum.EasingDirection.Out
    ), { Position = UDim2.new(0.5, 0, 0.68, 0) })
    table.insert(ui.tweens, entrance)
    entrance:Play()

    local borderTween = TweenService:Create(panelOutline, TweenInfo.new(
        2.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true
    ), { Transparency = 0.3 })
    table.insert(ui.tweens, borderTween)
    borderTween:Play()
end

updateUI = function(message)
    if not state.alive or not state.ui then return end
    local ui = state.ui
    if message then state.currentStatus = message end

    local view = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
    if view then
        ui.scale.Scale = math.min(1, math.max(0.68, (view.X - 24) / 336))
    end

    local data = getEventData()
    local folder, week = weekFolder(data)
    local collected, total = 0, 0
    if data and folder then
        collected = countCollected(data, folder)
        for _, candy in ipairs(CollectionService:GetTagged("CandyCorn26")) do
            if candy:IsA("BasePart") and candy:IsDescendantOf(folder) then
                total += 1
            end
        end
    end

    ui.number.Text = total > 0 and string.format("%d / %d", collected, total) or "— / —"
    ui.progressName.Text = week and ("CANDY CORN  ·  WEEK " .. tostring(week))
        or "CANDY CORN  ·  EVENT"

    local progress = total > 0 and math.clamp(collected / total, 0, 1) or 0
    if math.abs(progress - ui.lastProgress) > 0.001 then
        ui.lastProgress = progress
        if ui.progressTween then ui.progressTween:Cancel() end
        ui.progressTween = TweenService:Create(ui.fill, TweenInfo.new(
            0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out
        ), { Size = UDim2.fromScale(progress, 1) })
        ui.progressTween:Play()
    end

    ui.status.Text = state.currentStatus
    local running = state.auto
    if running ~= ui.running then
        ui.running = running
        ui.pillText.Text = running and "ACTIVE" or "READY"
        ui.pillText.TextColor3 = running and Color3.fromRGB(255, 193, 124)
            or Color3.fromRGB(210, 204, 209)
        ui.pill.BackgroundColor3 = running and Color3.fromRGB(63, 43, 42)
            or Color3.fromRGB(39, 39, 49)
        ui.button.Text = running and "■   ОСТАНОВИТЬ" or "▶   НАЧАТЬ СБОР"
        ui.button.TextColor3 = running and Color3.fromRGB(255, 225, 209)
            or Color3.fromRGB(32, 22, 22)
        ui.buttonGradient.Color = running and ColorSequence.new(
            Color3.fromRGB(85, 56, 60), Color3.fromRGB(55, 45, 59)
        ) or ColorSequence.new(
            Color3.fromRGB(255, 194, 114), Color3.fromRGB(255, 123, 86)
        )
        ui.buttonStroke.Color = running and Color3.fromRGB(179, 113, 103)
            or Color3.fromRGB(255, 216, 156)

        if ui.pulseTween then ui.pulseTween:Cancel(); ui.pulseTween = nil end
        ui.light.BackgroundTransparency = 0
        if running then
            ui.pulseTween = TweenService:Create(ui.light, TweenInfo.new(
                0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true
            ), { BackgroundTransparency = 0.7 })
            ui.pulseTween:Play()
        end
    end
end

createUI()
updateUI()
connect(state.connections, player.CharacterAdded:Connect(function(character)
    task.spawn(watchCharacter, character)
end))
if player.Character then task.spawn(watchCharacter, player.Character) end

local lastSafetyCheck = 0
connect(state.connections, RunService.Heartbeat:Connect(function()
    if not state.alive then return end
    local now = os.clock()
    if now - lastSafetyCheck < 0.12 then return end
    lastSafetyCheck = now
    if now - (state.lastUIRefresh or 0) >= 0.7 then
        state.lastUIRefresh = now
        if updateUI then pcall(updateUI) end
    end

    local _, root, humanoid = parts()
    if not root then return end

    if state.antiSit and humanoid and humanoid.Sit then
        humanoid.Sit = false
    end

    if state.antiFall then
        if humanoid and humanoid.FloorMaterial ~= Enum.Material.Air and root.Position.Y > -10 then
            state.lastSafeCFrame = root.CFrame
        end
        recoverIfFallen(root, humanoid)
    end

    if state.freeze then setAnchored(root, true) end
end))

say("Готов к сбору · нажми кнопку запуска")
