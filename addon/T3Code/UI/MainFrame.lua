-- The T3 Code window: a standard portrait frame with the thread list on the left,
-- the selected thread on the right, and side tabs for usage and settings.

local _, ns = ...
local UI = ns.UI

local M = {}
ns.Main = M

local WIDTH, HEIGHT = 940, 640
local LIST_W = 300
local COMPOSER_H = 92
local MODEL_ROW_H = 32

M.page = "threads"
M.mode = "thread" -- "thread" | "new"
M.pendingModels = {}

---------------------------------------------------------------------------
-- Frame

local function CreateSideTab(f, index, icon, tooltip, page)
	local tab = CreateFrame("Frame", nil, f, "LargeSideTabButtonTemplate")
	tab.Icon:SetTexture(icon)
	tab:SetFillToInterior(true, 40)
	tab.tooltipText = tooltip
	tab:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, -36 - (index - 1) * 48)
	tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
		if button == "LeftButton" and upInside then M:ShowPage(page) end
	end)
	tab:EnableMouse(true)
	tab.page = page
	return tab
end

local function CreateSelectionDropdown(parent, width, onChange)
	local dropdown = UI.Dropdown(parent, width, onChange)
	dropdown.opensUp = true
	dropdown:RegisterForClicks("LeftButtonUp")
	dropdown:EnableMouseWheel(false)
	dropdown:SetMotionScriptsWhileDisabled(true)
	return dropdown
end

function M:Create()
	if self.frame then return self.frame end
	local f = CreateFrame("Frame", "T3CodeFrame", UIParent, "ButtonFrameTemplate")
	self.frame = f
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER", 0, 20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	f:SetTitle("T3 Code")
	f:SetPortraitToAsset(ns.media .. "portrait")
	tinsert(UISpecialFrames, "T3CodeFrame")

	-- Drag by the title bar.
	local drag = CreateFrame("Frame", nil, f)
	drag:SetPoint("TOPLEFT", 60, 0)
	drag:SetPoint("TOPRIGHT", -30, 0)
	drag:SetHeight(24)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function() f:StartMoving() end)
	drag:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		local point, _, rel, x, y = f:GetPoint()
		ns.db.settings.windowPoint = { point, rel, x, y }
	end)
	local wp = ns.db.settings.windowPoint
	if wp then
		f:ClearAllPoints()
		f:SetPoint(wp[1], UIParent, wp[2], wp[3], wp[4])
	end

	-- Subtitle: the thread you're looking at, and the link status under it.
	f.Subtitle = UI.Text(f, "GameFontNormalLarge", "CENTER")
	f.Subtitle:SetPoint("TOP", 20, -30)
	f.Subtitle:SetWidth(WIDTH - 220)
	f.Subtitle:SetWordWrap(false)
	f.Status = UI.Text(f, "GameFontGreenSmall", "CENTER")
	f.Status:SetPoint("TOP", f.Subtitle, "BOTTOM", 0, -2)
	f.Status:SetWidth(WIDTH - 220)

	-- Collapse the thread list (arrow under the close button).
	f.SidebarToggle = UI.IconButton(f, "common-icon-backarrow", 24, "Hide the thread list", function() M:ToggleSidebar() end)
	if not f.SidebarToggle.Icon:GetAtlas() then f.SidebarToggle.Icon:SetAtlas("common-dropdown-icon-back") end
	f.SidebarToggle:SetPoint("TOPRIGHT", -10, -32)

	-- Shown when the session's live updates are running low: a reload frees them.
	f.RefreshSlots = UI.Button(f, "Refresh live updates", 170, function() ReloadUI() end)
	f.RefreshSlots:SetPoint("TOPRIGHT", f.SidebarToggle, "TOPLEFT", -8, 0)
	f.RefreshSlots:Hide()
	UI.Tooltip(f.RefreshSlots, "Refresh live updates", "Reloads the interface (a couple of seconds) to free a fresh set of live updates.")

	-- Pages live inside the inset.
	f.Pages = {}
	f.Pages.threads = CreateFrame("Frame", nil, f.Inset)
	f.Pages.threads:SetAllPoints()
	self:CreateThreadsPage(f.Pages.threads)
	f.Pages.usage = CreateFrame("Frame", nil, f.Inset)
	f.Pages.usage:SetAllPoints()
	f.Pages.settings = CreateFrame("Frame", nil, f.Inset)
	f.Pages.settings:SetAllPoints()

	-- Bottom button bar.
	self:CreateButtonBar(f)

	-- Side tabs.
	f.Tabs = {
		CreateSideTab(f, 1, ns.media .. "icon", "Threads", "threads"),
		CreateSideTab(f, 2, "Interface\\Icons\\INV_Scroll_08", "Usage limits", "usage"),
		CreateSideTab(f, 3, "Interface\\Icons\\INV_Misc_Gear_01", "Settings", "settings"),
	}

	f:SetScript("OnShow", ns.Safe(function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		ns.windowOpen = true
		ns.Interacted()
		ns.Transport:Touch()
		M:Refresh()
		ns:Fire("WindowShown", f)
	end))
	f:SetScript("OnHide", ns.Safe(function()
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
		M:SaveDraft()
		ns.windowOpen = false
		ns.Transport:Touch()
		ns:Fire("WindowHidden", f)
	end))

	self:ApplyScale()
	ns.Usage:Create(f.Pages.usage)
	ns.Settings:Create(f.Pages.settings)
	self:ShowPage("threads")
	return f
