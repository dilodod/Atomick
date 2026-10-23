-- Brookhaven Halloween 2026 · Candy Corn
-- Uses Brookhaven's normal proximity collector; does not invoke the collection remote directly.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TextService = game:GetService("TextService")

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
    sessionCollected = 0,
    countedCandies = {},
    noticeText = nil,
    noticeUntil = 0,
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

local function showNotice(message, duration)
    if not state.alive then return end
    state.noticeText = message
    state.noticeUntil = os.clock() + (duration or 3)
    local expires = state.noticeUntil
    if updateUI then pcall(updateUI) end
    task.delay(duration or 3, function()
        if state.alive and state.noticeUntil == expires and updateUI then pcall(updateUI) end
    end)
end

local function say(message, notice)
    if not state.alive then return end
    state.currentStatus = message
    if notice then showNotice(notice) end
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

-- Rearm a candy only after replicated data says it is available again.
-- This also handles a reset that completes while STOP is pressed.
local function observeSessionProgress(eventData, week)
    if not eventData or eventData.HuntWeek ~= week
        or type(eventData.HuntCollected) ~= "table" then return nil end
    local counted = state.countedCandies[week]
    if not counted then
        counted = {}
        state.countedCandies[week] = counted
    end
    for name in pairs(counted) do
        if not isCollected(eventData, name) then counted[name] = nil end
    end
    return counted
end

local function recordCollected(eventData, week, name)
    local counted = observeSessionProgress(eventData, week)
    if not counted or counted[name] or not isCollected(eventData, name) then return false end
    counted[name] = true
    state.sessionCollected += 1
    return true
end

