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
    antiSit = true,
    antiFall = true,
    freeze = false,
    generation = 0,
    connections = {},
    characterConnections = {},
    anchoredRoots = {},
    lastSafeCFrame = nil,
    recovering = false,
    window = nil,
    log = nil,
    stat = nil,
    autoToggle = nil,
    miniGui = nil,
    miniStatusLabel = nil,
    miniCountLabel = nil,
    miniProgressFill = nil,
    miniStartButton = nil,
    miniConnections = {},
    miniTweens = {},
    fullVisible = true,
}
env.__BrookhavenCandyState = state

local player = Players.LocalPlayer
local updateMini

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
    if state.log then
        pcall(function() state.log:Append(os.date("%H:%M:%S") .. "  " .. message) end)
    end
    if updateMini then pcall(updateMini, message) end
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

local function updateStat()
    local data = getEventData()
    local folder = weekFolder(data)
    if data and folder and state.stat then
        pcall(function() state.stat:Set(countCollected(data, folder)) end)
    end
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
local function cancelRun()
    state.auto = false
    state.generation += 1
    if state.autoToggle then state.autoToggle:Set(false, true) end
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
    for _, item in ipairs(CollectionService:GetTagged("CandyCorn26")) do
        if item:IsA("BasePart") and item:IsDescendantOf(folder) and not isCollected(data, item.Name) then
            table.insert(candies, item)
        end
    end

    if state.stat then
        pcall(function() state.stat:Set(countCollected(data, folder)) end)
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
            say("Остались только точки без безопасной опоры; маршрут остановлен")
        else
            say("В неделе " .. week .. " все конфеты уже собраны")
        end
        return
    end
    local total = #candies
    local visited = 0
    say("Неделя " .. week .. ": найдено " .. total .. " ещё не собранных")

    local planned = #candies
    for _ = 1, planned do
        if not state.alive or not state.auto or state.freeze or runId ~= state.generation then break end

        local beforeData = getEventData()
        for i = #candies, 1, -1 do
            local item = candies[i]
            if not item.Parent or isCollected(beforeData, item.Name) then
                table.remove(candies, i)
            end
        end
        if #candies == 0 then break end

        local _, routeRoot = parts()
        if not routeRoot then break end
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
            break
        end

        -- Read live replicated progress again immediately before each teleport.
        if candy.Parent and not isCollected(latest, candy.Name) then
            local _, currentRoot, humanoid = parts()
            if not currentRoot then
                say("Персонаж не готов; остановлено")
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
                break
            end
            task.wait(0.05)
        end
    end

    if state.alive and runId == state.generation then
        local _, returnRoot = parts()
        if returnRoot and not state.freeze then
            returnRoot.CFrame = startCFrame
            returnRoot.AssemblyLinearVelocity = Vector3.zero
        end
        updateStat()

        local finalData = getEventData()
        local finalFolder = weekFolder(finalData)
        local remaining = 0
        if finalData and finalFolder then
            for _, item in ipairs(CollectionService:GetTagged("CandyCorn26")) do
                if item:IsDescendantOf(finalFolder) and not isCollected(finalData, item.Name) then
                    remaining += 1
                end
            end
        end

        say("Обход завершён · осталось " .. remaining)
        if state.window then
            pcall(function()
                state.window:Notify({
                    title = "Сбор завершён",
                    content = "Подтверждённых остатков: " .. remaining,
                })
            end)
        end
    end
end

function state.cleanup()
    if not state.alive then return end
    state.alive = false
    state.auto = false
    state.generation += 1
    disconnectAll(state.characterConnections)
    disconnectAll(state.connections)

    for root, originalAnchored in pairs(state.anchoredRoots) do
        if root and root.Parent then
            pcall(function() root.Anchored = originalAnchored end)
        end
    end
    table.clear(state.anchoredRoots)

    disconnectAll(state.miniConnections)
    for _, tween in ipairs(state.miniTweens) do pcall(function() tween:Cancel() end) end
    table.clear(state.miniTweens)
    if state.miniProgressTween then pcall(function() state.miniProgressTween:Cancel() end) end
    if state.miniGui then pcall(function() state.miniGui:Destroy() end); state.miniGui = nil end

    if state.window and not state.window.unloaded then
        pcall(function() state.window:Unload() end)
    end