end

function M:CreateThreadsPage(page)
	-- Left: project filter + thread list.
	local left = CreateFrame("Frame", nil, page)
	left:SetPoint("TOPLEFT")
	left:SetPoint("BOTTOMLEFT")
	left:SetWidth(LIST_W)
	page.Left = left

	local divider = page:CreateTexture(nil, "ARTWORK")
	divider:SetAtlas("UI-Frame-Divider-Vertical") -- harmless if missing
	if not divider:GetAtlas() then
		divider:SetColorTexture(0.45, 0.36, 0.2, 0.6)
		divider:SetWidth(2)
	end
	divider:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, -2)
	divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 0, 2)
	page.Divider = divider

	ns.ThreadList:Create(left)

	-- Right: header bar, transcript, composer.
	local right = CreateFrame("Frame", nil, page)
	right:SetPoint("TOPLEFT", left, "TOPRIGHT", 4, 0)
	right:SetPoint("BOTTOMRIGHT")
	page.Right = right

	local header = CreateFrame("Frame", nil, right)
	header:SetPoint("TOPLEFT", 4, -4)
	header:SetPoint("TOPRIGHT", -4, -4)
	header:SetHeight(30)
	local hbg = header:CreateTexture(nil, "BACKGROUND")
	hbg:SetAtlas("common-button-list-collapseExpand")
	hbg:SetAllPoints()
	header.Text = UI.Text(header, "GameFontHighlight", "CENTER")
	header.Text:SetPoint("LEFT", 12, 0)
	header.Text:SetPoint("RIGHT", -110, 0)
	header.Text:SetWordWrap(false)
	header.Action = UI.Button(header, "Settle", 96, function() M:HeaderAction() end)
	header.Action:SetPoint("RIGHT", -4, 0)
	header.Archive = UI.Button(header, "Archive", 86, function()
		if ns.viewId then
			ns.Transport:Send("archive", ns.viewId)
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		end
	end)
	header.Archive:SetPoint("RIGHT", header.Action, "LEFT", -4, 0)
	header.Archive:Hide()
	UI.Tooltip(header.Archive, "Archive", "Hide this thread from the list (it stays in T3 Code's archive).")
	header.Project = UI.Dropdown(header, 220, function(value)
		if M.newProject ~= value then M.newModel, M.newEffort = nil, nil end
		M.newProject = value
		M:Refresh()
	end)
	header.Project:SetPoint("RIGHT", -6, 0)
	header.Project:Hide()
	right.Header = header

	local composer = UI.Inset(right)
	composer:SetPoint("BOTTOMLEFT", 2, 2)
	composer:SetPoint("BOTTOMRIGHT", -2, 2)
	composer:SetHeight(COMPOSER_H)
	right.ComposerInset = composer

	local modelRow = CreateFrame("Frame", nil, composer)
	modelRow:SetPoint("TOPLEFT", 10, -4)
	modelRow:SetPoint("TOPRIGHT", -8, -4)
	modelRow:SetHeight(26)
	modelRow:Hide()
	right.ModelRow = modelRow
	local modelLabel = UI.Text(modelRow, "GameFontNormalSmall")
	modelLabel:SetPoint("LEFT")
	modelLabel:SetText("Agent & model")
	right.Model = CreateSelectionDropdown(modelRow, 400, function(value) M:PickModel(value) end)
	right.Model:SetPoint("LEFT", modelLabel, "RIGHT", 8, 0)
	local effortLabel = UI.Text(modelRow, "GameFontNormalSmall")
	effortLabel:SetPoint("LEFT", right.Model, "RIGHT", 10, 0)
	effortLabel:SetText("Reasoning")
	right.EffortLabel = effortLabel
	right.Effort = CreateSelectionDropdown(modelRow, 124, function(value) M:PickEffort(value) end)
	right.Effort:SetPoint("LEFT", effortLabel, "RIGHT", 8, 0)

	local box = CreateFrame("Frame", nil, composer, "T3CodeComposerTemplate")
	box:SetPoint("TOPLEFT", 8, -6)
	box:SetPoint("BOTTOMRIGHT", -8, 18)
	box:SetDefaultText("Message the agent  (Shift+Enter for a new line)")
	box:RegisterCallback("OnEnterPressed", function()
		if IsShiftKeyDown() then
			box:Insert("\n")
		else
			M:Send()
		end
	end, M)
	box:RegisterCallback("OnTextChanged", function() M:UpdateCounter() ns.Interacted() end, M)
	box:RegisterCallback("OnEscapePressed", function() box:ClearFocus() end, M)
	right.Composer = box
	self.composer = box

	local counter = UI.Text(composer, "GameFontDisableSmall", "RIGHT")
	counter:SetPoint("BOTTOMRIGHT", -8, 5)
	right.Counter = counter

	local hint = UI.Text(composer, "GameFontDisableSmall", "LEFT")
	hint:SetPoint("BOTTOMLEFT", 10, 5)
	right.Hint = hint

	ns.Transcript:Create(right, header, composer)