-- Returns true only after the server actually refreshes the replicated hunt.
-- "rescan" means another collectible appeared before the reset.
local function useOfficialRespawn(folder, week, runId, considered)
    if not state.autoRespawn or not state.alive or not state.auto
        or state.generation ~= runId then return false end

    local data = getEventData()
    local activeFolder, activeWeek = weekFolder(data)
    if not data or not folder or activeFolder ~= folder or activeWeek ~= week then
        say("Не удалось подтвердить активную неделю; сброс отменён", "Нет данных события")
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
        say("Конфеты не загружены в мире; автосброс отменён", "Конфеты не загружены")
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
        say("Сброс не принят сервером: " .. tostring(response), "Сброс недоступен")
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
            say("Активная неделя изменилась · остановлено", "Неделя изменилась")
            return false
        end

        -- Previously collected candies must become uncollected; otherwise
        -- the 2 already-missing candies at 58/60 look like a false success.
        if updated and type(updated.HuntCollected) == "table" then
            for candyName in pairs(collectedBefore) do
                if not isCollected(updated, candyName) then
                    observeSessionProgress(updated, week)
                    say("Сервер обновил прогресс · начинаю новый сбор")
                    return true
                end
            end
        end
    until os.clock() >= deadline

    say("Вызов сброса выполнен, но прогресс не изменился; проверь ограничение сервера", "Сброс не подтверждён")
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
    if not data or not folder or type(data.HuntCollected) ~= "table" then
        say("Не удалось прочитать активную неделю события", "Нет данных события")
        return
    end
    observeSessionProgress(data, week)

    local character, root = parts()
    if not character or not root then
        say("Персонаж ещё загружается", "Персонаж загружается")
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
        if currentWeek ~= week or currentFolder ~= folder
            or type(latest.HuntCollected) ~= "table" then
            say("Данные недели события изменились; остановлено", "Нет данных события")
            completed = false
            break
        end

        -- Read live replicated progress again immediately before each teleport.
        observeSessionProgress(latest, week)
        if candy.Parent and not isCollected(latest, candy.Name) then
            local _, currentRoot, humanoid = parts()
            if not currentRoot then
                say("Персонаж не готов; остановлено", "Персонаж не готов")
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
                if state.alive and runId == state.generation then
                    recordCollected(latest, week, candy.Name)
                end
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
            say("Данные недели изменились · сброс отменён", "Неделя изменилась")
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
        for _, effect in pairs(ui.tweens) do
            pcall(function() effect:Cancel() end)
        end
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
        say("Сначала сними закрепление персонажа", "Персонаж закреплён")
        return
    end

    state.auto = enabled
    state.generation += 1
    state.noticeText = nil
    state.noticeUntil = 0
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
        if not ok and state.alive and runId == state.generation then
            say("Ошибка сбора: " .. tostring(err), "Ошибка сбора")
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
        for key, value in pairs(props) do object[key] = value end
        object.Parent = holder
        return object
    end
    local function round(holder, radius)
        make("UICorner", holder, {CornerRadius = UDim.new(0, radius)})
    end
    local ink = Color3.fromRGB(61, 28, 7)
    local gui = make("ScreenGui", parent, {
        Name = "AtomickCandyBar", ResetOnSpawn = false,
        IgnoreGuiInset = true, DisplayOrder = 9000,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    -- Clamp in viewport coordinates, including the insets explicitly below.
    gui.ScreenInsets = Enum.ScreenInsets.None
    local dock = make("Frame", gui, {
        AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1,
        Position = UDim2.fromScale(0.5, 0.82), Size = UDim2.fromOffset(360, 56),
    })
    local introScale = make("UIScale", dock, {Scale = 0.97})
    local shadow = make("Frame", dock, {
        BackgroundColor3 = Color3.fromRGB(98, 43, 8), BackgroundTransparency = 1,
        BorderSizePixel = 0, Position = UDim2.fromOffset(0, 4),
        Size = UDim2.fromScale(1, 1), ZIndex = 1,
    })
    round(shadow, 17)
    local canvas = make("CanvasGroup", dock, {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(0, 10),
        GroupTransparency = 1, ClipsDescendants = true, ZIndex = 2,
    })
    round(canvas, 16)
    -- UIGradient belongs to a supported Frame; CanvasGroup handles the fade.
    local bar = make("Frame", canvas, {
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), ClipsDescendants = true, Active = true, ZIndex = 2,
    })
    round(bar, 16)
    make("UIGradient", bar, {
        Color = ColorSequence.new(Color3.fromRGB(255, 155, 63), Color3.fromRGB(255, 132, 45)),
        Rotation = 12,
    })
    make("UIStroke", bar, {
        Color = Color3.fromRGB(255, 193, 119), Transparency = 0.25, Thickness = 1,
    })
    local highlight = make("Frame", bar, {
        BackgroundColor3 = Color3.fromRGB(255, 222, 179), BackgroundTransparency = 0.6,
        BorderSizePixel = 0, Position = UDim2.fromOffset(16, 1),
        Size = UDim2.new(1, -32, 0, 1), ZIndex = 2,
    })
    round(highlight, 1)
    local ui = {
        gui = gui, dock = dock, bar = bar, introScale = introScale,
        tweens = {}, layers = {}, sections = {}, running = nil, mode = nil,
        lastCount = -1, modeRevision = 0, width = 360, dragged = false,
        pointer = nil, suppressedInput = nil,
        blockedInputs = setmetatable({}, {__mode = "k"}),
    }
    state.ui = ui

    -- Fixed tween slots and reusable ripples keep rapid clicks bounded.
    local function tween(key, object, duration, properties)
        if ui.tweens[key] then ui.tweens[key]:Cancel() end
        local effect = TweenService:Create(object,
            TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), properties)
        ui.tweens[key] = effect
        effect:Play()
    end
    ui.tween = tween

    local function section(name, position, size, transparency)
        local hit = make("TextButton", bar, {
            Name = name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
            BorderSizePixel = 0, Position = position, Size = size, ZIndex = 3,
        })
        local face = make("Frame", hit, {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 218, 170),
            BackgroundTransparency = transparency, BorderSizePixel = 0,
            ClipsDescendants = true, ZIndex = 3,
        })
        round(face, 11)
        local faceScale = make("UIScale", face, {Scale = 1})
        local ripple = make("Frame", face, {
            AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(0, 0),
            BackgroundColor3 = Color3.fromRGB(255, 235, 204), BackgroundTransparency = 1,
            BorderSizePixel = 0, ZIndex = 4,
        })
        make("UICorner", ripple, {CornerRadius = UDim.new(1, 0)})
        local value = {hit = hit, face = face, scale = faceScale, ripple = ripple, name = name}
        ui.sections[name] = value
        return value
    end
    local left = section("StartStop", UDim2.fromOffset(6, 6), UDim2.new(0.3, 0, 1, -12), 0.78)
    local right = section("Information", UDim2.new(0.3, 22, 0, 6), UDim2.new(0.7, -28, 1, -12), 1)
    ui.button, ui.right = left.hit, right.hit
    ui.actionLabel = make("TextLabel", left.face, {
        Text = "▶  START", Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = ink, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5,
    })
    make("Frame", bar, {
        BackgroundColor3 = Color3.fromRGB(113, 53, 7), BackgroundTransparency = 0.78,
        BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0.3, 14, 0.5, 0), Size = UDim2.fromOffset(1, 24), ZIndex = 3,
    })
    for _, name in ipairs({"channel", "count", "notice"}) do
        ui.layers[name] = make("CanvasGroup", right.face, {
            Name = name, BackgroundTransparency = 1, GroupTransparency = 1,
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 5,
        })
    end
    make("TextLabel", ui.layers.channel, {
        Text = "➤  @AT3M3", Font = Enum.Font.GothamMedium, TextSize = 15,
        TextColor3 = ink, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
    })
    ui.notice = make("TextLabel", ui.layers.notice, {
        Text = "", Font = Enum.Font.GothamMedium, TextSize = 14,
        TextColor3 = ink, BackgroundTransparency = 1, TextScaled = true, TextWrapped = false,
        Position = UDim2.fromOffset(5, 0), Size = UDim2.new(1, -10, 1, 0),
    })
    make("UITextSizeConstraint", ui.notice, {MinTextSize = 11, MaxTextSize = 14})
    local counter = make("Frame", ui.layers.count, {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        BackgroundTransparency = 1, Size = UDim2.fromOffset(160, 30),
    })
    ui.countScale = make("UIScale", counter, {Scale = 1})
    local function counterLabel(text, font, size)
        return make("TextLabel", counter, {
            Text = text, Font = font, TextSize = size, TextColor3 = ink,
            BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
            Size = UDim2.fromOffset(70, 30),
        })
    end
    local prefix = counterLabel("Собрано", Enum.Font.GothamMedium, 14)
    ui.number = counterLabel("0", Enum.Font.GothamBold, 16)
    local suffix = counterLabel("шт.", Enum.Font.GothamMedium, 14)
    local prefixWidth = math.ceil(TextService:GetTextSize(prefix.Text, 14, prefix.Font, Vector2.new(1000, 30)).X)
    local suffixWidth = math.ceil(TextService:GetTextSize(suffix.Text, 14, suffix.Font, Vector2.new(1000, 30)).X)
    prefix.Size = UDim2.fromOffset(prefixWidth, 30)
    ui.numberPosition = UDim2.fromOffset(prefixWidth + 6, 0)
    ui.fitCounter = function()
        local numberWidth = math.ceil(TextService:GetTextSize(ui.number.Text, 16,
            ui.number.Font, Vector2.new(1000, 30)).X) + 2
        ui.number.Size = UDim2.fromOffset(numberWidth, 30)
        suffix.Position = UDim2.fromOffset(prefixWidth + numberWidth + 12, 0)
        suffix.Size = UDim2.fromOffset(suffixWidth, 30)
        local width = prefixWidth + numberWidth + suffixWidth + 12
        counter.Size = UDim2.fromOffset(width, 30)
        ui.countScale.Scale = math.clamp((ui.width * 0.7 - 40) / width, 0.01, 1)
    end

    ui.setMode = function(mode)
        if ui.mode == mode then return end
        local first = ui.mode == nil
        ui.mode = mode
        ui.modeRevision += 1
        local revision = ui.modeRevision
        for name, layer in pairs(ui.layers) do
            if name == mode then
                if not layer.Visible then
                    layer.Position = UDim2.new(0.5, first and 0 or 7, 0.5, 0)
                end
                layer.Visible = true
                tween(name .. "Transition", layer, first and 0 or 0.18, {
                    GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5),
                })
            elseif layer.Visible then
                tween(name .. "Transition", layer, 0.18, {
                    GroupTransparency = 1, Position = UDim2.new(0.5, -7, 0.5, 0),
                })
                task.delay(0.2, function()
                    if state.alive and state.ui == ui and ui.modeRevision == revision
                        and ui.mode ~= name then layer.Visible = false end
                end)
            end
        end
    end

    local function clampCenter(center)
        return Vector2.new(
            math.clamp(center.X, ui.minX + ui.width / 2, ui.maxX - ui.width / 2),
            math.clamp(center.Y, ui.minY + 28, math.max(ui.minY + 28, ui.maxY - 28)))
    end
    ui.layout = function()
        local camera = workspace.CurrentCamera
        if not camera then return end
        local viewport = camera.ViewportSize
        local insetStart, insetEnd = GuiService:GetGuiInset()
        local layoutKey = string.format("%d:%d:%d:%d:%d:%d", viewport.X, viewport.Y,
            insetStart.X, insetStart.Y, insetEnd.X, insetEnd.Y)
        if ui.layoutKey == layoutKey then return end
        if ui.cancelPointer then ui.cancelPointer() end
        ui.layoutKey = layoutKey
        ui.minX, ui.maxX = insetStart.X + 10, viewport.X - insetEnd.X - 10
        ui.minY, ui.maxY = insetStart.Y + 10, viewport.Y - insetEnd.Y - 10
        ui.width = math.min(360, math.max(1, ui.maxX - ui.minX))
        -- Avoid inverted clamp limits when a viewport is briefly zero-sized.
        ui.maxX = math.max(ui.maxX, ui.minX + ui.width)
        dock.Size = UDim2.fromOffset(ui.width, 56)
        local center = ui.dragged and Vector2.new(dock.Position.X.Offset, dock.Position.Y.Offset)
            or Vector2.new(viewport.X * 0.5, viewport.Y * 0.82)
        center = clampCenter(center)
        dock.Position = UDim2.fromOffset(center.X, center.Y)
        ui.fitCounter()
    end

    local function interactive(value)
        return value == left or (not state.auto and ui.mode == "channel")
    end
    local function restTransparency(value)
        if value == right then return 1 end
        return state.auto and 0.91 or 0.78
    end
    local function release(value)
        tween(value.name .. "Press", value.scale, 0.18, {Scale = 1})
        tween(value.name .. "Face", value.face, 0.18, {
            Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = restTransparency(value),
        })
    end
    local function press(value, point)
        if not interactive(value) then return end
        local bounds, size = value.hit.AbsolutePosition, value.hit.AbsoluteSize
        local x = math.clamp((point.X - bounds.X) / math.max(1, size.X), 0, 1)
        local y = math.clamp((point.Y - bounds.Y) / math.max(1, size.Y), 0, 1)
        local ripple = value.ripple
        if ui.tweens[value.name .. "Ripple"] then ui.tweens[value.name .. "Ripple"]:Cancel() end
        ripple.Position = UDim2.fromScale(x, y)
        ripple.Size = UDim2.fromOffset(0, 0)
        ripple.BackgroundTransparency = 0.45
        local diameter = math.max(size.X, size.Y) * 2.4
        tween(value.name .. "Ripple", ripple, 0.38, {
            Size = UDim2.fromOffset(diameter, diameter), BackgroundTransparency = 1,
        })
        tween(value.name .. "Press", value.scale, 0.08, {Scale = 0.975})
        tween(value.name .. "Face", value.face, 0.08, {
            Position = UDim2.new(0.5, value == left and -1 or 1, 0.5, 1),
            BackgroundTransparency = value == left and 0.65 or 0.87,
        })
    end
    for _, value in pairs(ui.sections) do
        connect(state.uiConnections, value.hit.MouseEnter:Connect(function()
            if interactive(value) and not ui.pointer then
                tween(value.name .. "Face", value.face, 0.15, {
                    BackgroundTransparency = value == left and 0.62 or 0.89,
                })
            end
        end))
        connect(state.uiConnections, value.hit.MouseLeave:Connect(function()
            if not ui.pointer then release(value) end
        end))
    end
    local function contains(hit, point)
        local position, size = hit.AbsolutePosition, hit.AbsoluteSize
        return point.X >= position.X and point.X <= position.X + size.X
            and point.Y >= position.Y and point.Y <= position.Y + size.Y
    end
    local function beginPointer(input)
        if not state.alive then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if ui.pointer then
            if input ~= ui.pointer.input then ui.blockedInputs[input] = true end
            return
        end
        ui.layout()
        if not ui.minX then return end
        local point = Vector2.new(input.Position.X, input.Position.Y)
        local target = contains(left.hit, point) and left or (contains(right.hit, point) and right or nil)
        ui.suppressedInput = nil
        ui.pointer = {
            input = input, origin = point, dragging = false, section = target,
            center = Vector2.new(dock.Position.X.Offset, dock.Position.Y.Offset),
        }
        if target then press(target, point) end
    end
    ui.cancelPointer = function()
        if not ui.pointer then return end
        ui.suppressedInput = ui.pointer.input
        ui.pointer = nil
        release(left)
        release(right)
    end
    connect(state.uiConnections, bar.InputBegan:Connect(beginPointer))
    connect(state.uiConnections, left.hit.InputBegan:Connect(beginPointer))
    connect(state.uiConnections, right.hit.InputBegan:Connect(beginPointer))
    connect(state.uiConnections, UserInputService.InputChanged:Connect(function(input)
        local pointer = ui.pointer
        if not pointer then return end
        if pointer.input.UserInputType == Enum.UserInputType.Touch then
            if input ~= pointer.input then return end
        elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
            return
        end
        local point = Vector2.new(input.Position.X, input.Position.Y)
        local delta = point - pointer.origin
        if not pointer.dragging and delta.Magnitude < 6 then return end
        if not pointer.dragging then
            pointer.dragging = true
            ui.suppressedInput = pointer.input
            ui.dragged = true
            release(left)
            release(right)
        end
        local center = clampCenter(pointer.center + delta)
        dock.Position = UDim2.fromOffset(center.X, center.Y)
    end))
    connect(state.uiConnections, UserInputService.InputEnded:Connect(function(input)
        local pointer = ui.pointer
        if not pointer or input ~= pointer.input then return end
        if pointer.dragging then ui.suppressedInput = input end
        ui.pointer = nil
        release(left)
        release(right)
    end))
    connect(state.uiConnections, UserInputService.WindowFocusReleased:Connect(ui.cancelPointer))

    local function canActivate(input)
        if not state.alive or (ui.pointer and ui.pointer.dragging) then return false end
        if input and ui.blockedInputs[input] then return false end
        if input and input == ui.suppressedInput then return false end
        -- A second finger must not activate a different section during a gesture.
        if input and ui.pointer and input ~= ui.pointer.input then return false end
        return true
    end
    connect(state.uiConnections, left.hit.Activated:Connect(function(input)
        if not canActivate(input) then return end
        setAuto(not state.auto)
    end))
    connect(state.uiConnections, right.hit.Activated:Connect(function(input)
        if not canActivate(input) or state.auto or ui.mode ~= "channel" then return end
        local ok, result = false, nil
        if type(setclipboard) == "function" then
            ok, result = pcall(setclipboard, "https://t.me/AT3M3")
        end
        if ok and result ~= false then
            showNotice("Скопировано", 1)
        else
            showNotice("t.me/AT3M3", 3)
        end
    end))
    ui.layout()
    tween("introScale", introScale, 0.4, {Scale = 1})
    tween("intro", canvas, 0.4, {GroupTransparency = 0, Position = UDim2.fromOffset(0, 0)})
    tween("shadow", shadow, 0.4, {BackgroundTransparency = 0.84})
