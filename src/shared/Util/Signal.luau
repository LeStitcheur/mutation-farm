--!strict
-- Signal minimal typé. Les gestionnaires sont lancés via task.spawn : une erreur dans l'un
-- n'interrompt ni l'émetteur ni les autres gestionnaires ; l'ordre de connexion est respecté.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local handlers: { [Connection]: (T...) -> () } = {}
	local order: { Connection } = {}

	local function connect(_self: Signal<T...>, handler: (T...) -> ()): Connection
		local connection: Connection = {
			Connected = true,
			Disconnect = function(self: Connection)
				if not self.Connected then
					return
				end
				self.Connected = false
				handlers[self] = nil
				local index = table.find(order, self)
				if index then
					table.remove(order, index)
				end
			end,
		}
		handlers[connection] = handler
		table.insert(order, connection)
		return connection
	end

	local function fire(_self: Signal<T...>, ...: T...)
		for _, connection in table.clone(order) do
			local handler = handlers[connection]
			if handler then
				task.spawn(handler, ...)
			end
		end
	end

	local function disconnectAll(_self: Signal<T...>)
		for _, connection in table.clone(order) do
			connection:Disconnect()
		end
	end

	return {
		Connect = connect,
		Fire = fire,
		DisconnectAll = disconnectAll,
	}
end

return Signal