end

local Rayfield
local loaded, loadError = pcall(function()
    Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
end)
if not loaded or not Rayfield then
    warn("Rayfield Gen2 не загрузился: " .. tostring(loadError))
    state.alive = false
    return
end

local window = Rayfield:CreateWindow({
    name = "Atomick AutoFarm",
    subtitle = "Brookhaven · Halloween 2026",
    sidebarLayout = true,
    theme = "ember",
    showName = "ATOMICK AUTOFARM",
    showIconOnly = false,
    configuration = {
        autoSave = true,
        autoLoad = true,
        fileName = "BrookhavenHalloweenCandy",
    },
})
state.window = window

local collectTab = window:CreateTab({ name = "Сбор" })
local safetyTab = window:CreateTab({ name = "Защита" })
local settingsTab = window:CreateTab({ name = "Настройки" })

state.log = collectTab:CreateConsole({
    name = "Журнал",
    text = "Готово · нажми «Автосбор», чтобы начать",
    height = 150,
    follow = true,
    maxLines = 80,
})
state.stat = collectTab:CreateStat({
    name = "Собрано на этой неделе",
    value = 0,
})
updateStat()

state.autoToggle = collectTab:CreateToggle({
    name = "Автосбор недостающих конфет",
    description = "Сверяет прогресс перед каждым перемещением",
    value = false,
    forgetState = true,
    callback = function(enabled)
        if enabled and state.freeze then
            if state.autoToggle then state.autoToggle:Set(false, true) end
            say("Сначала выключи закрепление персонажа")
            return
        end

        state.auto = enabled
        state.generation += 1
        if enabled then
            local runId = state.generation
            task.spawn(function()
                local ok, err = pcall(collectPass, runId)
                if not ok and state.alive then
                    say("Ошибка сбора: " .. tostring(err))
                    cancelRun()
                end
                if state.alive and runId == state.generation then
                    state.auto = false
                    if state.autoToggle then state.autoToggle:Set(false, true) end
                end
            end)
        else
            say("Автосбор остановлен")
        end
    end,
})

collectTab:CreateButton({
    name = "Сбросить маршрут / пересканировать",
    description = "Перезапускает поиск незачтённых конфет; прогресс события не сбрасывает",
    callback = function()
        if state.freeze then
            say("Сними закрепление, чтобы пересканировать маршрут")
            return
        end
        if state.auto then
            cancelRun()
            task.delay(0.12, function()
                if state.alive and not state.freeze and state.autoToggle then state.autoToggle:Set(true) end
            end)
        elseif state.autoToggle then
            state.autoToggle:Set(true)
        end
    end,
})
collectTab:CreateKeybind({
    name = "Показать/скрыть меню",
    value = Enum.KeyCode.RightShift,
    callback = function()
        if state.window and state.alive then
            state.fullVisible = not state.fullVisible
            state.window:ToggleHide()
        end
    end,
})

collectTab:CreateKeybind({
    name = "Старт/стоп автосбора",
    value = Enum.KeyCode.RightControl,
    callback = function()
        if state.autoToggle and state.alive then
            state.autoToggle:Set(not state.autoToggle.value)
        end
    end,
})

safetyTab:CreateToggle({
    name = "Анти-сидение",
    description = "Автоматически встаёт, если персонаж сел",
    value = true,
    flag = "AntiSit",
    callback = function(enabled)
        state.antiSit = enabled
        if enabled then
            local _, _, humanoid = parts()
            if humanoid and humanoid.Sit then
                humanoid.Sit = false
                pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
            end
        end
        say(enabled and "Анти-сидение включено" or "Анти-сидение выключено")
    end,
})

safetyTab:CreateToggle({
    name = "Восстановление после падения",
    description = "Возвращает к последней безопасной точке ниже Y = -30",
    value = true,
    flag = "AntiFall",
    callback = function(enabled)
        state.antiFall = enabled
        say(enabled and "Защита от провала включена" or "Защита от провала выключена")
    end,
})

safetyTab:CreateToggle({
    name = "Закрепить персонажа",
    description = "Удерживает на месте; автосбор при этом выключается",
    value = false,
    forgetState = true,
    callback = function(enabled)
        state.freeze = enabled
        local _, root = parts()
        if enabled then
            if state.auto then cancelRun() end
            if root then setAnchored(root, true) end
            say("Персонаж закреплён")
        else
            if root then setAnchored(root, false) end
            say("Закрепление выключено")
        end
    end,
})

