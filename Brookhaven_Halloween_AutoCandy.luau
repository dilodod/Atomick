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
        local object = Instance.new(class)
        for k, v in pairs(props) do object[k] = v end
        object.Parent = holder
        return object
    end
    local function round(holder, radius)
        make("UICorner", holder, {CornerRadius = UDim.new(0, radius)})
    end
    local gui = make("ScreenGui", parent, {
        Name = "AtomickCandyBar", ResetOnSpawn = false,
        IgnoreGuiInset = true, DisplayOrder = 9000,
    })
    local dock = make("Frame", gui, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.82, 15),
        Size = UDim2.fromOffset(330, 52),
        BackgroundTransparency = 1,
    })
    local scale = make("UIScale", dock, {Scale = 1})
    local bar = make("Frame", dock, {
        BackgroundColor3 = Color3.fromRGB(18, 20, 29),
        BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
        ClipsDescendants = true,
    })
    round(bar, 16)
    make("UIStroke", bar, {
        Color = Color3.fromRGB(100, 108, 135),
        Transparency = 0.45, Thickness = 1,
    })
    make("UIGradient", bar, {
        Color = ColorSequence.new(
            Color3.fromRGB(32, 33, 46),
            Color3.fromRGB(15, 18, 27)
        ), Rotation = 12,
    })
    local accent = make("Frame", bar, {
        BackgroundColor3 = Color3.fromRGB(255, 173, 106),
        BorderSizePixel = 0, Position = UDim2.fromOffset(0, 9),
        Size = UDim2.fromOffset(3, 34),
    })
    round(accent, 3)

    -- One horizontal line: action | live count or centered Telegram channel.
    local button = make("TextButton", bar, {
        Name = "StartStop", AutoButtonColor = false,
        Text = "START", Font = Enum.Font.GothamBold,
        TextSize = 12, TextColor3 = Color3.fromRGB(30, 24, 25),
        BackgroundColor3 = Color3.fromRGB(255, 180, 113),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(8, 7),
        Size = UDim2.fromOffset(100, 38),
    })
    round(button, 11)
    local buttonScale = make("UIScale", button, {Scale = 1})
    local buttonGradient = make("UIGradient", button, {
        Color = ColorSequence.new(
            Color3.fromRGB(255, 206, 139),
            Color3.fromRGB(255, 142, 101)
        ),
    })
    local divider = make("Frame", bar, {
        BackgroundColor3 = Color3.fromRGB(79, 82, 103),
        BackgroundTransparency = 0.4, BorderSizePixel = 0,
        Position = UDim2.fromOffset(116, 12),
        Size = UDim2.fromOffset(1, 28),
    })
    local right = make("Frame", bar, {
        BackgroundTransparency = 1, Active = true,
        Position = UDim2.fromOffset(124, 0),
        Size = UDim2.fromOffset(196, 52),
    })
    local channel = make("TextLabel", right, {
        BackgroundTransparency = 1,
        Text = "✈  @AT3M3", Font = Enum.Font.GothamBold,
        TextSize = 15, TextColor3 = Color3.fromRGB(143, 209, 255),
        TextXAlignment = Enum.TextXAlignment.Center,
        Size = UDim2.fromScale(1, 1),
    })
    local count = make("TextLabel", right, {
        BackgroundTransparency = 1,
        Text = "СОБРАНО  0 / 0",
        Font = Enum.Font.GothamBold, TextSize = 15,
        TextColor3 = Color3.fromRGB(248, 247, 251),
        TextXAlignment = Enum.TextXAlignment.Center,
        Size = UDim2.fromScale(1, 1), Visible = false,
    })
    local progressTrack = make("Frame", right, {
        BackgroundColor3 = Color3.fromRGB(59, 65, 82),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 43),
        Size = UDim2.fromOffset(172, 2),
        Visible = false,
    })
    round(progressTrack, 2)
    local fill = make("Frame", progressTrack, {
        BackgroundColor3 = Color3.fromRGB(255, 176, 109),
        BorderSizePixel = 0, Size = UDim2.fromScale(0, 1),
    })
    round(fill, 2)

    local ui = {
        gui = gui, dock = dock, scale = scale,
        button = button, buttonScale = buttonScale,
        buttonGradient = buttonGradient,
        channel = channel, count = count,
        progressTrack = progressTrack, fill = fill,
        running = false, lastProgress = -1, tweens = {},
    }
    state.ui = ui
    local function animateButton(size)
        if ui.buttonTween then ui.buttonTween:Cancel() end
        ui.buttonTween = TweenService:Create(buttonScale,
            TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            {Scale = size})
        ui.buttonTween:Play()
    end
    connect(state.uiConnections, button.MouseEnter:Connect(function()
        animateButton(1.035)
    end))
    connect(state.uiConnections, button.MouseLeave:Connect(function()
        animateButton(1)
    end))
    connect(state.uiConnections, button.Activated:Connect(function()
        setAuto(not state.auto)
        if updateUI then updateUI() end
    end))

    -- Telegram is centered in the right half while stopped.
    connect(state.uiConnections, right.InputBegan:Connect(function(input)
        if state.auto then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if type(setclipboard) == "function" then
            pcall(setclipboard, "https://t.me/AT3M3")
        end
    end))

    local dragging, dragStart, dockStart = false, nil, nil
    connect(state.uiConnections, bar.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        dragStart, dockStart = input.Position, dock.Position
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
    local intro = TweenService:Create(dock,
        TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        {Position = UDim2.new(0.5, 0, 0.82, 0)})
    table.insert(ui.tweens, intro)
    intro:Play()
end

updateUI = function(message)
    if not state.alive or not state.ui then return end
    if message then state.currentStatus = message end
    local ui = state.ui
    local camera = workspace.CurrentCamera
    if camera then
        ui.scale.Scale = math.min(1, math.max(0.65,
            (camera.ViewportSize.X - 20) / 330))
    end
    local data = getEventData()
    local folder = weekFolder(data)
    local collected, total = 0, 0
    if data then
        if type(data.HuntCollected) == "table" then
            for _, marked in pairs(data.HuntCollected) do
                if marked then collected += 1 end
            end
        end
        if folder then
            for _, candy in ipairs(CollectionService:GetTagged("CandyCorn26")) do
                if candy:IsA("BasePart") and candy:IsDescendantOf(folder) then
                    total += 1
                end
            end
        end
    end
    total = math.max(total, collected)
    ui.count.Text = string.format("СОБРАНО  %d / %d", collected, total)
    local progress = total > 0 and math.clamp(collected / total, 0, 1) or 0
    if math.abs(progress - ui.lastProgress) > 0.001 then
        ui.lastProgress = progress
        if ui.progressTween then ui.progressTween:Cancel() end
        ui.progressTween = TweenService:Create(ui.fill,
            TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            {Size = UDim2.fromScale(progress, 1)})
        ui.progressTween:Play()
    end
    if state.auto ~= ui.running then
        ui.running = state.auto
        ui.channel.Visible = not state.auto
        ui.count.Visible = state.auto
        ui.progressTrack.Visible = state.auto
        ui.button.Text = state.auto and "STOP" or "START"
        ui.button.TextColor3 = state.auto
            and Color3.fromRGB(255, 225, 224)
            or Color3.fromRGB(30, 24, 25)
        ui.buttonGradient.Color = state.auto and ColorSequence.new(
            Color3.fromRGB(92, 62, 76),
            Color3.fromRGB(58, 48, 67)
        ) or ColorSequence.new(
            Color3.fromRGB(255, 206, 139),
            Color3.fromRGB(255, 142, 101)
        )
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
