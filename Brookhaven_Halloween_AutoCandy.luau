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

    local function make(class, holder, properties)
        local object = Instance.new(class)
        for key, value in pairs(properties) do object[key] = value end
        object.Parent = holder
        return object
    end
    local function rounded(holder, radius)
        make("UICorner", holder, { CornerRadius = UDim.new(0, radius) })
    end
    local function playTween(target, info, goal)
        local tween = TweenService:Create(target, info, goal)
        tween:Play()
        return tween
    end

    local white = Color3.fromRGB(247, 246, 249)
    local gray = Color3.fromRGB(154, 157, 172)
    local amber = Color3.fromRGB(255, 178, 110)
    local telegram = Color3.fromRGB(100, 185, 255)
    local easing = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

    local gui = make("ScreenGui", parent, {
        Name = "AtomickCandyMini",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9000,
    })
    local dock = make("Frame", gui, {
        Name = "Mini",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.78, 25),
        Size = UDim2.fromOffset(272, 128),
        BackgroundTransparency = 1,
    })
    local scale = make("UIScale", dock, { Scale = 1 })
    local shadow = make("Frame", dock, {
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.62,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 8),
        Size = UDim2.fromScale(1, 1),
        ZIndex = 1,
    })
    rounded(shadow, 21)

    local panel = make("Frame", dock, {
        BackgroundColor3 = Color3.fromRGB(17, 19, 27),
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        ClipsDescendants = true,
        ZIndex = 2,
    })
    rounded(panel, 20)
    make("UIGradient", panel, {
        Rotation = 32,
        Color = ColorSequence.new(
            Color3.fromRGB(29, 29, 42),
            Color3.fromRGB(13, 17, 25)
        ),
    })
    local outline = make("UIStroke", panel, {
        Color = Color3.fromRGB(101, 108, 136),
        Transparency = 0.55,
        Thickness = 1,
    })

    local topBar = make("Frame", panel, {
        BackgroundColor3 = amber,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(42, 2),
        Position = UDim2.fromOffset(15, 0),
        ZIndex = 3,
    })
    rounded(topBar, 2)
    make("UIGradient", topBar, {
        Color = ColorSequence.new(amber, telegram),
    })

    local handle = make("Frame", panel, {
        Name = "DragArea",
        Active = true,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(9, 5),
        Size = UDim2.fromOffset(155, 29),
        ZIndex = 3,
    })
    local emblem = make("Frame", handle, {
        BackgroundColor3 = amber,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(6, 6),
        Size = UDim2.fromOffset(17, 17),
        ZIndex = 4,
    })
    rounded(emblem, 6)
    make("TextLabel", emblem, {
        BackgroundTransparency = 1,
        Text = "A",
        Font = Enum.Font.GothamBold,
        TextColor3 = Color3.fromRGB(29, 22, 26),
        TextSize = 11,
        Size = UDim2.fromScale(1, 1),
        ZIndex = 5,
    })
    make("TextLabel", handle, {
        BackgroundTransparency = 1,
        Text = "ATOMICK",
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(31, 3),
        Size = UDim2.fromOffset(110, 24),
        ZIndex = 4,
    })

    -- Telegram branding; tapping the label copies the channel URL.
    local tgPill = make("Frame", panel, {
        BackgroundColor3 = Color3.fromRGB(26, 48, 66),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(170, 9),
        Size = UDim2.fromOffset(88, 22),
        Active = true,
        ZIndex = 4,
    })
    rounded(tgPill, 11)
    local tgStroke = make("UIStroke", tgPill, {
        Color = telegram, Transparency = 0.64, Thickness = 1,
    })
    local tgText = make("TextLabel", tgPill, {
        BackgroundTransparency = 1,
        Text = "TG  @AT3M3",
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = Color3.fromRGB(158, 216, 255),
        Size = UDim2.fromScale(1, 1),
        ZIndex = 5,
    })

    local number = make("TextLabel", panel, {
        BackgroundTransparency = 1,
        Text = "— / —",
        Font = Enum.Font.GothamBold,
        TextSize = 25,
        TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(15, 35),
        Size = UDim2.fromOffset(156, 34),
        ZIndex = 4,
    })
    local name = make("TextLabel", panel, {
        BackgroundTransparency = 1,
        Text = "CANDY CORN",
        Font = Enum.Font.GothamMedium,
        TextSize = 9,
        TextColor3 = gray,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(16, 70),
        Size = UDim2.fromOffset(155, 14),
        ZIndex = 4,
    })

    -- The only actual button: toggle farm on/off.
    local button = make("TextButton", panel, {
        Name = "StartStop",
        BackgroundColor3 = amber,
        Text = "START",
        TextColor3 = Color3.fromRGB(33, 27, 28),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        AutoButtonColor = false,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(174, 44),
        Size = UDim2.fromOffset(84, 38),
        ZIndex = 4,
    })
    rounded(button, 12)
    local buttonScale = make("UIScale", button, { Scale = 1 })
    local buttonGradient = make("UIGradient", button, {
        Color = ColorSequence.new(
            Color3.fromRGB(255, 211, 142),
            Color3.fromRGB(255, 138, 103)
        ),
    })
    local buttonOutline = make("UIStroke", button, {
        Color = Color3.fromRGB(255, 230, 175),
        Transparency = 0.55,
        Thickness = 1,
    })

    local track = make("Frame", panel, {
        BackgroundColor3 = Color3.fromRGB(50, 53, 64),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(15, 89),
        Size = UDim2.fromOffset(242, 3),
        ZIndex = 4,
    })
    rounded(track, 3)
    local fill = make("Frame", track, {
        BackgroundColor3 = amber,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1),
        ZIndex = 5,
    })
    rounded(fill, 3)
    make("UIGradient", fill, {
        Color = ColorSequence.new(amber, telegram),
    })
    local statusDot = make("Frame", panel, {
        BackgroundColor3 = Color3.fromRGB(120, 125, 141),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(16, 101),
        Size = UDim2.fromOffset(5, 5),
        ZIndex = 4,
    })
    rounded(statusDot, 5)
    local status = make("TextLabel", panel, {
        BackgroundTransparency = 1,
        Text = "Готов к запуску",
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = gray,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.fromOffset(27, 96),
        Size = UDim2.fromOffset(229, 16),
        ZIndex = 4,
    })

    -- Seamless scrolling Telegram signature; two repeated copies align exactly.
    local tickerWindow = make("Frame", panel, {
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(15, 112),
        Size = UDim2.fromOffset(242, 13),
        ZIndex = 4,
    })
    local message = "  @AT3M3  •  t.me/AT3M3  •  TELEGRAM / AT3M3  • "
    local textService = game:GetService("TextService")
    local messageWidth = math.ceil(textService:GetTextSize(
        message, 9, Enum.Font.GothamMedium, Vector2.new(10000, 13)
    ).X) + 20
    local moving = make("Frame", tickerWindow, {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromOffset(messageWidth * 2, 13),
        ZIndex = 4,
    })
    for i = 0, 1 do
        make("TextLabel", moving, {
            BackgroundTransparency = 1,
            Text = message,
            TextColor3 = Color3.fromRGB(105, 160, 198),
            Font = Enum.Font.GothamMedium,
            TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
            Position = UDim2.fromOffset(i * messageWidth, 0),
            Size = UDim2.fromOffset(messageWidth, 13),
            ZIndex = 5,
        })
    end
    local tickerTween = playTween(moving, TweenInfo.new(
        16, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1
    ), { Position = UDim2.fromOffset(-messageWidth, 0) })

    local ui = {
        gui = gui,
        dock = dock,
        scale = scale,
        number = number,
        progressName = name,
        fill = fill,
        status = status,
        statusDot = statusDot,
        button = button,
        buttonScale = buttonScale,
        buttonGradient = buttonGradient,
        buttonOutline = buttonOutline,
        lastProgress = -1,
        running = false,
        tweens = { tickerTween },
    }
    state.ui = ui

    local function buttonAnimation(size)
        if ui.buttonTween then ui.buttonTween:Cancel() end
        ui.buttonTween = playTween(buttonScale, easing, { Scale = size })
    end
    connect(state.uiConnections, button.MouseEnter:Connect(function()
        buttonAnimation(1.04)
    end))
    connect(state.uiConnections, button.MouseLeave:Connect(function()
        buttonAnimation(1)
    end))
    connect(state.uiConnections, button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            buttonAnimation(0.96)
        end
    end))
    connect(state.uiConnections, button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            buttonAnimation(1)
        end
    end))
    connect(state.uiConnections, button.Activated:Connect(function()
        setAuto(not state.auto)
    end))

    connect(state.uiConnections, tgPill.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local copied = pcall(function()
            if type(setclipboard) ~= "function" then error("clipboard unavailable") end
            setclipboard("https://t.me/AT3M3")
        end)
        if copied then
            tgText.Text = "✓  COPIED"
            playTween(tgStroke, easing, { Transparency = 0.15 })
            task.delay(1.6, function()
                if state.alive and tgText.Parent then
                    tgText.Text = "TG  @AT3M3"
                    playTween(tgStroke, easing, { Transparency = 0.64 })
                end
            end)
        else
            say("ТГК: t.me/AT3M3")
        end
    end))

    local dragging = false
    local dragStart, dockStart
    connect(state.uiConnections, handle.InputBegan:Connect(function(input)
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

    local entrance = playTween(dock, TweenInfo.new(
        0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out
    ), { Position = UDim2.new(0.5, 0, 0.78, 0) })
    table.insert(ui.tweens, entrance)
    local outlineTween = playTween(outline, TweenInfo.new(
        3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true
    ), { Transparency = 0.3 })
    table.insert(ui.tweens, outlineTween)
end

updateUI = function(message)
    if not state.alive or not state.ui then return end
    local ui = state.ui
    if message then state.currentStatus = message end

    local camera = workspace.CurrentCamera
    local view = camera and camera.ViewportSize
    if view then
        ui.scale.Scale = math.min(1, math.max(0.68, (view.X - 18) / 272))
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
        or "CANDY CORN"
    local progress = total > 0 and math.clamp(collected / total, 0, 1) or 0
    if math.abs(progress - ui.lastProgress) > 0.001 then
        ui.lastProgress = progress
        if ui.progressTween then ui.progressTween:Cancel() end
        ui.progressTween = TweenService:Create(ui.fill, TweenInfo.new(
            0.36, Enum.EasingStyle.Quint, Enum.EasingDirection.Out
        ), { Size = UDim2.fromScale(progress, 1) })
        ui.progressTween:Play()
    end

    ui.status.Text = state.currentStatus
    local running = state.auto
    if running ~= ui.running then
        ui.running = running
        ui.button.Text = running and "STOP" or "START"
        ui.button.TextColor3 = running and Color3.fromRGB(255, 219, 214)
            or Color3.fromRGB(33, 27, 28)
        ui.buttonGradient.Color = running and ColorSequence.new(
            Color3.fromRGB(84, 55, 66), Color3.fromRGB(55, 46, 63)
        ) or ColorSequence.new(
            Color3.fromRGB(255, 211, 142), Color3.fromRGB(255, 138, 103)
        )
        ui.buttonOutline.Color = running and Color3.fromRGB(186, 113, 123)
            or Color3.fromRGB(255, 230, 175)
        ui.statusDot.BackgroundColor3 = running and Color3.fromRGB(119, 228, 171)
            or Color3.fromRGB(120, 125, 141)
        if ui.pulseTween then ui.pulseTween:Cancel(); ui.pulseTween = nil end
        ui.statusDot.BackgroundTransparency = 0
        if running then
            ui.pulseTween = TweenService:Create(ui.statusDot, TweenInfo.new(
                0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true
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