safetyTab:CreateButton({
    name = "Вернуться в безопасное место",
    description = "К последней точке, где персонаж стоял на поверхности",
    callback = function()
        local _, root, humanoid = parts()
        if not root or not state.lastSafeCFrame then
            say("Безопасная точка ещё не сохранена")
            return
        end
        root.Anchored = false
        root.CFrame = state.lastSafeCFrame + Vector3.new(0, 4, 0)
        root.AssemblyLinearVelocity = Vector3.zero
        if humanoid then
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
        say("Возврат к безопасной точке выполнен")
    end,
})

local telegramLink = "https://t.me/AT3M3"

settingsTab:CreateButton({
    name = "TG AT3M3 · скопировать ссылку",
    description = "Копирует Telegram-ссылку в буфер обмена",
    callback = function()
        local ok = pcall(setclipboard, telegramLink)
        if ok then
            window:Notify({ title = "Ссылка скопирована", content = telegramLink })
        else
            say("Не удалось скопировать ссылку: setclipboard недоступен")
        end
    end,
})

settingsTab:CreateButton({
    name = "Свернуть меню",
    description = "Скрывает окно; RightShift снова покажет его",
    callback = function()
        if state.window and state.alive then
            state.fullVisible = not state.fullVisible
            state.window:ToggleHide()
        end
    end,
})
local function createMiniWidget()
    local parent
    if type(gethui) == "function" then
        local ok, hidden = pcall(gethui)
        if ok and hidden then parent = hidden end
    end
    if not parent then
        local ok, core = pcall(function() return game:GetService("CoreGui") end)
        parent = ok and core or player:WaitForChild("PlayerGui")
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AtomickAutoFarmMini"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 9000
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = parent
    state.miniGui = gui

    local card = Instance.new("Frame")
    card.Name = "Card"
    card.AnchorPoint = Vector2.new(0, 0.5)
    card.Position = UDim2.new(0, 20, 0.58, 16)
    card.Size = UDim2.new(0, 264, 0, 104)
    card.BackgroundColor3 = Color3.fromRGB(18, 17, 25)
    card.BackgroundTransparency = 1
    card.BorderSizePixel = 0
    card.ClipsDescendants = true
    card.ZIndex = 10
    card.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 15)
    corner.Parent = card
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(244, 137, 67)
    stroke.Transparency = 1
    stroke.Thickness = 1.2
    stroke.Parent = card
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 25, 34)),
        ColorSequenceKeypoint.new(0.55, Color3.fromRGB(20, 19, 29)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(34, 20, 23)),
    })
    gradient.Rotation = 0
    gradient.Parent = card

    local accent = Instance.new("Frame")
    accent.Position = UDim2.new(0, 8, 0, 11)
    accent.Size = UDim2.new(0, 3, 1, -22)
    accent.BackgroundColor3 = Color3.fromRGB(255, 145, 70)
    accent.BorderSizePixel = 0
    accent.ZIndex = 11
    accent.Parent = card
    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

    local title = Instance.new("TextButton")
    title.Position = UDim2.new(0, 20, 0, 10)
    title.Size = UDim2.new(0, 158, 0, 25)
    title.BackgroundTransparency = 1
    title.Text = "ATOMICK  /  AUTOFARM"
    title.TextColor3 = Color3.fromRGB(255, 226, 205)
    title.TextSize = 12
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.AutoButtonColor = false
    title.ZIndex = 12
    title.Parent = card

    local status = Instance.new("TextLabel")
    status.AnchorPoint = Vector2.new(1, 0)
    status.Position = UDim2.new(1, -12, 0, 14)
    status.Size = UDim2.new(0, 75, 0, 18)
    status.BackgroundColor3 = Color3.fromRGB(42, 35, 35)
    status.BorderSizePixel = 0
    status.Text = "READY"
    status.TextColor3 = Color3.fromRGB(255, 185, 124)
    status.TextSize = 9
    status.Font = Enum.Font.GothamBold
    status.ZIndex = 12
    status.Parent = card
    local statusCorner = Instance.new("UICorner")
    statusCorner.CornerRadius = UDim.new(1, 0)
    statusCorner.Parent = status

    local count = Instance.new("TextLabel")
    count.Position = UDim2.new(0, 20, 0, 39)
    count.Size = UDim2.new(1, -32, 0, 16)
    count.BackgroundTransparency = 1
    count.Text = "CHECKING EVENT…"
    count.TextColor3 = Color3.fromRGB(177, 172, 183)
    count.TextSize = 10
    count.Font = Enum.Font.GothamMedium
    count.TextXAlignment = Enum.TextXAlignment.Left
    count.ZIndex = 12
    count.Parent = card

    local track = Instance.new("Frame")
    track.Position = UDim2.new(0, 20, 0, 59)
    track.Size = UDim2.new(1, -32, 0, 4)
    track.BackgroundColor3 = Color3.fromRGB(56, 50, 59)
    track.BorderSizePixel = 0
    track.ZIndex = 12
    track.Parent = card
    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(1, 0)
    trackCorner.Parent = track
    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.fromScale(0, 1)
    fill.BackgroundColor3 = Color3.fromRGB(255, 151, 74)
    fill.BorderSizePixel = 0
    fill.ZIndex = 13
    fill.Parent = track
    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(1, 0)
    fillCorner.Parent = fill
    local fillGradient = Instance.new("UIGradient")
    fillGradient.Color = ColorSequence.new(Color3.fromRGB(255, 198, 98), Color3.fromRGB(255, 105, 75))
    fillGradient.Parent = fill

    local source = Instance.new("TextLabel")
    source.Position = UDim2.new(0, 20, 0, 70)
    source.Size = UDim2.new(0, 105, 0, 20)
    source.BackgroundTransparency = 1
    source.Text = "SOURCE  ·  AT3M3"
    source.TextColor3 = Color3.fromRGB(139, 132, 145)
    source.TextSize = 8
    source.Font = Enum.Font.GothamMedium
    source.TextXAlignment = Enum.TextXAlignment.Left
    source.ZIndex = 12
    source.Parent = card

    local startButton = Instance.new("TextButton")
    startButton.Name = "StartStop"
    startButton.AnchorPoint = Vector2.new(1, 0)
    startButton.Position = UDim2.new(1, -72, 0, 68)
    startButton.Size = UDim2.new(0, 66, 0, 26)
    startButton.BackgroundColor3 = Color3.fromRGB(209, 104, 64)
    startButton.BorderSizePixel = 0
    startButton.Text = "START"
    startButton.TextColor3 = Color3.fromRGB(255, 247, 239)
    startButton.TextSize = 9
    startButton.Font = Enum.Font.GothamBold
    startButton.AutoButtonColor = false
    startButton.ZIndex = 12
    startButton.Parent = card
    local startCorner = Instance.new("UICorner")
    startCorner.CornerRadius = UDim.new(0, 8)
    startCorner.Parent = startButton

    local openButton = Instance.new("TextButton")
    openButton.Name = "OpenMenu"
    openButton.AnchorPoint = Vector2.new(1, 0)
    openButton.Position = UDim2.new(1, -12, 0, 68)
    openButton.Size = UDim2.new(0, 52, 0, 26)
    openButton.BackgroundColor3 = Color3.fromRGB(48, 42, 54)
    openButton.BorderSizePixel = 0
    openButton.Text = "OPEN"
    openButton.TextColor3 = Color3.fromRGB(234, 222, 240)
    openButton.TextSize = 9
    openButton.Font = Enum.Font.GothamBold
    openButton.AutoButtonColor = false
    openButton.ZIndex = 12
    openButton.Parent = card
    local openCorner = Instance.new("UICorner")
    openCorner.CornerRadius = UDim.new(0, 8)
    openCorner.Parent = openButton

    state.miniStatusLabel = status
    state.miniCountLabel = count
    state.miniProgressFill = fill
    state.miniStartButton = startButton

    local buttonTweens = {}
    local function hover(button, baseColor, hoverColor)
        connect(state.miniConnections, button.MouseEnter:Connect(function()
            if buttonTweens[button] then buttonTweens[button]:Cancel() end
            buttonTweens[button] = TweenService:Create(button, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundColor3 = hoverColor })
            buttonTweens[button]:Play()
        end))
        connect(state.miniConnections, button.MouseLeave:Connect(function()
            if buttonTweens[button] then buttonTweens[button]:Cancel() end
            buttonTweens[button] = TweenService:Create(button, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundColor3 = baseColor })
            buttonTweens[button]:Play()
        end))
    end
    hover(startButton, Color3.fromRGB(209, 104, 64), Color3.fromRGB(245, 132, 67))
    hover(openButton, Color3.fromRGB(48, 42, 54), Color3.fromRGB(75, 61, 79))

    connect(state.miniConnections, startButton.Activated:Connect(function()
        if state.autoToggle and state.alive then state.autoToggle:Set(not state.autoToggle.value) end
    end))
    connect(state.miniConnections, openButton.Activated:Connect(function()
        if state.window and state.alive and not state.fullVisible then
            state.fullVisible = true
            state.window:ToggleHide()
        end
    end))

    local dragging = false
    local dragStart
    local startPosition
    connect(state.miniConnections, title.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        dragStart = input.Position
        startPosition = card.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end))
    connect(state.miniConnections, UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - dragStart
        card.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
    end))

    local entrance = TweenService:Create(card, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.new(0, 20, 0.58, 0),
        BackgroundTransparency = 0.04,
    })
    table.insert(state.miniTweens, entrance)
    entrance:Play()
    local strokeIn = TweenService:Create(stroke, TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 0.24 })
    table.insert(state.miniTweens, strokeIn)
    strokeIn:Play()
    local shimmer = TweenService:Create(gradient, TweenInfo.new(12, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Rotation = 360 })
    state.miniGradientTween = shimmer
    table.insert(state.miniTweens, shimmer)
    shimmer:Play()