end

updateUI = function(message)
    if not state.alive or not state.ui then return end
    if message then state.currentStatus = message end
    local ui = state.ui
    ui.layout()
    if ui.lastCount ~= state.sessionCollected then
        local previousCount = ui.lastCount
        ui.lastCount = state.sessionCollected
        local digits = string.format("%.0f", state.sessionCollected)
        ui.number.Text = digits:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
        if ui.tweens.countBump then ui.tweens.countBump:Cancel() end
        ui.number.Position = ui.numberPosition
        ui.number.TextTransparency = 0
        ui.fitCounter()
        if previousCount >= 0 and state.auto and ui.mode == "count" then
            ui.number.Position = ui.numberPosition + UDim2.fromOffset(0, 3)
            ui.number.TextTransparency = 0.3
            ui.tween("countBump", ui.number, 0.16, {
                Position = ui.numberPosition, TextTransparency = 0,
            })
        end
    end
    if ui.running ~= state.auto then
        ui.running = state.auto
        ui.actionLabel.Text = state.auto and "■  STOP" or "▶  START"
        ui.right.Selectable = not state.auto
        ui.tween("StartStopFace", ui.sections.StartStop.face, 0.16, {
            BackgroundTransparency = state.auto and 0.91 or 0.78,
            Position = UDim2.fromScale(0.5, 0.5),
        })
    end
    local notice = state.noticeText and os.clock() < state.noticeUntil
    if notice then ui.notice.Text = state.noticeText end
    ui.setMode(notice and "notice" or (state.auto and "count" or "channel"))
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

