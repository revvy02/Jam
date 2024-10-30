local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_CLIENT = RunService:IsClient()

local Jecs = require(script.Parent.Parent.Jecs)
local Jabby = require(script.Parent.Parent.Jabby)

local pair = Jecs.pair
local topoRuntime = require(script.Parent.topoRuntime)

local Loop = {}
Loop.__index = Loop

local recentErrors = {}
local recentErrorLastTime = 0

local function systemFn(system)
	if type(system) == "table" then
		return system.system
	end

	return system
end

local function systemName(system)
	local fn = systemFn(system)
	return debug.info(fn, "s") .. "->" .. debug.info(fn, "n")
end

function Loop.new(params: { name: string, debug: any, world: any }, ...)
	local self = setmetatable({}, Loop)

	self._name = params.name
	self._debug = params.debug or Jecs.Name
	self._running = false

	self._state = { ... }
	self._stateLength = select("#", ...)

	self._world = params.world
	self._reporter = Jabby.scheduler.create(self._name .. "-scheduler")
	Jabby.public.updated = true

	table.insert(Jabby.public, {
		name = self._name .. "-world",
		world = self._world,
		debug = self._debug,
		class_name = "World",
	})

	table.insert(Jabby.public, self._reporter)

	self._components = {
		Event = self._world:component(),
		Phase = self._world:component(),
		System = self._world:component(),
		Disabled = self._world:component(),
		DependsOn = self._world:component(),
	}

	self._world:set(self._components.Event, self._debug, "Event")
	self._world:set(self._components.Phase, self._debug, "Phase")
	self._world:set(self._components.System, self._debug, "System")
	self._world:set(self._components.Disabled, self._debug, "Disabled")
	self._world:set(self._components.DependsOn, self._debug, "DependsOn")

	self.phases = {
		RenderStepped = self._world:component(),
		Heartbeat = self._world:component(),
		PreSimulation = self._world:component(),
		PreAnimation = self._world:component(),
	}

	if IS_CLIENT then
		self._world:add(self.phases.RenderStepped, self._components.Phase)
		self._world:set(self.phases.RenderStepped, self._components.Event, RunService.RenderStepped)
		self._world:set(self.phases.RenderStepped, self._debug, "RenderStepped")
	end

	self._world:add(self.phases.Heartbeat, self._components.Phase)
	self._world:set(self.phases.Heartbeat, self._components.Event, RunService.Heartbeat)
	self._world:set(self.phases.Heartbeat, self._debug, "Heartbeat")

	self._world:add(self.phases.PreSimulation, self._components.Phase)
	self._world:set(self.phases.PreSimulation, self._components.Event, RunService.PreSimulation)
	self._world:set(self.phases.PreSimulation, self._debug, "PreSimulation")

	self._world:add(self.phases.PreAnimation, self._components.Phase)
	self._world:set(self.phases.PreAnimation, self._components.Event, RunService.PreAnimation)
	self._world:set(self.phases.PreAnimation, self._debug, "PreAnimation")

	return self
end

function Loop:_collectSystemsUnderPhaseRecursive(systems, phase)
	for _, system in self._world:query(self._components.System):with(pair(self._components.DependsOn, phase)) do
		table.insert(systems, system)
	end
	for after in self._world:query(self._components.Phase):with(pair(self._components.DependsOn, phase)) do
		self:_collectSystemsUnderPhaseRecursive(systems, after)
	end
end

function Loop:_collectSystemsUnderEvent(event)
	local systems = {}
	self:_collectSystemsUnderPhaseRecursive(systems, event)

	return systems
end

function Loop:_collect()
	local systems = {}
	for phase, event in self._world:query(self._components.Event):with(self._components.Phase) do
		systems[event] = self:_collectSystemsUnderEvent(phase)
	end
	return systems
end

function Loop:phase(after)
	local phase = self._world:entity()
	self._world:add(phase, self._components.Phase)
	self._world:add(phase, pair(self._components.DependsOn, after))
	return phase
end

function Loop:schedule(system, phase)
	local id = self._world:entity()
	local name = systemName(system)
	local callback = systemFn(system)

	self._world:set(id, self._components.System, {
		name = name,
		state = {},
		callback = callback,
		jabbyId = self._reporter:register_system({ name = name }),
	})

	self._world:add(id, pair(self._components.DependsOn, phase or self.phases.Heartbeat))

	return system
end

function Loop:begin()
	assert(not self._running, string.format("Loop (%s) is already running!", self._name))

	self._running = true

	local connections = {}

	for event, systems in self:_collect() do
		local lastTime = os.clock()

		local function stepSystems()
			local currentTime = os.clock()
			local deltaTime = currentTime - lastTime
			lastTime = currentTime

			for _, system in systems do
				topoRuntime.start({
					system = system.state,
					frame = {
						deltaTime = deltaTime,
					},
					currentSystem = system,
				}, function()
					debug.profilebegin("system: " .. system.name)

					local commitFailed = false
					local thread = coroutine.create(function(...)
						self._reporter:run(system.jabbyId, system.callback)
					end)

					local success, errorValue = coroutine.resume(thread, unpack(self._state, 1, self._stateLength))

					if coroutine.status(thread) ~= "dead" then
						coroutine.close(thread)

						task.spawn(
							error,
							(
								"Jam: System %s yielded! Its thread has been closed. "
								.. "Yielding in systems is not allowed."
							):format(systemName(system))
						)
					end

					if not success then
						if os.clock() - recentErrorLastTime > 10 then
							recentErrorLastTime = os.clock()
							recentErrors = {}
						end

						local errorString = system.name
							.. ": "
							.. (
								if commitFailed
									-- Strip irrelevant line numbers that point to Loop / World
									then string.gsub(errorValue, "%[.+%]:%d+: ", "Failed to apply commands: ")
									else errorValue
							)
							.. "\n"
							.. debug.traceback(thread)

						if not recentErrors[errorString] then
							task.spawn(error, errorString)
							warn("Jam: The above error will be suppressed for the next 10 seconds")
							recentErrors[errorString] = true
						end
					end

					debug.profileend()
				end)
			end
		end

		connections[event] = event:Connect(stepSystems)
	end

	return connections
end

return Loop