end

function M:CreateButtonBar(f)
	local bar = {}
	bar.Refresh = UI.Button(f, "Refresh", 110, function()
		ns.Transport:Send("ping")
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end)
	bar.Refresh:SetPoint("BOTTOMLEFT", 6, 4)
	UI.Tooltip(bar.Refresh, "Refresh", "Ask the bridge for a fresh update now.")

	bar.New = UI.Button(f, "New Thread", 130, function() M:StartNewThread() end)
	bar.New:SetPoint("LEFT", bar.Refresh, "RIGHT", 60, 0)

	bar.Back = UI.Button(f, "Back", 110, function() M:Back() end)
	bar.Back:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", LIST_W + 18, 4)

	bar.Stop = UI.IconButton(f, "common-icon-redx", 26, "Stop the agent", function()
		if ns.viewId then
			ns.Transport:Send("stop", ns.viewId)
			PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		end
	end)
	bar.Stop:SetPoint("LEFT", bar.Back, "RIGHT", 18, 0)

	bar.Mic = UI.IconButton(f, "voicechat-icon-mic", 26, "Dictate", function() M:ToggleDictation() end)
	bar.Mic:SetPoint("LEFT", bar.Stop, "RIGHT", 6, 0)
	UI.Tooltip(bar.Mic, nil, function()
		local d = ns.Store.data.bridge and ns.Store.data.bridge.dictation
		return d and ("Click, speak, click again: your words are typed into the message box (" .. d .. " on your desktop). On a controller, hold Y.")
			or "No dictation backend found on the desktop. Install one from the Omarchy menu (Install > AI > Dictation)."
	end)

	bar.Speak = UI.IconButton(f, "voicechat-icon-speaker", 26, "Read aloud", function()
		local v = ns.Store:View()
		local last
		if v and v.msgs then
			for i = #v.msgs, 1, -1 do
				if v.msgs[i].r == "a" then last = v.msgs[i] break end
			end
		end
		if last then ns.Speak(last.t, ns.viewId, last.n) end
	end)
	bar.Speak:SetPoint("LEFT", bar.Mic, "RIGHT", 6, 0)

	bar.Shot = UI.IconButton(f, "Interface\\Icons\\INV_Misc_Spyglass_03", 26, nil, nil)
	bar.Shot:SetPoint("LEFT", bar.Speak, "RIGHT", 6, 0)
	bar.Shot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	bar.Shot:SetScript("OnClick", function(_, button)
		if button == "RightButton" then M:RemoveScreenshots() else M:AttachScreenshot() end
	end)
	UI.Tooltip(bar.Shot, "Attach a screenshot", "Adds a screenshot of the game to your next message. Right-click to remove it. /t3 report also adds diagnostics.")
	UI.Tooltip(bar.Speak, nil, "Read the latest reply aloud.")

	bar.Send = UI.Button(f, "Send", 110, function() M:Send() end)
	bar.Send:SetPoint("BOTTOMRIGHT", -6, 4)
	f.Bar = bar
end

---------------------------------------------------------------------------
-- Pages, sidebar

function M:ShowPage(page)
	local f = self.frame
	self.page = page
	for name, p in pairs(f.Pages) do p:SetShown(name == page) end
	for _, tab in ipairs(f.Tabs) do tab:SetChecked(tab.page == page) end
	local threads = page == "threads"
	for _, key in ipairs({ "Back", "Stop", "Mic", "Speak", "Shot", "Send" }) do f.Bar[key]:SetShown(threads) end
	f.SidebarToggle:SetShown(threads)
	if page == "usage" then ns.Usage:Refresh() end
	if page == "settings" then ns.Settings:Refresh() end
	self:Refresh()
	ns:Fire("PageChanged", page)
end

function M:ToggleSidebar(show)
	local page = self.frame.Pages.threads
	if show == nil then show = not page.Left:IsShown() end
	page.Left:SetShown(show)
	page.Divider:SetShown(show)
	page.Right:ClearAllPoints()
	if show then
		page.Right:SetPoint("TOPLEFT", page.Left, "TOPRIGHT", 4, 0)
	else
		page.Right:SetPoint("TOPLEFT", 0, 0)
	end
	page.Right:SetPoint("BOTTOMRIGHT")
	self.frame.Bar.Refresh:SetShown(show)
	self.frame.Bar.New:SetShown(show)
	self.frame.Bar.Back:ClearAllPoints()
	if show then
		self.frame.Bar.Back:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", LIST_W + 18, 4)
	else
		self.frame.Bar.Back:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 6, 4)
	end
	self.frame.SidebarToggle.Icon:SetRotation(show and 0 or math.pi)
	ns.Transcript:Relayout()
end

