-- Brookhaven Halloween 2026 · Candy Corn
-- Uses Brookhaven's normal proximity collector; does not invoke the collection remote directly.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
}
env.__BrookhavenCandyState = state

local player = Players.LocalPlayer

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
    if #candies == 0 then
        say("В неделе " .. week .. " все конфеты уже собраны")
        return
    end

    table.sort(candies, function(a, b)
        local _, currentRoot = parts()
        if not currentRoot then return a.Name < b.Name end
        local da = (a.Position - currentRoot.Position).Magnitude
        local db = (b.Position - currentRoot.Position).Magnitude
        if da == db then return a.Name < b.Name end
        return da < db
    end)

    local total = #candies
    local visited = 0
    say("Неделя " .. week .. ": найдено " .. total .. " ещё не собранных")

    for _, candy in ipairs(candies) do
        if not state.alive or not state.auto or state.freeze or runId ~= state.generation then break end

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
            local deadline = os.clock() + 2.5
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
                        local retryDeadline = os.clock() + 2.5
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
            task.wait(0.2)
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
    name = "Atomick Hub · Candy Corn",
    subtitle = "Brookhaven · Halloween 2026",
    sidebarLayout = true,
    theme = "ember",
    showName = "ATOMICK HUB",
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

collectTab:CreateKeybind({
    name = "Показать/скрыть меню",
    value = Enum.KeyCode.RightShift,
    callback = function()
        if state.window and state.alive then state.window:ToggleHide() end
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
        if state.window and state.alive then state.window:ToggleHide() end
    end,
})
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

connect(state.connections, player.CharacterAdded:Connect(function(character)
    task.spawn(watchCharacter, character)
end))
if player.Character then task.spawn(watchCharacter, player.Character) end

connect(state.connections, RunService.Heartbeat:Connect(function()
    if not state.alive then return end
    if state.window and state.window.unloaded then
        state.cleanup()
        return
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

say("Меню готово · RightShift показать/скрыть");
