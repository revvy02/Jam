local Jecs = require(script.Parent.Parent.Jecs)

export type World = typeof(Jecs.World.new())
export type Entity<T> = number & {
	__T: T,
}

export type System<T...> = { system: (T...) -> (), name: string } | (T...) -> ()

export type Loop<T...> = {
	phases: {
		RenderStepped: Entity<number>,
		Heartbeat: Entity<number>,
		PreSimulation: Entity<number>,
		PreAnimation: Entity<number>,
	},
	phase: (after: Entity<number>) -> Entity<number>,
	schedule: (self: Loop<T...>, system: System<T...>, phase: number?) -> System<T...>,
	begin: (self: Loop<T...>) -> { [any]: any },
}

return {}