---------------------------------------------------------------------------
-- Selecting threads, drafts

function M:SaveDraft()
	if not self.composer then return end
	local key = self.mode == "new" and "__new" or ns.viewId
	if key then
		local text = self.composer:GetInputText()
		ns.db.drafts[key] = (text and text ~= "") and text or nil
	end
end

function M:LoadDraft()
	local key = self.mode == "new" and "__new" or ns.viewId
	self.composer:SetText(key and ns.db.drafts[key] or "")
	self:UpdateCounter()
end

function M:SelectThread(id, opts)
	self:Create()
	if id == ns.viewId and self.mode == "thread" then
		if opts and opts.show then self:Open() end
		return
	end
	self:SaveDraft()
	self.mode = "thread"
	self.previous = ns.viewId
	ns.viewId = id
	local t = ns.Store:Thread(id)
	if t and t.un then ns.Transport:Send("read", id) end
	ns.Transport:Touch()
	self:LoadDraft()
	if opts and opts.show then self:Open() end
	if self.page ~= "threads" then self:ShowPage("threads") end
	self:Refresh()
	ns:Fire("ViewSelected", id)
end

function M:Back()
	if self.mode == "new" then
		self.mode = "thread"
		self:LoadDraft()
		self:Refresh()
		return
	end
	if not self.frame.Pages.threads.Left:IsShown() then
		self:ToggleSidebar(true)
		return
	end
	self:SaveDraft()
	ns.viewId = nil
	ns.Transport:Touch()
	self:LoadDraft()
	self:Refresh()
	ns:Fire("ViewSelected", nil)
end

function M:StartNewThread(projectId)
	self:Create()
	self:SaveDraft()
	self.mode = "new"
	self.newModel, self.newEffort = nil, nil
	local filter = ns.db.settings.project
	self.newProject = projectId or (filter ~= "all" and filter) or ns.db.settings.lastProject
	if not ns.Store.projectsById[self.newProject or ""] then
		local first = ns.Store.data.projects[1]
		self.newProject = first and first.id
	end
	self:LoadDraft()
	if self.page ~= "threads" then self:ShowPage("threads") end
	self:Open()
	self:Refresh()
	self.composer:SetFocus()
end