end

updateMini = function()
    if not state.alive or not state.miniGui then return end
    local eventData = getEventData()
    local folder = weekFolder(eventData)
    if eventData and folder then
        local collected = countCollected(eventData, folder)
        local total = 0
        for _, item in ipairs(CollectionService:GetTagged("CandyCorn26")) do
            if item:IsDescendantOf(folder) then total += 1 end
        end
        if state.miniCountLabel then
            state.miniCountLabel.Text = string.format("WEEK %s  ·  %d / %d CANDY", tostring(eventData.HuntWeek), collected, total)
        end
        if state.miniProgressFill then
            if state.miniProgressTween then state.miniProgressTween:Cancel() end
            local progress = total > 0 and math.clamp(collected / total, 0, 1) or 0
            state.miniProgressTween = TweenService:Create(state.miniProgressFill, TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(progress, 1) })
            state.miniProgressTween:Play()
        end
    end
    if state.miniStatusLabel then
        state.miniStatusLabel.Text = state.auto and "FARMING" or (state.freeze and "PAUSED" or "READY")
        state.miniStatusLabel.TextColor3 = state.auto and Color3.fromRGB(255, 190, 114) or Color3.fromRGB(192, 176, 198)
    end
    if state.miniStartButton then
        state.miniStartButton.Text = state.auto and "STOP" or "START"
        state.miniStartButton.BackgroundColor3 = state.auto and Color3.fromRGB(91, 58, 65) or Color3.fromRGB(209, 104, 64)
    end
end
settingsTab:CreateDropdown({
    name = "Цветовая тема",
    options = { "ember", "amethyst", "cobalt", "frost", "rose", "default" },
    value = "ember",
    callback = function(theme)
        if state.window and state.alive then state.window:ChangeTheme(theme) end
    end,
})

settingsTab:CreateButton({
    name = "Остановить и закрыть",
    description = "Отключает защиты, снимает закрепление и закрывает меню",
    callback = function()
        state.cleanup()
    end,
})

createMiniWidget()
updateMini()

connect(state.connections, player.CharacterAdded:Connect(function(character)
    task.spawn(watchCharacter, character)
end))
if player.Character then task.spawn(watchCharacter, player.Character) end

local lastSafetyCheck = 0
connect(state.connections, RunService.Heartbeat:Connect(function()
    if not state.alive then return end
    if state.window and state.window.unloaded then
        state.cleanup()
        return
    end

    local now = os.clock()
    if now - lastSafetyCheck < 0.12 then return end
    lastSafetyCheck = now

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

say("Atomick AutoFarm готов");