function M:HeaderAction()
	local t = ns.Store:Thread(ns.viewId)
	if not t then return end
	if t.s == "settled" then
		ns.Transport:Send("unsettle", t.id)
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	else
		ns.Transport:Send("settle", t.id)
		PlaySound(SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end
end

---------------------------------------------------------------------------
-- Agent and model

local function ModelKey(agent, model)
	return agent and model and agent .. "\031" .. model or ""
end

local function FindChoice(options, key)
	for _, choice in ipairs(options) do
		if choice.value == key then return choice end
	end
end

local function SafeLabel(label, id)
	return label or (id and id:gsub("|", "||"))
end

local function SelectionLabel(agent, model)
	return agent and model and agent .. " · " .. model or model or agent
end

local function SetPickerContext(picker, context)
	if picker.context ~= context then
		local open = UI.ListOpen()
		if open and open.owner == picker then open:Hide() end
		picker.context = context
	end
end

local function SetPicker(picker, options, key, fallback, enabled, help, changing)
	picker:SetOptions(options, key)
	local choice = FindChoice(options, key)
	picker.Text:SetText((choice and choice.label or fallback) .. (changing and " · changing…" or ""))
	picker:SetEnabled(enabled)
	picker.Arrow:SetDesaturated(not enabled)
	picker.help = help
	local open = UI.ListOpen()
	if not enabled and open and open.owner == picker then open:Hide() end
end

local WAIT_TO_CHANGE = "Wait for the current run or request to finish before changing the agent, model, or reasoning."

function M:RefreshEffortPicker(right, context, selection, busy, pending)
	local picker = right.Effort
	local model = ModelKey(selection.agent, selection.model)
	SetPickerContext(picker, context .. "\031" .. model)
	picker.selection = selection
	local change = self.mode == "new" and self.newEffort
	if change and change.model ~= model then
		self.newEffort = nil
		change = nil
	end
	local option = selection.option
	local value = change and change.value or selection.effort or ""
	local options = {}
	for _, choice in ipairs(option and option.choices or {}) do
		table.insert(options, { value = choice.id, label = SafeLabel(choice.label, choice.id) })
	end
	if #options > 0 and not selection.effort and self.mode == "new" then
		table.insert(options, 1, { value = "", label = "Default" })
	end
	local shown = #options > 0 or value ~= ""
	right.EffortLabel:SetShown(shown)
	picker:SetShown(shown)
	right.Model:SetWidth(shown and 290 or 400)
	local fallback = value ~= "" and SafeLabel(nil, value) or "Default"
	if change then fallback = change.label .. " · unavailable" end
	local help = busy and WAIT_TO_CHANGE or "Choose how much reasoning this model uses."
	SetPicker(picker, options, value, fallback, shown and not busy and not pending and #options > 0,
		help, pending and pending.effort)
end

function M:RefreshModelPicker(right, thread)
	local store = ns.Store
	local new = self.mode == "new"
	local project = new and store.projectsById[self.newProject or ""]
	local source = new and project or (not new and thread)
	local picker = right.Model
	local shown = new or thread ~= nil
	if shown ~= right.ModelRow:IsShown() then
		right.ModelRow:SetShown(shown)
		right.ComposerInset:SetHeight(COMPOSER_H + (shown and MODEL_ROW_H or 0))
		right.Composer:ClearAllPoints()
		right.Composer:SetPoint("TOPLEFT", 8, shown and -6 - MODEL_ROW_H or -6)
		right.Composer:SetPoint("BOTTOMRIGHT", -8, 18)
	end
	local context = new and "new:" .. (self.newProject or "") or thread and "thread:" .. thread.id
	SetPickerContext(picker, context)
	if not shown then
		SetPickerContext(right.Effort, nil)
		return
	end

	local agent = source and source.mi
	local model = source and source.m
	local effort = source and source.eff
	local agentLabel, modelLabel = source and source.mil, source and source.ml
	if project and not project.e and not (agent and model) then
		local defaults = store.data.bridge
		agent, model, agentLabel, modelLabel = defaults.mi, defaults.m, defaults.mil, defaults.ml
		effort = defaults.eff
	end
	local catalog = store.data.models or {}
	if source and source.e then catalog = (store.data.modelsByEnv or {})[source.e] or {} end
	local busy = not new and thread and (thread.s == "working" or thread.s == "input")
	local restrictAgent
	local option
	for _, entry in ipairs(catalog) do
		if entry.id == agent then
			agentLabel = entry.label or agentLabel
			restrictAgent = not new and not busy and entry.locked
			for _, item in ipairs(entry.models or {}) do
				if item.id == model then
					modelLabel, option = item.label or modelLabel, item.effort
					break
				end
			end
			break
		end
	end
	local currentLabel = SelectionLabel(SafeLabel(agentLabel, agent), SafeLabel(modelLabel, model))
	local options = {}
	local baseKey = ModelKey(agent, model)
	local key = baseKey
	local fallback = currentLabel or "No model selected"
	if new then
		local defaultLabel = currentLabel and "Project default · " .. currentLabel or "Project default"
		if project then table.insert(options, { value = "", label = defaultLabel }) end
		local choice = self.newModel
		key = choice and choice.value or ""
		fallback = choice and (choice.label .. " · unavailable") or (project and defaultLabel or "Pick a project first")
	end
	if source and not busy then
		for _, entry in ipairs(catalog) do
			if not restrictAgent or entry.id == agent then
				for _, item in ipairs(entry.models or {}) do
					table.insert(options, {
						value = ModelKey(entry.id, item.id),
						label = SelectionLabel(SafeLabel(entry.label, entry.id), SafeLabel(item.label, item.id)),
						agent = entry.id, model = item.id, option = item.effort,
					})
				end
			end
		end
	end
	local selection = { agent = agent, model = model, option = option, effort = effort }
	if new and self.newModel and key ~= baseKey then
		local choice = FindChoice(options, key)
		selection = { agent = self.newModel.agent, model = self.newModel.model, option = choice and choice.option }
	end
	selection.effort = selection.effort or (selection.option and selection.option.default)
	local pending = not new and self.pendingModels[thread.id]
	if pending and pending.agent == agent and pending.model == model
		and (not pending.effort or pending.effort == selection.effort) then
		self.pendingModels[thread.id] = nil
		pending = nil
	end
	local enabled = not pending and #options > (new and key == "" and 1 or 0)
	local help
	if busy then
		help = WAIT_TO_CHANGE
	elseif restrictAgent then
		help = "This thread can only change models within its agent."
	else
		help = "Choose the agent and model together."
	end
	SetPicker(picker, options, key, fallback, enabled, help, pending and not pending.effort)
	self:RefreshEffortPicker(right, context, selection, busy, pending)
end

function M:ChangeThreadSelection(thread, agent, model, effort)
	if self.pendingModels[thread.id] then return end
	local id = ns.Transport:Send("model", thread.id, agent, model, effort)
	local pending = { id = id, agent = agent, model = model, effort = effort }
	self.pendingModels[thread.id] = pending
	C_Timer.NewTimer(30, function()
		if self.pendingModels[thread.id] ~= pending then return end
		self.pendingModels[thread.id] = nil
		if ns.viewId == thread.id then self:Refresh() end
	end)
end

function M:PickModel(value)
	local right = self.frame.Pages.threads.Right
	local picker = right.Model
	if not picker:IsEnabled() then return end
	local choice = FindChoice(picker.options, value)
	if not choice then return end
	if self.mode == "new" then
		if value == "" or (self.newModel and self.newModel.value or "") ~= value
			or (self.newEffort and not FindChoice(right.Effort.options, self.newEffort.value)) then
			self.newEffort = nil
		end
		self.newModel = choice.agent and choice or nil
	else
		local thread = ns.Store:Thread(ns.viewId)
		if not thread or ModelKey(thread.mi, thread.m) == value then return end
		self:ChangeThreadSelection(thread, choice.agent, choice.model)
	end
	self:Refresh()
end

function M:PickEffort(value)
	local picker = self.frame.Pages.threads.Right.Effort
	if not picker:IsEnabled() then return end
	local choice = FindChoice(picker.options, value)
	if not choice then return end
	local selection = picker.selection
	local model = ModelKey(selection.agent, selection.model)
	if model == "" then return end
	local changed = value ~= "" and value ~= selection.effort
	if self.mode == "new" then
		self.newEffort = changed and { model = model, value = value, label = choice.label } or nil
	elseif changed then
		local thread = ns.Store:Thread(ns.viewId)
		if not thread or ModelKey(thread.mi, thread.m) ~= model then return end
		self:ChangeThreadSelection(thread, selection.agent, selection.model, value)
	end
	self:Refresh()
end

---------------------------------------------------------------------------
-- Sending

function M:UpdateCounter()
	local right = self.frame and self.frame.Pages.threads.Right
	if not right then return end
	local text = self.composer:GetInputText() or ""
	right.Counter:SetText(2000 - strlenutf8(text))
end

function M:Send(textOverride)
	local text = textOverride or self.composer:GetInputText() or ""
	text = strtrim(text)
	if text == "" then return end
	local model = self.mode == "new" and self.newModel
	local effort = self.mode == "new" and self.newEffort
	local right = self.frame.Pages.threads.Right
	if effort then
		local selection = right.Effort.selection
		if not selection or ModelKey(selection.agent, selection.model) ~= effort.model
			or not FindChoice(right.Effort.options, effort.value) then
			ns.Print("That reasoning level is unavailable. Choose another level or reselect the model.")
			return
		end
		model = model or selection
	end
	local extra = (model and #model.agent + #model.model + 2 or 0) + (effort and #effort.value + 1 or 0)
	if #text + extra > 2300 then
		ns.Print("That message is too long to send from the game (max ~2,000 characters).")
		return
	end
	if self.mode == "new" then
		if not self.newProject then
			ns.Print("Pick a project for the new thread first.")
			return
		end
		ns.db.settings.lastProject = self.newProject
		if model then
			if self.newModel and not FindChoice(right.Model.options, self.newModel.value) then
				ns.Print("That model is unavailable. Choose another model or use the project default.")
				return
			end
			self.pendingNew = ns.Transport:Send("new", self.newProject, text, model.agent, model.model, effort and effort.value or nil)
		else
			self.pendingNew = ns.Transport:Send("new", self.newProject, text)
		end
		self.pendingNewText = text
		ns.db.drafts.__new = nil
	elseif ns.viewId and self.pendingModels[ns.viewId] then
		ns.Print("Wait for the model change before sending a message.")
		return
	elseif ns.viewId and not textOverride and ns.Transcript:CustomAnswer(text) then
		ns.db.drafts[ns.viewId] = nil
	elseif ns.viewId then
		ns.Transport:Send("send", ns.viewId, text)
		ns.Transcript:AddLocalEcho(ns.viewId, text)
		ns.db.drafts[ns.viewId] = nil
	else
		ns.Print("Pick a thread, or start a new one.")
		return
	end
	if not textOverride then
		self.composer:SetText("")
		self.composer:ClearFocus()
	end
	PlaySound(SOUNDKIT.TELL_MESSAGE or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	self:Refresh()
end

---------------------------------------------------------------------------
-- Screenshots and reports

function M:ShotKey()
	if self.mode == "new" then return "new" end
	return ns.viewId
end

function M:ShotCount()
	if self.mode == "new" then return ns.Store.data.newShots or 0 end
	local v = ns.Store:View()
	return v and v.shots or 0
end

function M:ShotHint()
	local n = self:ShotCount()
	if n > 0 then
		return ns.Color("gold", string.format("%d screenshot%s attached", n, n == 1 and "" or "s")) .. ns.Color("grey", " (right-click the spyglass to remove)")
	end
end

function M:AttachScreenshot()
	local key = self:ShotKey()
	if not key then
		ns.Print("Open a thread (or start a new one) first, then attach the screenshot.")
		return
	end
	ns.Transport:Send("shot", key)
	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

function M:RemoveScreenshots()
	local key = self:ShotKey()
	if key then ns.Transport:Send("unshot", key) end
end

-- Fill the message box with diagnostics (and attach a screenshot) for a bug report.
function M:Report(note)
	self:Open()
	if not ns.viewId and self.mode ~= "new" then self:StartNewThread() end
	local T = ns.Transport
	local b = ns.Store.data.bridge or {}
	local lines = { "--- T3 Code for World of Warcraft diagnostics ---" }
	table.insert(lines, string.format("addon %s, bridge %s, T3 %s (%s)", ns.version, b.version or "?", b.t3 or "?", b.server or "?"))
	table.insert(lines, string.format("link %s, signals %s via %s, live updates left %d/%d, queued %d", T:BridgeState(), T.signals, tostring(T.channel), T:SlotsLeft(), T.slotCount, #T.queue))
	if b.envs then
		local m = {}
		for _, e in ipairs(b.envs) do table.insert(m, e.label .. "=" .. e.state) end
		table.insert(lines, "machines " .. table.concat(m, ", "))
	end
	table.insert(lines, string.format("page %s, mode %s, gamepad %s, window scale %.2f", self.page, self.mode, tostring(ns.Gamepad:IsActive()), self.frame:GetScale() or 1))
	local errs = ns.db.errors or {}
	for i = math.max(1, #errs - 2), #errs do
		table.insert(lines, "error " .. date("%H:%M:%S", errs[i].t) .. ": " .. errs[i].msg)
	end
	local text = table.concat(lines, "\n")
	if note and note ~= "" then text = note .. "\n\n" .. text end
	local current = self.composer:GetInputText() or ""
	self.composer:SetText(current ~= "" and (current .. "\n\n" .. text) or text)
	self:AttachScreenshot()
	self.composer:SetFocus()
end

local SCALES = { normal = 1, large = 1.15, xlarge = 1.3 }

function M:ApplyScale()
	if not self.frame then return end
	local pref = ns.db.settings.windowScale or "auto"
	local scale = SCALES[pref] or ((ns.Gamepad and ns.Gamepad:IsActive()) and 1.15 or 1)
	self.frame:SetScale(scale)
end

function M:ToggleDictation()
	if self.dictating then
		self.dictating = false
		ns.Transport:Send("dictate", "stop")
	else
		self.dictating = true
		self:Open()
		self.composer:SetFocus()
		ns.Transport:Send("dictate", "start")
	end
	self:Refresh()
end

---------------------------------------------------------------------------
-- Status line and refresh

local LINK_TEXT = {
	connected = { "green", "Connected" },
	waiting = { "orange", "Waiting for the bridge… (run t3code-wow install on your desktop)" },
	stale = { "red", "Bridge not responding — is t3code-wow running?" },
	t3offline = { "red", "Bridge connected, but T3 Code is offline" },
	exhausted = { "orange", "Live updates paused — /reload to resume" },
}

function M:StatusLine()
	local T = ns.Transport
	if T.slotError == "MISSING" then
		return ns.Color("red", "Live-update files missing — run t3code-wow install, then restart WoW")
	end
	local state = T:BridgeState()
	local entry = LINK_TEXT[state] or LINK_TEXT.waiting
	local text = ns.Color(entry[1], entry[2])
	if #T.queue > 0 then
		text = text .. ns.Color("grey", "  ·  sending…")
	end
	local left = T:SlotsLeft()
	if state == "connected" and left > 0 and left < math.max(40, T.slotCount * 0.15) then
		text = text .. ns.Color("orange", string.format("  ·  %d live updates left", left))
	end
	if self.dictating then
		text = text .. ns.Color("orange", "  ·  listening… release to finish")
	elseif self.dictState == "transcribing" then
		text = text .. ns.Color("orange", "  ·  transcribing…")
	end
	return text
end

function M:UpdateRefreshButton()
	local f = self.frame
	if not f then return end
	local T = ns.Transport
	local low = T.exhausted or (T.slotCount > 0 and T:SlotsLeft() < T.slotCount * 0.15)
	f.RefreshSlots:SetShown(low and not InCombatLockdown())
end

function M:Refresh()
	local f = self.frame
	if not f or not f:IsShown() then return end
	f.Status:SetText(self:StatusLine())
	self:UpdateRefreshButton()

	local right = f.Pages.threads.Right
	local header = right.Header
	local t = ns.Store:Thread(ns.viewId)
	if self.mode == "new" then
		f.Subtitle:SetText("New Thread")
		header.Text:SetText(ns.Color("gold", "Start a new thread in"))
		header.Text:ClearAllPoints()
		header.Text:SetPoint("LEFT", 12, 0)
		header.Text:SetPoint("RIGHT", header.Project, "LEFT", -8, 0)
		header.Text:SetJustifyH("RIGHT")
		header.Action:Hide()
		header.Archive:Hide()
		header.Project:Show()
		self:SetupProjectDropdown()
		self.composer:SetDefaultText("Describe what the agent should do  (Shift+Enter for a new line)")
		right.Hint:SetText(self:ShotHint() or "")
		f.Bar.Send:SetText("Start")
	else
		header.Text:ClearAllPoints()
		header.Text:SetPoint("LEFT", 12, 0)
		header.Text:SetPoint("RIGHT", -110, 0)
		header.Text:SetJustifyH("CENTER")
		header.Project:Hide()
		f.Bar.Send:SetText("Send")
		if t then
			f.Subtitle:SetText(t.title)
			local status = ns.Color(ns.Store.StatusColor(t.s), ns.Store.StatusText(t.s))
			local age = (t.s == "working" and t.st) and ns.Duration(time() - t.st) or ns.Ago(t.u)
			header.Text:SetText(string.format("%s  ·  %s  ·  %s", status, ns.Store:ProjectName(t.p), age))
			header.Action:SetShown(true)
			header.Action:SetText(t.s == "settled" and "Reopen" or "Settle")
			header.Archive:SetShown(t.s == "settled")
			header.Text:SetPoint("RIGHT", t.s == "settled" and -200 or -110, 0)
			self.composer:SetDefaultText(t.s == "working" and "Queue a follow-up  (Shift+Enter for a new line)" or "Message the agent  (Shift+Enter for a new line)")
		else
			f.Subtitle:SetText(ns.Color("grey", "No thread selected"))
			header.Text:SetText(ns.Color("grey", "Pick a thread on the left, or start a new one"))
			header.Action:Hide()
			header.Archive:Hide()
		end
		right.Hint:SetText(self:ShotHint() or (ns.Gamepad and ns.Gamepad:IsActive() and ns.Gamepad:HintText()) or "")
	end
	self:RefreshModelPicker(right, t)
	f.Bar.Send:SetEnabled(self.mode == "new" or not (ns.viewId and self.pendingModels[ns.viewId]))
	f.Bar.Stop:SetEnabled(t ~= nil and t.s == "working" and self.mode ~= "new")
	f.Bar.Stop.Icon:SetDesaturated(not f.Bar.Stop:IsEnabled())
	f.Bar.Mic.Icon:SetVertexColor(self.dictating and 1 or 1, self.dictating and 0.3 or 1, self.dictating and 0.3 or 1)
	f.Bar.Back:SetEnabled(self.mode == "new" or ns.viewId ~= nil or not f.Pages.threads.Left:IsShown())
	self:UpdateCounter()
	ns.ThreadList:Refresh()
	ns.Transcript:Refresh()
end

function M:SetupProjectDropdown()
	local options = {}
	for _, p in ipairs(ns.Store.data.projects) do table.insert(options, { value = p.id, label = p.name }) end
	self.frame.Pages.threads.Right.Header.Project:SetOptions(options, M.newProject)
end

---------------------------------------------------------------------------

function M:Open()
	self:Create()
	if not self.frame:IsShown() then self.frame:Show() end
end

function M:Toggle()
	self:Create()
	self.frame:SetShown(not self.frame:IsShown())
end

ns:On("Login", function()
	M:Create()
end)
-- Dictation results arrive in the snapshot; type them into the message box.
function M:HandleDictation(d)
	if type(d) ~= "table" or type(d.n) ~= "number" then return end
	if d.n <= (ns.db.lastDictN or 0) then return end
	ns.db.lastDictN = d.n
	if time() - math.floor(d.n / 1000) > 90 then return end -- left over from before a /reload
	self.dictState = d.state
	if d.state == "done" and d.text and d.text ~= "" then
		self:Create()
		local box = self.composer
		local current = (box:GetInputText() or ""):gsub("%s+$", "")
		-- The backend also sends a paste keystroke; if that did land, don't add it twice.
		if not current:find(d.text, 1, true) then
			box:SetText(current ~= "" and (current .. " " .. d.text) or d.text)
		end
		self.dictState = nil
		PlaySound(SOUNDKIT.TELL_MESSAGE or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		if ns.db.settings.dictateSend then
			self:Send()
		elseif ns.Gamepad.capturing then
			ns.Gamepad:Highlight(box) -- A sends it
			box:SetFocus()
		else
			box:SetFocus()
		end
	elseif d.state == "empty" then
		self.dictState = nil
		ns.Print("Didn't catch anything — hold to talk and try again.")
	elseif d.state == "error" then
		self.dictState = nil
		ns.Print(ns.Color("red", "Dictation: " .. (d.err or "failed")))
	elseif d.state == "cancelled" then
		self.dictState = nil
	end
	if self.frame and self.frame:IsShown() then self.frame.Status:SetText(self:StatusLine()) end
end

ns:On("DataChanged", function()
	M:HandleDictation(ns.Store.data.dict)
end)

ns:On("DataChanged", function()
	if M.frame and M.frame:IsShown() then M:Refresh() end
end)
ns:On("LinkChanged", function()
	if M.frame and M.frame:IsShown() then
		M.frame.Status:SetText(M:StatusLine())
		M:UpdateRefreshButton()
	end
end)
ns:On("CommandResult", function(r)
	if r.ok == false and r.msg then
		ns.Print(ns.Color("red", r.msg))
		if UIErrorsFrame then UIErrorsFrame:AddMessage("T3 Code: " .. r.msg, 1, 0.2, 0.2) end
	end
	for threadId, pending in pairs(M.pendingModels) do
		if pending.id == r.id then
			M.pendingModels[threadId] = nil
			if ns.viewId == threadId then M:Refresh() end
			break
		end
	end
	if r.id == M.pendingNew then
		M.pendingNew = nil
		if r.ok and r.open then
			M.mode = "thread"
			M:SelectThread(r.open)
		end
	end
end)

-- Live elapsed timers in the header.
C_Timer.NewTicker(1, ns.Safe(function()
	if M.frame and M.frame:IsShown() and M.page == "threads" then
		local t = ns.Store:Thread(ns.viewId)
		if t and t.s == "working" and M.mode == "thread" then M:Refresh() end
	end
end))
